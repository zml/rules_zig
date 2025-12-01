"""Handle translate-c pass."""

load("@apple_support//lib:apple_support.bzl", "apple_support")
load("@rules_cc//cc:action_names.bzl", "ACTION_NAMES")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")

# load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cc_toolchain")
load("//zig/private:cc_helper.bzl", "find_cc_toolchain")
load("//zig/private/providers:zig_module_info.bzl", "ZigModuleInfo", "zig_module_info")

def _extract_sysroot(command_line):
    rewritten = []
    sysroot = None
    waiting_for_sysroot = False

    for arg in command_line:
        if waiting_for_sysroot:
            sysroot = arg
            waiting_for_sysroot = False
        elif arg == "-isysroot":
            waiting_for_sysroot = True
        elif arg.startswith("-isysroot"):
            # rare compact form: -isysroot/path
            sysroot = arg[len("-isysroot"):]
        else:
            rewritten.append(arg)

    if waiting_for_sysroot:
        fail("-isysroot without following path in command_line")

    return rewritten, sysroot

def zig_translate_c(*, ctx, name, canonical_name, zigtoolchaininfo, global_args, cc_infos, output_prefix = ""):
    """Handle translate-c build action.

    Sets the appropriate command-line flags for the Zig compiler to expose
    provided headers and link against the provided libraries.

    Args:
      ctx: Context object.
      name: String, the name of the resulting Zig module.
      zigtoolchaininfo: ZigToolchainInfo.
      global_args: Args; mutable, Append the global Zig command-line flags to this object.
      cc_infos: List of CcInfo, The CcInfo providers for the C dependencies.
      output_prefix: String, a prefix to be used for generated files. Used for zig_docs.

    Returns:
        `ZigModuleInfo` surrounding the generated zig file.
    """
    cc_info = cc_common.merge_cc_infos(direct_cc_infos = cc_infos)
    compilation_context = cc_info.compilation_context
    linking_context = cc_info.linking_context

    inputs = []
    transitive_inputs = [compilation_context.headers]

    hdrs = compilation_context.direct_public_headers

    # If there is a CC toolchain, add builtin directories.
    # This allows including to extra headers provided directly by the toolchain.
    # E.g. <os/log.h> on macOS.
    cc_toolchain, cc_feature_configuration = find_cc_toolchain(ctx, mandatory = False)
    if cc_toolchain:
        toolchain_defines_hdr = ctx.actions.declare_file("{}.toolchain_defines_hdr.c".format(ctx.label.name))
        ctx.actions.write(toolchain_defines_hdr, "")

        _, cc_results = cc_common.compile(
            actions = ctx.actions,
            feature_configuration = cc_feature_configuration,
            cc_toolchain = cc_toolchain,
            srcs = [toolchain_defines_hdr],
            name = ctx.label.name,
            # -fblocks is by default on darwin. but gcc doesn't handle it so best undef the macro manually.
            user_compile_flags = ["-x", "c", "-E", "-dM", "-D__building_module(x)=0", "-U__BLOCKS__"],
            disallow_pic_outputs = True,
        )

        hdrs = cc_results.objects + hdrs
        transitive_inputs.append(depset(direct = cc_results.objects))

    hdr = ctx.actions.declare_file("{}{}_c.h".format(output_prefix, ctx.label.name))
    ctx.actions.write(hdr, "\n".join([
        '#include "{}"'.format(hdr.path)
        for hdr in hdrs
    ]))
    inputs.append(hdr)

    args = ctx.actions.args()
    args.add(hdr)

    if cc_toolchain:
        c_compile_variables = cc_common.create_compile_variables(
            feature_configuration = cc_feature_configuration,
            cc_toolchain = cc_toolchain,
            user_compile_flags = ctx.fragments.cpp.copts + ctx.fragments.cpp.conlyopts,
        )
        command_line = cc_common.get_memory_inefficient_command_line(
            feature_configuration = cc_feature_configuration,
            action_name = ACTION_NAMES.c_compile,
            variables = c_compile_variables,
        )

        print(cc_toolchain.built_in_include_directories)

        transitive_inputs.append(cc_toolchain.all_files)
        args.add_all([
            d.replace("external/toolchains_llvm_bootstrapped+/toolchain/", "")
            for d in cc_toolchain.built_in_include_directories
        ], before_each = "-isystem")

        # args.add_all(cc_toolchain.built_in_include_directories, before_each = "-isystem")

        rewritten, sysroot = _extract_sysroot(command_line)
        if sysroot != None or sysroot != "/dev/null":
            rewritten.append("--sysroot=%s" % sysroot)
        args.add_all(rewritten)

        # args.add_all(command_line)

    args.add_all([
        "--emulate=clang",
        "-undef",
        "-nobuiltininc",
        "-nostdlibinc",
        "-fmodule-libs",
        "-D__building_module(x)=0",
    ])

    args.add_all(compilation_context.defines, format_each = "-D%s")
    args.add("-I.")
    args.add_all(compilation_context.includes, format_each = "-I%s")

    # Note, Zig does not support `-iquote` as of Zig 0.12.0
    # args.add_all(compilation_context.quote_includes, format_each = "-iquote%s")
    args.add_all(compilation_context.quote_includes, format_each = "-I%s")
    args.add_all(compilation_context.system_includes, before_each = "-isystem")

    # Added in Bazel 7, see https://github.com/bazelbuild/bazel/commit/a6ef0b341a8ffe8ab27e5ace79d8eaae158c422b
    args.add_all(getattr(compilation_context, "external_includes", []), before_each = "-isystem")
    args.add_all(compilation_context.framework_includes, format_each = "-F%s")

    zig_out = ctx.actions.declare_file("{}{}_c.zig".format(output_prefix, ctx.label.name))
    args.add("-o", zig_out)

    if apple_support.target_os_from_rule_ctx(ctx, fail_on_missing_constraint = False):
        apple_support.run(
            actions = ctx.actions,
            executable = ctx.executable._translate_c,
            inputs = depset(
                direct = inputs,
                transitive = transitive_inputs,
            ),
            outputs = [zig_out],
            arguments = [args],
            mnemonic = "ZigTranslateC",
            progress_message = "zig translate-c %{label}",
            execution_requirements = {tag: "" for tag in ctx.attr.tags},
            xcode_path_resolve_level = apple_support.xcode_path_resolve_level.args,
            env = {
                "ZIG_GLOBAL_CACHE_DIR": zigtoolchaininfo.zig_cache,
                "ZIG_LIB_DIR": zigtoolchaininfo.zig_lib_path,
                "ZIG_LOCAL_CACHE_DIR": zigtoolchaininfo.zig_cache,
            },
            tools = zigtoolchaininfo.zig_files,
            toolchain = "//zig:toolchain_type",
            apple_fragment = ctx.fragments.apple,
            xcode_config = ctx.attr._xcode_config[apple_common.XcodeVersionConfig],
        )
    else:
        ctx.actions.run(
            inputs = depset(
                direct = inputs,
                transitive = transitive_inputs,
            ),
            executable = ctx.executable._translate_c,
            outputs = [zig_out],
            arguments = [args],
            mnemonic = "ZigTranslateC",
            progress_message = "zig translate-c %{label}",
            execution_requirements = {tag: "" for tag in ctx.attr.tags},
            env = {
                "ZIG_GLOBAL_CACHE_DIR": zigtoolchaininfo.zig_cache,
                "ZIG_LIB_DIR": zigtoolchaininfo.zig_lib_path,
                "ZIG_LOCAL_CACHE_DIR": zigtoolchaininfo.zig_cache,
            },
            tools = zigtoolchaininfo.zig_files,
            toolchain = "//zig:toolchain_type",
        )

    # Only forward the linking context since compilation_context is now handled
    # by Zig through the generated _c.zig.
    cc_info = CcInfo(
        linking_context = linking_context,
    )

    return zig_module_info(
        name = name,
        canonical_name = canonical_name,
        main = zig_out,
        cdeps = [cc_info],
        deps = [ctx.attr._c_helpers[ZigModuleInfo], ctx.attr._c_builtins[ZigModuleInfo]],
    )
