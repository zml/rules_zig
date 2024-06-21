"""Common implementation of the zig_binary|library|test rules."""

load(
    "//zig/private/common:bazel_builtin.bzl",
    "bazel_builtin_module",
    BAZEL_BUILTIN_ATTRS = "ATTRS",
)
load("//zig/private/common:data.bzl", "zig_collect_data", "zig_create_runfiles")
load(
    "//zig/private/common:filetypes.bzl",
    "ZIG_SOURCE_EXTENSIONS",
)
load("//zig/private/common:linker_script.bzl", "zig_linker_script")
load("//zig/private/common:location_expansion.bzl", "location_expansion")
load("//zig/private/common:zig_cache.bzl", "zig_cache_output")
load("//zig/private/common:zig_lib_dir.bzl", "zig_lib_dir")
load(
    "//zig/private/providers:zig_module_info.bzl",
    "ZigModuleInfo",
    "zig_module_info",
    "zig_module_specifications",
)
load(
    "//zig/private/providers:zig_settings_info.bzl",
    "ZigSettingsInfo",
    "zig_settings",
)
load("//zig/private/providers:zig_target_info.bzl", "zig_target_platform")

ATTRS = {
    "main": attr.label(
        allow_single_file = ZIG_SOURCE_EXTENSIONS,
        doc = "The main source file.",
        mandatory = False,
    ),
    "srcs": attr.label_list(
        allow_files = ZIG_SOURCE_EXTENSIONS,
        doc = "Other Zig source files required to build the target, e.g. files imported using `@import`.",
        mandatory = False,
    ),
    "extra_srcs": attr.label_list(
        allow_files = True,
        doc = "Other files required to build the target, e.g. files embedded using `@embedFile`.",
        mandatory = False,
    ),
    "extra_docs": attr.label_list(
        allow_files = True,
        doc = "Other files required to generate documentation, e.g. guides referenced using `//!zig-autodoc-guide:`.",
        mandatory = False,
    ),
    "copts": attr.string_list(
        doc = "C compiler flags required to build the C sources of the target. Subject to location expansion.",
        mandatory = False,
    ),
    "linkopts": attr.string_list(
        doc = "Linker flags required to build the target. Subject to location expansion.",
        mandatory = False,
    ),
    "deps": attr.label_list(
        doc = "modules required to build the target.",
        mandatory = False,
    ),
    "data": attr.label_list(
        allow_files = True,
        doc = "Files required by the target during runtime.",
        mandatory = False,
    ),
    "_settings": attr.label(
        default = "//zig/settings",
        doc = "Zig build settings.",
        providers = [ZigSettingsInfo],
    ),
} | BAZEL_BUILTIN_ATTRS

DOCS_ATTRS = {
    "extra_docs": attr.label_list(
        allow_files = True,
        doc = "Other files required to generate documentation, e.g. guides referenced using `//!zig-autodoc-guide:`.",
        mandatory = False,
    ),
}

BINARY_KIND = struct(
    exe = "exe",
    static_lib = "static_lib",
    shared_lib = "shared_lib",
    obj = "obj",
    test = "test",
    test_lib = "test_lib",
)

BINARY_ATTRS = {
    "kind": attr.string(
        doc = "The kind of the target.",
        default = BINARY_KIND.exe,
        values = dir(BINARY_KIND),
        mandatory = True,
    ),
    "env": attr.string_dict(
        doc = """\
Additional environment variables to set when executed by `bazel run`.
Subject to location expansion.
NOTE: The environment variables are not set when you run the target outside of Bazel (for example, by manually executing the binary in bazel-bin/).
        """,
        mandatory = False,
    ),
}

TEST_ATTRS = {
    "env": attr.string_dict(
        doc = """\
Additional environment variables to set when executed by `bazel run` or `bazel test`.
Subject to location expansion.
        """,
        mandatory = False,
    ),
    "env_inherit": attr.string_list(
        doc = """\
Environment variables to inherit from external environment when executed by `bazel test`.
        """,
        mandatory = False,
    ),
}

TOOLCHAINS = [
    "//zig:toolchain_type",
    "//zig/target:toolchain_type",
]

def _lib_prefix(os):
    return os == "windows" and "" or "lib"

def _static_lib_extension(os):
    return os == "windows" and ".lib" or ".a"

def _shared_lib_extension(os):
    return {
        "windows": ".dll",
        "darwin": ".dylib",
    }.get(os, ".so")

def _executable_extension(os):
    return os == "windows" and ".exe" or ""

