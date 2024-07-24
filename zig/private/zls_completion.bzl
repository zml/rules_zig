load("//zig/private/common:zig_build.bzl", "TOOLCHAINS")
load("//zig/private/common:zig_cache.bzl", "zig_cache_output")
load("//zig/private/common:zig_lib_dir.bzl", "zig_lib_dir")
load("//zig/private/common:zig_translate_c.bzl", "zig_translate_c")
load("//zig/private/providers:zig_module_info.bzl", "ZigModuleInfo", "add_module_files")

_TPL = """\
#!/bin/bash
cat <<EOF
{json}
EOF
"""

def _add_package(packages, srcs, mod):
    add_module_files(srcs, mod)
    packages.append(struct(
        name = mod.name,
        path = "$(realpath {})".format(mod.main.short_path),
    ))

def _zls_completion_impl(ctx):
    direct = []
    transitive = []
    for dep in ctx.attr.deps:
        zmi = dep[ZigModuleInfo]
        direct.append(zmi)
        transitive.append(zmi.transitive_deps)

    srcs = []
    packages = []
    for mod in depset(direct = direct, transitive = transitive).to_list():
        _add_package(packages, srcs, mod)

    cdeps = depset(transitive = [mod.transitive_cdeps for mod in direct]).to_list()
    if (cdeps):
        zigtoolchaininfo = ctx.toolchains["//zig:toolchain_type"].zigtoolchaininfo
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
        c_module = zig_translate_c(
            ctx = ctx,
            zigtoolchaininfo = zigtoolchaininfo,
            zig_config_args = zig_config_args,
            cc_infos = cdeps,
        )
        _add_package(packages, srcs, c_module)

    runner = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.write(runner, _TPL.format(
        json = json.encode(
            struct(
                deps_build_roots = [],
                packages = packages,
                include_dirs = [],
                available_options = {},
            )
        ),
    ))

    return [
        DefaultInfo(
            files = depset(direct = [runner], transitive = srcs),
            executable = runner,
            runfiles = ctx.runfiles(transitive_files = depset(transitive = srcs)),
        )
    ]

zls_completion = rule(
    implementation = _zls_completion_impl,
    attrs = {
        "deps": attr.label_list(
            providers = [ZigModuleInfo],
            mandatory = True,
        ),
    },
    toolchains = TOOLCHAINS,
    executable =  True,
)
