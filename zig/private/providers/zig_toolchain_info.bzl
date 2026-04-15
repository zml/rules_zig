"""Defines providers for the Zig toolchain rule."""

DOC = """\
Information about how to invoke the Zig executable.
"""

FIELDS = {
    "zig_exe_file": "File for the Zig executable.",
    "zig_h": "File for the Zig header at the root of the Zig lib directory.",
    "zig_lib": "File for the Zig lib source directory.",
    "zig_version": "String, The Zig toolchain's version.",
    "zig_cache": "String, The Zig cache directory prefix used for the global and local cache.",
    "translate_c": "Label, The translate-c label.",
}

ZigToolchainInfo = provider(
    doc = DOC,
    fields = FIELDS,
)
