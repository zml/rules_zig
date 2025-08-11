"""Common implementation of the zig_binary|library|test rules."""

load("@build_bazel_rules_android//:cc_common_link.bzl", "cc_common_link")
load("@rules_cc//cc:defs.bzl", "cc_common")
load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cc_toolchain", "use_cc_toolchain")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("//zig/private:settings.bzl", "LINKMODE_VALUES")
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
load("//zig/private/common:location_expansion.bzl", "location_expansion")
load("//zig/private/common:zig_cache.bzl", "zig_cache_output")
load("//zig/private/common:zig_lib_dir.bzl", "zig_lib_dir")
load("//zig/private/common:zig_translate_c.bzl", "zig_translate_c")
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
        allow_single_file = True,
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
    "test_runner": attr.label(
        allow_single_file = True,
        doc = "Optional Zig file to specify a custom test runner",
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

build_kind = struct(
    exe = 1,
    static_lib = 2,
    shared_lib = 3,
    test = 4,
    asm = 5,
)

BINARY_ATTRS = {
    "kind": attr.string(mandatory = False),
    "env": attr.string_dict(
        doc = """\
Additional environment variables to set when executed by `bazel run`.
Subject to location expansion.
NOTE: The environment variables are not set when you run the target outside of Bazel (for example, by manually executing the binary in bazel-bin/).
        """,
        mandatory = False,
    ),
    "linkmode": attr.string(
        mandatory = False,
        values = ["zig", "cc"],
    ),
}

ASM_ATTRS = {
    "extension": attr.string(default = ".s"),
}

STATIC_LIBRARY_ATTRS = {
    "linkmode": attr.string(
        mandatory = False,
        values = LINKMODE_VALUES,
    ),
}

SHARED_LIBRARY_ATTRS = {
    "shared_lib_name": attr.string(mandatory = False),
    "linkmode": attr.string(
        mandatory = False,
        values = LINKMODE_VALUES,
    ),
}

TEST_ATTRS = {
    "kind": attr.string(mandatory = False),
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
    "linkmode": attr.string(
        mandatory = False,
        values = LINKMODE_VALUES,
    ),
}

TOOLCHAINS = [
    "//zig:toolchain_type",
    "//zig/target:toolchain_type",
] + use_cc_toolchain()

def _lib_prefix(os):
    return os == "windows" and "" or "lib"

def _static_lib_extension(os):
    return os == "windows" and ".lib" or ".a"

def _shared_lib_extension(os):
    return {
        "windows": ".dll",
        "darwin": ".dylib",
        "macos": ".dylib",
    }.get(os, ".so")

def _executable_extension(os):
    return os == "windows" and ".exe" or ""

def _cc_info_for_library(ctx, **kwargs):
    cc_toolchain = find_cc_toolchain(ctx)
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )
    lib = cc_common.create_library_to_link(
        actions = ctx.actions,
        cc_toolchain = cc_toolchain,
        feature_configuration = feature_configuration,
        **kwargs
    )
    return _cc_info_for_library_to_link(ctx, lib)

def _cc_info_for_library_to_link(ctx, library_to_link):
    return CcInfo(
        linking_context = cc_common.create_linking_context(
            linker_inputs = depset([
                cc_common.create_linker_input(
                    owner = ctx.label,
                    libraries = depset([library_to_link]),
                ),
            ]),
        ),
    )

