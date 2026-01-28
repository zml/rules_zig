"""Implementation of the zig_asm rule.

This rule emits assembly output (.s) from Zig sources, using the common build
implementation in `//zig/private/common:zig_build.bzl`.
"""

load(
    "//zig/private/common:zig_build.bzl",
    "zig_build_impl",
    COMMON_ATTRS = "ATTRS",
    COMMON_FRAGMENTS = "FRAGMENTS",
    COMMON_TOOLCHAINS = "TOOLCHAINS",
)

DOC = """\
Builds Zig sources into an assembly file.

The target can be built using `bazel build`, corresponding roughly to
invoking Zig to compile and emit assembly output (without emitting a binary).

The default output is a single `.s` file named after the target.

**EXAMPLE**

```bzl
load("@rules_zig//zig:defs.bzl", "zig_asm")

zig_asm(
    name = "my-asm",
    main = "main.zig",
    srcs = [
        "utils.zig",  # to support `@import("utils.zig")`.
    ],
    deps = [
        ":my-module",  # to support `@import("my-module")`.
    ],
)
```
"""

ATTRS = COMMON_ATTRS

TOOLCHAINS = COMMON_TOOLCHAINS

FRAGMENTS = COMMON_FRAGMENTS

def _zig_asm_impl(ctx):
    providers, groups = zig_build_impl(ctx, kind = "zig_asm")
    return providers + [OutputGroupInfo(**groups)]

zig_asm = rule(
    _zig_asm_impl,
    attrs = ATTRS,
    doc = DOC,
    toolchains = TOOLCHAINS,
    fragments = FRAGMENTS,
)
