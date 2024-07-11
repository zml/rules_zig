load("//zig/private/providers:zig_module_info.bzl", "ZigModuleInfo")

_TPL = """\
#!/bin/bash
cat <<EOF
{json}
EOF
"""

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
        srcs.append(depset(direct = tuple((mod.main,)) + mod.srcs + mod.extra_srcs))
        packages.append(struct(
            name = mod.name,
            path = "$(realpath {})".format(mod.main.short_path),
        ))

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
    executable =  True,
)
