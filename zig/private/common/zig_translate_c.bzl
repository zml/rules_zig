load("//zig/private/providers:zig_module_info.bzl", "zig_module_info")
load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cc_toolchain")
load("@rules_cc//cc:action_names.bzl", "C_COMPILE_ACTION_NAME")

def zig_translate_c(*, ctx, zigtoolchaininfo, zig_config_args, cc_infos):
    cc_info = cc_common.merge_cc_infos(direct_cc_infos = cc_infos)
    compilation_context = cc_info.compilation_context

    header_txt = "\n".join([
        '#include "{}"'.format(hdr.path)
        for hdr in compilation_context.direct_public_headers
    ])
    hdr = ctx.actions.declare_file("{}_c.h".format(ctx.label.name))
    ctx.actions.write(hdr, header_txt)

    zig_out = ctx.actions.declare_file("{}_c.zig".format(ctx.label.name))

    args = ctx.actions.args()
    args.add(hdr)
    args.add("-lc")
    args.add_all(compilation_context.defines, format_each = "-D%s")
    args.add("-I.")
    args.add_all(compilation_context.includes, format_each = "-I%s")

    args.add_all(compilation_context.quote_includes, format_each = "-I%s")
    args.add_all(compilation_context.system_includes, before_each = "-isystem")
    if hasattr(compilation_context, "external_includes"):
        # Added in Bazel 7, see https://github.com/bazelbuild/bazel/commit/a6ef0b341a8ffe8ab27e5ace79d8eaae158c422b
        args.add_all(compilation_context.external_includes, before_each = "-isystem")
    args.add_all(compilation_context.framework_includes, format_each = "-F%s")

    # If there is a CC toolchain, add its path there
    cc_toolchain = find_cc_toolchain(ctx)

    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = [],
        unsupported_features = [],
    )

    c_compile_variables = cc_common.create_compile_variables(
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        user_compile_flags = ctx.fragments.cpp.copts + ctx.fragments.cpp.conlyopts,
    )

    command_line = cc_common.get_memory_inefficient_command_line(
        feature_configuration = feature_configuration,
        action_name = C_COMPILE_ACTION_NAME,
        variables = c_compile_variables,
    )

    new_command_line = []
    for arg in command_line:
        if arg.startswith("--sysroot="):
            new_command_line.append("--sysroot")
            new_command_line.append(arg[len("--sysroot="):])
            new_command_line.append("-isystem")
            new_command_line.append("{}/usr/include".format(arg[len("--sysroot="):]))
        else:
            new_command_line.append(arg)
    command_line = new_command_line

    new_command_line = []
    for i in range(len(command_line)):
        flag = command_line[i]
        if flag in ["--sysroot", "-isystem", "-iquote"]:
            if i + 1 < len(command_line):
                new_command_line.append(flag)
                new_command_line.append(command_line[i + 1])
            else:
                pass

    command_line = new_command_line

    args.add_all(command_line)

    if (cc_toolchain):
        args.add_all(cc_toolchain.built_in_include_directories, before_each = "-isystem")

    inputs = depset(direct = [hdr], transitive = [compilation_context.headers, cc_toolchain.all_files])
    ctx.actions.run_shell(
        command = "${{@}} > {}".format(zig_out.path),
        inputs = inputs,
        outputs = [zig_out],
        arguments = [zigtoolchaininfo.zig_exe.path, "translate-c", zig_config_args, args],
        mnemonic = "ZigTranslateC",
        progress_message = "zig translate-c {}".format(ctx.label.name),
        execution_requirements = {tag: "" for tag in ctx.attr.tags},
        tools = zigtoolchaininfo.zig_files,
        toolchain = "//zig:toolchain_type",
    )

    return zig_module_info(
        name = "c",
        canonical_name = "{}/c".format(str(ctx.label)),
        main = zig_out,
    )
