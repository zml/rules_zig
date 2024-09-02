"""Implementation of the zig_module rule."""

load(
    "//zig/private/common:bazel_builtin.bzl",
    "bazel_builtin_module",
    BAZEL_BUILTIN_ATTRS = "ATTRS",
)
load("//zig/private/common:data.bzl", "zig_collect_data", "zig_create_runfiles")
load("//zig/private/common:filetypes.bzl", "ZIG_SOURCE_EXTENSIONS")
load(
    "//zig/private/providers:zig_module_info.bzl",
    "ZigModuleInfo",
    "zig_module_info",
)

DOC = """\
Defines a Zig module.

A Zig module is a collection of Zig sources with a main source file
that defines the module's entry point.

This rule does not perform compilation by itself.
Instead, modules are compiled at the use-site.
Zig performs whole program compilation.

**EXAMPLE**

```bzl
load("@rules_zig//zig:defs.bzl", "zig_module")

zig_module(
    name = "my-module",
    main = "main.zig",
    srcs = [
        "utils.zig",  # to support `@import("utils.zig")`.
    ],
    deps = [
        ":other-module",  # to support `@import("other-module")`.
    ],
)
```
"""

ATTRS = {
    "main": attr.label(
        allow_single_file = True,
        doc = "The main source file.",
        mandatory = True,
    ),
    "import_name": attr.string(
        doc = "The import name of the module.",
        mandatory = False,
    ),
    "srcs": attr.label_list(
        allow_files = ZIG_SOURCE_EXTENSIONS,
        doc = "Other Zig source files required when building the module, e.g. files imported using `@import`.",
        mandatory = False,
    ),
    "extra_srcs": attr.label_list(
        allow_files = True,
        doc = "Other files required when building the module, e.g. files embedded using `@embedFile`.",
        mandatory = False,
    ),
    "copts": attr.string_list(
        doc = "Zig compiler flags required to build the sources of the target. Subject to location expansion.",
        mandatory = False,
    ),
    "linkopts": attr.string_list(
        doc = "Zig linker flags required to build the sources of the target. Subject to location expansion.",
        mandatory = False,
    ),
    "deps": attr.label_list(
        doc = "Other modules required when building the module.",
        mandatory = False,
        # providers = [ZigModuleInfo],
    ),
    "data": attr.label_list(
        allow_files = True,
        doc = "Files required by the module during runtime.",
        mandatory = False,
    ),
} | BAZEL_BUILTIN_ATTRS

def _zig_module_impl(ctx):
    transitive_data = []
    transitive_runfiles = []

    zig_collect_data(
        data = ctx.attr.data,
        deps = ctx.attr.deps,
        transitive_data = transitive_data,
        transitive_runfiles = transitive_runfiles,
    )

    default = DefaultInfo(
        runfiles = zig_create_runfiles(
            ctx_runfiles = ctx.runfiles,
            direct_data = [],
            transitive_data = transitive_data,
            transitive_runfiles = transitive_runfiles,
        ),
    )

    bazel_builtin = bazel_builtin_module(ctx)

    zdeps = [bazel_builtin]
    cdeps = []
    for dep in ctx.attr.deps:
        if ZigModuleInfo in dep:
            zdeps.append(dep[ZigModuleInfo])
        elif CcInfo in dep:
            cdeps.append(dep[CcInfo])

    module = zig_module_info(
        name = ctx.attr.import_name or ctx.label.name,
        canonical_name = str(ctx.label),
        main = ctx.file.main,
        srcs = ctx.files.srcs,
        extra_srcs = ctx.files.extra_srcs,
        copts =  ctx.attr.copts,
        linkopts = ctx.attr.linkopts,
        deps = zdeps,
        cdeps = cdeps,
    )

    return [default, module]

zig_module = rule(
    _zig_module_impl,
    attrs = ATTRS,
    doc = DOC,
    toolchains = ["//zig:toolchain_type"],
)