def _create_cc_info_for_lib(owner, actions, cc_infos, header = None, **kwargs):
    return cc_common.merge_cc_infos(
        direct_cc_infos = [
            CcInfo(
                compilation_context = header and cc_common.create_compilation_context(
                    headers = depset([header]),
                    quote_includes = depset([header.dirname]),
                ) or None,
                linking_context = cc_common.create_linking_context(
                    linker_inputs = depset([
                        cc_common.create_linker_input(
                            owner = owner,
                            libraries = depset([
                                cc_common.create_library_to_link(
                                    actions = actions,
                                    **kwargs,
                                ),
                            ]),
                        ),
                    ]),
                ),
            ),
        ],
        cc_infos = cc_infos,
    )


def zig_build_impl(ctx, *, kind):
    # type: (ctx) -> Unknown
    """Common implementation for Zig build rules.

    Args:
      ctx: Bazel rule context object.
      kind: String; The kind of the rule, one of `zig_binary`, `zig_library`, `zig_shared_library`, `zig_test`.

    Returns:
      List of providers.
    """
    zigtoolchaininfo = ctx.toolchains["//zig:toolchain_type"].zigtoolchaininfo
    zigtargetinfo = ctx.toolchains["//zig/target:toolchain_type"].zigtargetinfo

    files = None
    direct_data = []
    transitive_data = []
    transitive_runfiles = []

    outputs = []

    direct_inputs = []
    transitive_inputs = []

    zig_collect_data(
        data = ctx.attr.data,
        deps = ctx.attr.deps,
        transitive_data = transitive_data,
        transitive_runfiles = transitive_runfiles,
    )

    args = ctx.actions.args()
    args.use_param_file("@%s")

    output = None
    if kind in [BINARY_KIND.exe, BINARY_KIND.test]:
        output = ctx.actions.declare_file(ctx.label.name + _executable_extension(zigtargetinfo.triple.os))
        direct_data.append(output)
    elif kind == BINARY_KIND.static_lib:
        output = ctx.actions.declare_file(_lib_prefix(zigtargetinfo.triple.os) + ctx.label.name + _static_lib_extension(zigtargetinfo.triple.os))
    elif kind == BINARY_KIND.obj:
        # Use static lib extension until CcInfo.objects is working
        output = ctx.actions.declare_file(ctx.label.name + _static_lib_extension(zigtargetinfo.triple.os))
    elif kind == BINARY_KIND.shared_lib:
        output = ctx.actions.declare_file(_lib_prefix(zigtargetinfo.triple.os) + ctx.label.name + _shared_lib_extension(zigtargetinfo.triple.os))
    elif kind == BINARY_KIND.test_lib:
        output = ctx.actions.declare_file(ctx.label.name + ".bc")
    else:
        fail("Unknown rule kind '{}'.".format(kind))

    zig_config_args = ctx.actions.args()
    zig_config_args.use_param_file("@%s")

    zig_lib_dir(
        zigtoolchaininfo = zigtoolchaininfo,
        args = zig_config_args,
    )

    zig_cache_output(
        zigtoolchaininfo = zigtoolchaininfo,
        args = zig_config_args,
    )

    location_targets = ctx.attr.data

    zdeps = []
    cdeps = []
    for dep in ctx.attr.deps:
        if ZigModuleInfo in dep:
            zdeps.append(dep[ZigModuleInfo])
        elif CcInfo in dep:
            cdeps.append(dep[CcInfo])

    root_module = None
    if not ctx.attr.main and len(zdeps) == 1:
        root_module = zdeps[0]
    else:
        bazel_builtin = bazel_builtin_module(ctx)
        root_module = zig_module_info(
            name = ctx.attr.name,
            canonical_name = ctx.label.name,
            main = ctx.file.main,
            srcs = ctx.files.srcs,
            extra_srcs = ctx.files.extra_srcs,
            copts = location_expansion(
                ctx = ctx,
                targets = location_targets,
                outputs = outputs,
                attribute_name = "copts",
                strings = ctx.attr.copts,
            ),
            linkopts = [],
            deps = zdeps + [bazel_builtin],
            cdeps = cdeps,
        )

    cc_infos = [zigtoolchaininfo.zig_hdrs_ccinfo]
    zig_module_specifications(
        root_module = root_module,
        inputs = transitive_inputs,
        cc_infos = cc_infos,
        args = args,
    )

    zig_settings(
        settings = ctx.attr._settings[ZigSettingsInfo],
        args = zig_config_args,
    )

    zig_target_platform(
        target = zigtargetinfo,
        args = zig_config_args,
    )

    inputs = depset(
        direct = [],
        transitive = transitive_inputs,
        order = "preorder",
    )

    providers = []


    if kind == BINARY_KIND.exe:
        outputs.append(output)
        args.add(output, format = "-femit-bin=%s")
        arguments = ["build-exe", zig_config_args, args]
        mnemonic = "ZigBuildExe"
        progress_message = "Building %{input} as Zig binary %{output}"
    elif kind == BINARY_KIND.test:
        outputs.append(output)
        args.add(output, format = "-femit-bin=%s")
        arguments = ["test", "--test-no-exec", zig_config_args, args]
        mnemonic = "ZigBuildTest"
        progress_message = "Building %{input} as Zig test %{output}"
    elif kind == BINARY_KIND.static_lib:
        outputs.append(output)
        args.add(output, format = "-femit-bin=%s")
        # Disabled until https://github.com/ziglang/zig/issues/18188 is fixed
        header = None
        # header = ctx.actions.declare_file(ctx.label.name + ".h")
        # outputs.append(header)
        # args.add(header, format = "-femit-h=%s")
        arguments = ["build-lib", zig_config_args, args]
        mnemonic = "ZigBuildLib"
        progress_message = "Building %{input} as Zig library %{output}"
        cc_info = _create_cc_info_for_lib(
            owner = ctx.label,
            actions = ctx.actions,
            cc_infos = cc_infos,
            header = header,
            static_library = output,
            alwayslink = True,
        )
        providers.append(cc_info)
    elif kind == BINARY_KIND.obj:
        outputs.append(output)
        args.add(output, format = "-femit-bin=%s")
        # Disabled until https://github.com/ziglang/zig/issues/18188 is fixed
        header = None
        # header = ctx.actions.declare_file(ctx.label.name + ".h")
        # outputs.append(header)
        # args.add(header, format = "-femit-h=%s")
        arguments = ["build-obj", zig_config_args, args]
        mnemonic = "ZigBuildObj"
        progress_message = "Building %{input} as Zig library %{output}"
        cc_info = _create_cc_info_for_lib(
            actions = ctx.actions,
            owner = ctx.label,
            cc_infos = cc_infos,
            header = header,
            # CcInfo.objects doesn't work at the moment
            # see https://github.com/bazelbuild/bazel/blob/727632539bd58dbcf54a9a52a7da15eb0e7c49e2/src/main/starlark/builtins_bzl/common/cc/cc_common.bzl#L318
            static_library = output,
            alwayslink = True,
        )
        providers.append(cc_info)
    elif kind == BINARY_KIND.shared_lib:
        outputs.append(output)
        args.add(output, format = "-femit-bin=%s")
        args.add(output.basename, format = "-fsoname=%s")
        arguments = ["build-lib", "-dynamic", zig_config_args, args]
        mnemonic = "ZigBuildSharedLib"
        progress_message = "Building %{input} as Zig shared library %{output}"
    elif kind == BINARY_KIND.test_lib:
        outputs.append(output)
        args.add(output, format = "-femit-llvm-bc=%s")
        arguments = ["test", "-fno-emit-bin", zig_config_args, args]
        mnemonic = "ZigBuildTestLib"
        progress_message = "Building %{input} as Zig test library %{output}"
    else:
        fail("Unknown rule kind '{}'.".format(kind))

    ctx.actions.run(
        outputs = outputs,
        inputs = inputs,
        executable = zigtoolchaininfo.zig_exe,
        tools = [zigtoolchaininfo.zig_lib],
        arguments = arguments,
        mnemonic = mnemonic,
        progress_message = progress_message,
        execution_requirements = {tag: "" for tag in ctx.attr.tags},
    )

    if kind == BINARY_KIND.test_lib:
        bcinput = output
        output = ctx.actions.declare_file(_lib_prefix(zigtargetinfo.triple.os) + ctx.label.name + _static_lib_extension(zigtargetinfo.triple.os))
        libargs = ctx.actions.args()
        libargs.add(output, format = "-femit-bin=%s")
        libargs.add(bcinput)
        ctx.actions.run(
            outputs = [output],
            inputs = [bcinput],
            executable = zigtoolchaininfo.zig_exe,
            tools = [zigtoolchaininfo.zig_lib],
            arguments = ["build-lib", zig_config_args, libargs],
            mnemonic = mnemonic,
            progress_message = progress_message,
            execution_requirements = {tag: "" for tag in ctx.attr.tags},
        )
        cc_info = _create_cc_info_for_lib(
            owner = ctx.label,
            actions = ctx.actions,
            cc_infos = cc_infos,
            static_library = output,
            alwayslink = True,
        )
        providers.append(cc_info)

    files = depset([output])
    default = DefaultInfo(
        executable = output,
        files = files,
        runfiles = zig_create_runfiles(
            ctx_runfiles = ctx.runfiles,
            direct_data = direct_data,
            transitive_data = transitive_data,
            transitive_runfiles = transitive_runfiles,
        ),
    )
    providers.append(default)

    if kind in [BINARY_KIND.exe, BINARY_KIND.test]:
        run_environment = RunEnvironmentInfo(
            environment = dict(zip(ctx.attr.env.keys(), location_expansion(
                ctx = ctx,
                targets = location_targets,
                outputs = outputs,
                attribute_name = "env",
                strings = ctx.attr.env.values(),
            ))),
            inherited_environment = getattr(ctx.attr, "env_inherit", []),
        )
        providers.append(run_environment)

    return providers
