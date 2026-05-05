"""Bootstrap rule for the Zig persistent worker."""

def _zig_worker_binary_impl(ctx):
    zigtoolchaininfo = ctx.toolchains["//zig:toolchain_type"].zigtoolchaininfo
    worker_bootstrap_cache = "bazel-out/rules_zig_worker_cache/bootstrap/{}".format(zigtoolchaininfo.zig_version)

    output = ctx.actions.declare_file(ctx.label.name + (".exe" if ctx.target_platform_has_constraint(ctx.attr._windows_constraint[platform_common.ConstraintValueInfo]) else ""))

    args = ctx.actions.args()
    args.add("build-exe")
    args.add(ctx.file.src)
    args.add("-O")
    args.add("ReleaseSafe")
    args.add("--zig-lib-dir")
    args.add(zigtoolchaininfo.zig_lib_path)
    args.add("--cache-dir")
    args.add(worker_bootstrap_cache)
    args.add("--global-cache-dir")
    args.add(worker_bootstrap_cache)
    args.add("-femit-bin={}".format(output.path))

    ctx.actions.run(
        executable = zigtoolchaininfo.zig_exe_path,
        arguments = [args],
        inputs = [ctx.file.src],
        outputs = [output],
        tools = zigtoolchaininfo.zig_files,
        env = {
            "ZIG_GLOBAL_CACHE_DIR": worker_bootstrap_cache,
            "ZIG_LIB_DIR": zigtoolchaininfo.zig_lib_path,
            "ZIG_LOCAL_CACHE_DIR": worker_bootstrap_cache,
        },
        mnemonic = "ZigBuildWorker",
        progress_message = "zig build worker %{label}",
        toolchain = "//zig:toolchain_type",
    )

    return [
        DefaultInfo(
            executable = output,
            files = depset([output]),
        ),
    ]

zig_worker_binary = rule(
    implementation = _zig_worker_binary_impl,
    attrs = {
        "src": attr.label(
            allow_single_file = [".zig"],
            mandatory = True,
        ),
        "_windows_constraint": attr.label(
            default = "@platforms//os:windows",
        ),
    },
    executable = True,
    toolchains = ["//zig:toolchain_type"],
)
