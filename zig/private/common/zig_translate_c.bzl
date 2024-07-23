load("//zig/private/providers:zig_module_info.bzl", "zig_module_info")

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
    args.add_all(compilation_context.defines, format_each = "-D%s")
    args.add_all(compilation_context.includes, format_each = "-I%s")

    args.add_all(compilation_context.quote_includes, format_each = "-I%s")
    args.add_all(compilation_context.system_includes, before_each = "-isystem")
    if hasattr(compilation_context, "external_includes"):
        # Added in Bazel 7, see https://github.com/bazelbuild/bazel/commit/a6ef0b341a8ffe8ab27e5ace79d8eaae158c422b
        args.add_all(compilation_context.external_includes, before_each = "-isystem")
    args.add_all(compilation_context.framework_includes, format_each = "-F%s")

    inputs = depset(direct = [hdr], transitive = [compilation_context.headers])
    ctx.actions.run_shell(
        command = "exec ${{@}} > {}".format(zig_out.path),
        inputs = inputs,
        outputs = [zig_out],
        arguments = [zigtoolchaininfo.zig_exe.path, "translate-c", zig_config_args, args],
        progress_message = "zig translate-c {}".format(ctx.label.name),
        tools = [
            zigtoolchaininfo.zig_exe,
            zigtoolchaininfo.zig_lib,
        ],
    )

    return zig_module_info(
        name = "c",
        canonical_name = "{}/c".format(str(ctx.label)),
        main = zig_out,
    )