def _cc_link(ctx, name, cc_infos, **kwargs):
    cc_toolchain = find_cc_toolchain(ctx)
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )
    return cc_common_link(
        actions = ctx.actions,
        name = name,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        linking_contexts = [cc_info.linking_context for cc_info in cc_infos],
        **kwargs
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

    linkmode = getattr(ctx.attr, "linkmode", None) or ctx.attr._settings[ZigSettingsInfo].linkmode

    direct_data = []
    transitive_data = []
    transitive_runfiles = []

    outputs = []

    transitive_inputs = []

    zig_collect_data(
        data = ctx.attr.data,
        deps = ctx.attr.deps,
        transitive_data = transitive_data,
        transitive_runfiles = transitive_runfiles,
    )

    args = ctx.actions.args()
    args.use_param_file("@%s")

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
            linkopts = ctx.attr.linkopts,
            deps = zdeps + [bazel_builtin_module(ctx)],
            cdeps = cdeps,
        )

    zig_settings(
        settings = ctx.attr._settings[ZigSettingsInfo],
        args = zig_config_args,
    )

    zig_target_platform(
        target = zigtargetinfo,
        args = zig_config_args,
    )

    cc_infos = root_module.transitive_cdeps.to_list()
    c_module = None
    if cc_infos:
        args.add("-lc")
        c_module = zig_translate_c(
            ctx = ctx,
            zigtoolchaininfo = zigtoolchaininfo,
            zig_config_args = zig_config_args,
            cc_infos = cc_infos,
        )

    zig_module_specifications(
        root_module = root_module,
        inputs = transitive_inputs,
        c_module = c_module,
        args = args,
    )

    inputs = depset(
        direct = [],
        transitive = transitive_inputs,
        order = "preorder",
    )

    providers = [
        root_module,
    ]

    runfiles = zig_create_runfiles(
        ctx_runfiles = ctx.runfiles,
        direct_data = direct_data,
        transitive_data = transitive_data,
        transitive_runfiles = transitive_runfiles,
    )

    zig_build_kwargs = dict(
        execution_requirements = {tag: "" for tag in ctx.attr.tags},
        tools = zigtoolchaininfo.zig_files,
        toolchain = "//zig:toolchain_type",
    )

    if kind == build_kind.exe:
        executable = None
        mnemonic = "ZigBuildExe"
        progress_message = "zig build-exe %{label}"

        if linkmode == "cc":
            static_lib = ctx.actions.declare_file(ctx.label.name + _static_lib_extension(zigtargetinfo.triple.os))
            zig_config_args.add_all([
                "-fPIC",
                "-fcompiler-rt",
                "-lc",
            ])
            args.add(static_lib, format = "-femit-bin=%s")
            ctx.actions.run(
                outputs = [static_lib],
                inputs = inputs,
                executable = zigtoolchaininfo.zig_exe,
                arguments = ["build-lib", zig_config_args, args],
                mnemonic = mnemonic,
                progress_message = progress_message,
                **zig_build_kwargs
            )

            link_outputs = _cc_link(
                ctx = ctx,
                name = ctx.label.name,
                user_link_flags = ctx.attr.linkopts,
                output_type = "executable",
                cc_infos = cc_infos + [_cc_info_for_library(
                    ctx = ctx,
                    static_library = static_lib,
                    alwayslink = True,
                )],
            )

            executable = link_outputs.executable
        else:
            executable = ctx.actions.declare_file(ctx.label.name + _executable_extension(zigtargetinfo.triple.os))
            args.add(executable, format = "-femit-bin=%s")
            ctx.actions.run(
                outputs = [executable],
                inputs = inputs,
                executable = zigtoolchaininfo.zig_exe,
                arguments = ["build-exe", zig_config_args, args],
                mnemonic = mnemonic,
                progress_message = progress_message,
                **zig_build_kwargs
            )

        providers.append(
            DefaultInfo(
                executable = executable,
                files = depset([executable]),
                runfiles = runfiles,
            ),
        )

    elif kind == build_kind.test:
        mnemonic = "ZigBuildTest"
        progress_message = "zig test %{label}"
        executable = None

        if ctx.attr.test_runner:
            args.add("--test-runner", ctx.file.test_runner)

        if linkmode == "cc":
            bc = ctx.actions.declare_file(ctx.label.name + ".bc")
            test_args = ctx.actions.args()
            test_args.add("-fno-emit-bin")
            test_args.add(bc, format = "-femit-llvm-bc=%s")
            ctx.actions.run(
                outputs = [bc],
                inputs = inputs,
                executable = zigtoolchaininfo.zig_exe,
                arguments = ["test", "--test-no-exec", zig_config_args, args, test_args],
                mnemonic = mnemonic,
                progress_message = progress_message,
                **zig_build_kwargs
            )

            static_lib = ctx.actions.declare_file(ctx.label.name + _static_lib_extension(zigtargetinfo.triple.os))
            lib_args = ctx.actions.args()
            lib_args.add_all([
                "-fPIC",
                "-fcompiler-rt",
            ])
            lib_args.add(static_lib, format = "-femit-bin=%s")
            lib_args.add(bc)
            ctx.actions.run(
                outputs = [static_lib],
                inputs = [bc],
                executable = zigtoolchaininfo.zig_exe,
                arguments = ["build-lib", zig_config_args, lib_args],
                mnemonic = "ZigBuildTestLib",
                progress_message = "zig build-lib %{label}",
                **zig_build_kwargs
            )

            link_outputs = _cc_link(
                ctx = ctx,
                name = ctx.label.name,
                user_link_flags = ctx.attr.linkopts,
                output_type = "executable",
                cc_infos = cc_infos + [_cc_info_for_library(
                    ctx = ctx,
                    static_library = static_lib,
                    alwayslink = True,
                )],
            )

            executable = link_outputs.executable

        else:
            executable = ctx.actions.declare_file(ctx.label.name + _executable_extension(zigtargetinfo.triple.os))
            args.add(executable, format = "-femit-bin=%s")
            ctx.actions.run(
                outputs = outputs,
                inputs = inputs,
                executable = zigtoolchaininfo.zig_exe,
                arguments = ["test", "--test-no-exec", zig_config_args, args],
                mnemonic = mnemonic,
                progress_message = progress_message,
                **zig_build_kwargs
            )

        providers.append(
            DefaultInfo(
                executable = executable,
                files = depset([executable]),
                runfiles = runfiles,
            ),
        )

    elif kind == build_kind.static_lib:
        static_lib = ctx.actions.declare_file(ctx.label.name + _static_lib_extension(zigtargetinfo.triple.os))
        args.add(static_lib, format = "-femit-bin=%s")
        ctx.actions.run(
            outputs = [static_lib],
            inputs = inputs,
            executable = zigtoolchaininfo.zig_exe,
            arguments = ["build-lib", zig_config_args, args],
            mnemonic = "ZigBuildStaticLib",
            progress_message = "zig build-lib %{label}",
            **zig_build_kwargs
        )
        providers.extend([
            DefaultInfo(
                files = depset([static_lib]),
                runfiles = runfiles,
            ),
            cc_common.merge_cc_infos(
                direct_cc_infos = [
                    _cc_info_for_library(
                        ctx = ctx,
                        cc_infos = cc_infos,
                        static_library = static_lib,
                        alwayslink = True,
                    ),
                ],
                cc_infos = cc_infos,
            ),
        ])

    elif kind == build_kind.shared_lib:
        mnemonic = "ZigBuildSharedLib"
        progress_message = "zig build-lib %{label}"

        shared_library = None
        cc_info = None

        if linkmode == "cc":
            zig_config_args.add_all([
                "-fPIC",
                "-lc",
            ])

            if (ctx.attr.shared_lib_name):
                shared_library = ctx.actions.declare_file(ctx.attr.shared_lib_name)
            else:
                shared_library = ctx.actions.declare_file(_lib_prefix(zigtargetinfo.triple.os) + ctx.label.name + _shared_lib_extension(zigtargetinfo.triple.os))

            static_lib = ctx.actions.declare_file(ctx.label.name + _static_lib_extension(zigtargetinfo.triple.os))
            args.add(static_lib, format = "-femit-bin=%s")
            ctx.actions.run(
                outputs = [static_lib],
                inputs = inputs,
                executable = zigtoolchaininfo.zig_exe,
                arguments = ["build-lib", zig_config_args, args],
                mnemonic = mnemonic,
                progress_message = progress_message,
                **zig_build_kwargs
            )
            link_outputs = _cc_link(
                ctx = ctx,
                name = ctx.label.name,
                user_link_flags = ctx.attr.linkopts,
                output_type = "dynamic_library",
                main_output = shared_library,
                cc_infos = cc_infos + [_cc_info_for_library(
                    ctx = ctx,
                    static_library = static_lib,
                    alwayslink = True,
                )],
            )

            cc_info = _cc_info_for_library_to_link(
                ctx = ctx,
                library_to_link = link_outputs.library_to_link,
            )
        else:
            shared_library = ctx.actions.declare_file(_lib_prefix(zigtargetinfo.triple.os) + ctx.label.name + _shared_lib_extension(zigtargetinfo.triple.os))
            args.add(shared_library, format = "-femit-bin=%s")
            ctx.actions.run(
                outputs = [shared_library],
                inputs = inputs,
                executable = zigtoolchaininfo.zig_exe,
                arguments = ["build-lib", "-dynamic", zig_config_args, args],
                mnemonic = mnemonic,
                progress_message = progress_message,
                **zig_build_kwargs
            )
            cc_info = _cc_info_for_library(
                ctx = ctx,
                dynamic_library = shared_library,
            )

        providers.extend([
            DefaultInfo(
                files = depset([shared_library]),
                runfiles = runfiles,
            ),
            cc_common.merge_cc_infos(
                direct_cc_infos = [cc_info],
                cc_infos = cc_infos,
            ),
        ])

    elif kind == build_kind.asm:
        asm_file = ctx.actions.declare_file(ctx.label.name + ctx.attr.extension)
        args.add("-fno-emit-bin")
        args.add(asm_file, format = "-femit-asm=%s")
        ctx.actions.run(
            outputs = [asm_file],
            inputs = inputs,
            executable = zigtoolchaininfo.zig_exe,
            arguments = ["build-obj", zig_config_args, args],
            mnemonic = "ZigBuildAsm",
            progress_message = "zig build-obj -femit-asm %{label}",
            **zig_build_kwargs
        )

        providers.append(
            DefaultInfo(
                files = depset([asm_file]),
                runfiles = runfiles,
            ),
        )

    else:
        fail("Unknown rule kind '{}'.".format(kind))

    providers.append(
        OutputGroupInfo(
            srcs = inputs,
        ),
    )

    if kind in [build_kind.exe, build_kind.test]:
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
