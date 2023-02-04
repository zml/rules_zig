"""Implementation of the zig_binary rule."""

load("//zig/private/common:zig_cache.bzl", "zig_cache_output")
load("//zig/private:filetypes.bzl", "ZIG_SOURCE_EXTENSIONS")
load(
    "//zig/private/providers:zig_package_info.bzl",
    "ZigPackageInfo",
    "add_package_flags",
    "get_package_files",
)

DOC = """\
"""

ATTRS = {
    "main": attr.label(
        allow_single_file = ZIG_SOURCE_EXTENSIONS,
        doc = "The main source file.",
        mandatory = True,
    ),
    "srcs": attr.label_list(
        allow_files = ZIG_SOURCE_EXTENSIONS,
        doc = "Other source files required to build the target.",
        mandatory = False,
    ),
    "deps": attr.label_list(
        doc = "Packages or libraries required to build the target.",
        mandatory = False,
        providers = [ZigPackageInfo],
    ),
}

def _zig_binary_impl(ctx):
    ziginfo = ctx.toolchains["//zig:toolchain_type"].ziginfo

    outputs = []

    args = ctx.actions.args()
    args.use_param_file("@%s")

    # TODO[AH] Append `.exe` extension on Windows.
    output = ctx.actions.declare_file(ctx.label.name)
    outputs.append(output)

    # TODO[AH] Factor out common dependency management code.
    direct_inputs = [ctx.file.main] + ctx.files.srcs
    transitive_inputs = []

    args.add(output, format = "-femit-bin=%s")
    args.add(ctx.file.main)

    # TODO[AH] Factor out common dependency management code.
    for dep in ctx.attr.deps:
        if ZigPackageInfo in dep:
            package = dep[ZigPackageInfo]
            transitive_inputs.append(get_package_files(package))
            add_package_flags(args, package)

    zig_cache_output(
        actions = ctx.actions,
        name = ctx.label.name,
        outputs = outputs,
        args = args,
    )

    ctx.actions.run(
        outputs = outputs,
        inputs = depset(direct = direct_inputs, transitive = transitive_inputs),
        executable = ziginfo.target_tool_path,
        tools = ziginfo.tool_files,
        arguments = ["build-exe", args],
        mnemonic = "ZigBuildExe",
        progress_message = "Building %{input} as Zig binary %{output}",
        execution_requirements = {tag: "" for tag in ctx.attr.tags},
    )

    default = DefaultInfo(
        executable = output,
        files = depset([output]),
        runfiles = ctx.runfiles(files = [output]),
    )

    return [default]

zig_binary = rule(
    _zig_binary_impl,
    attrs = ATTRS,
    doc = DOC,
    toolchains = ["//zig:toolchain_type"],
)
