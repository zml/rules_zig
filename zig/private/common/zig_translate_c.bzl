load("//zig/private/providers:zig_module_info.bzl", "zig_module_info")
load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cc_toolchain")
load("@rules_cc//cc:action_names.bzl", "C_COMPILE_ACTION_NAME")

# { option: takes_value }
# translate-c only supports a limited set of clang options.
_TRANSLATE_C_OPTIONS_ALLOW_LIST = {
    "-isystem": True,
    "-idirafter": True,
    "-I": False,
    "-D": False,
}

def _find_option_argument(command_line, option_name):
    for i in range(len(command_line)):
        arg = command_line[i]
        if arg.startswith(option_name + "="):
            # Case: --option=value or -isystem=/path
            return arg.split("=", 1)[1]
        elif arg == option_name:
            # Case: --option value or -isystem /path
            if i + 1 < len(command_line):
                return command_line[i + 1]
    return None  # Not found

def _filter_options(command_line, allow_list):
    filtered_command_line = []
    skip_next = False
    for i in range(len(command_line)):
        if skip_next:
            skip_next = False
            continue

        arg = command_line[i]
        # Check for exact match, possibly with '='
        option_name = arg.split("=", 1)[0]
        if option_name in allow_list:
            expects_value = allow_list[option_name]
            if "=" in arg:
                # Handle options like -isystem=/path (=value)
                filtered_command_line.append(arg)
            else:
                # Handle the separate forms like -isystem /path
                filtered_command_line.append(arg)
                if expects_value and i + 1 < len(command_line):
                    filtered_command_line.append(command_line[i + 1])
                    skip_next = True
        else:
            # Handle options like -I/usr/include (prefix match)
            for opt in allow_list:
                if not allow_list[opt] and arg.startswith(opt):
                    filtered_command_line.append(arg)
                    break

    return filtered_command_line

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

    additional_args = []
    additional_inputs = []
    if cc_toolchain:
        args.add_all(cc_toolchain.built_in_include_directories, before_each = "-isystem")

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

        # extracting possible sysroot before filtering the command line
        sysroot = _find_option_argument(command_line, "--sysroot")
        command_line = _filter_options(command_line, _TRANSLATE_C_OPTIONS_ALLOW_LIST)

        args.add_all(command_line)

        if cc_toolchain.sysroot:
            sysroot = cc_toolchain.sysroot

        if sysroot:
            libc_txt = ctx.actions.declare_file("libc.txt")
            ctx.actions.write(
                libc_txt,
                """include_dir={include_dir}
sys_include_dir={sys_include_dir}
crt_dir=
msvc_lib_dir=
kernel32_lib_dir=
gcc_dir=
""".format(
                include_dir = "{}/usr/include".format(sysroot),
                sys_include_dir = "{}/usr/include".format(sysroot),
                ),
            )
            additional_args.append("--libc")
            additional_args.append(libc_txt.path)
            additional_inputs.append(libc_txt)

    args.add_all(additional_args)

    inputs = depset(direct = [hdr] + additional_inputs, transitive = [compilation_context.headers, cc_toolchain.all_files])
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
