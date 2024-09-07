"""Implementation of the zig_toolchain rule."""

load("@bazel_skylib//lib:paths.bzl", "paths")
load("//zig/private/providers:zig_toolchain_info.bzl", "ZigToolchainInfo")

DOC = """\
Defines a Zig compiler toolchain.

The Zig compiler toolchain, defined by the `zig_toolchain` rule,
has builtin cross-compilation support.
Meaning, most Zig toolchains can target any platform supported by Zig
independent of the execution platform.

Therefore, there is no need to couple the execution platform
with the target platform, at least not by default.

This rule configures a Zig compiler toolchain
and the corresponding Bazel execution platform constraints
can be declared using the builtin `toolchain` rule.

You will rarely need to invoke this rule directly.
Instead, use `zig_register_toolchains`
provided by `@rules_zig//zig:repositories.bzl`.

Use the target `@rules_zig//zig:resolved_toolchain`
to access the resolved toolchain for the current execution platform.

See https://bazel.build/extending/toolchains#defining-toolchains.
"""

ATTRS = {
    "zig_exe": attr.label(
        doc = "A hermetically downloaded Zig executable for the target platform.",
        mandatory = True,
        executable = True,
        cfg = "exec",
        allow_single_file = True,
    ),
    "zig_lib": attr.label(
        doc = "Path of a hermetically downloaded Zig library for the target platform.",
        mandatory = True,
        allow_single_file = True,
    ),
    "zig_lib_srcs": attr.label_list(
        doc = "Files of a hermetically downloaded Zig library for the target platform.",
        mandatory = True,
        allow_files = True,
    ),
    "zig_h": attr.label(
        doc = "zig.h header file",
        mandatory = True,
        allow_single_file = True,
    ),
    "zig_version": attr.string(
        doc = "The Zig toolchain's version.",
        mandatory = True,
    ),
    "zig_cache": attr.string(
        doc = "The Zig cache directory prefix. Used for both the global and local cache.",
        mandatory = True,
    ),
}

def _zig_toolchain_impl(ctx):
    zig_version = ctx.attr.zig_version
    zig_cache = ctx.attr.zig_cache
    zig_files = depset(direct = ctx.files.zig_lib_srcs + [ctx.file.zig_exe])

    # Make the $(tool_BIN) variable available in places like genrules.
    # See https://docs.bazel.build/versions/main/be/make-variables.html#custom_variables
    template_variables = platform_common.TemplateVariableInfo({
        "ZIG_BIN": ctx.file.zig_exe.path,
        "ZIG_LIB_DIR": ctx.file.zig_lib.path,
    })

    default = DefaultInfo(
        files = zig_files,
        runfiles = ctx.runfiles(transitive_files = zig_files),
    )

    zigtoolchaininfo = ZigToolchainInfo(
        zig_exe = ctx.executable.zig_exe,
        zig_lib_path = ctx.file.zig_lib.path,
        zig_files = zig_files,
        zig_hdrs_ccinfo = CcInfo(
            compilation_context = cc_common.create_compilation_context(
                headers = depset([ctx.file.zig_h]),
                quote_includes = depset([ctx.file.zig_h.dirname]),
                defines = depset(["ZIG_TARGET_MAX_INT_ALIGNMENT=_Alignof(struct { long long __ll; long double __ld; })"]),
            ),
        ),
        zig_version = zig_version,
        zig_cache = zig_cache,
    )

    # Export all the providers inside our ToolchainInfo
    # so the resolved_toolchain rule can grab and re-export them.
    toolchain_info = platform_common.ToolchainInfo(
        zigtoolchaininfo = zigtoolchaininfo,
        template_variables = template_variables,
        default = default,
    )

    return [
        default,
        toolchain_info,
        template_variables,
    ]

zig_toolchain = rule(
    implementation = _zig_toolchain_impl,
    attrs = ATTRS,
    doc = DOC,
)
