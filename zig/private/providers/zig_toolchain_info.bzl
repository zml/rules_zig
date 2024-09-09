"""Defines providers for the Zig toolchain rule."""

DOC = """\
Information about how to invoke the Zig executable.
"""

FIELDS = {
    "zig_exe": "Path to the Zig executable for the target platform.",
    "zig_lib_path": "Path to the Zig library directory for the target platform.",
    "zig_files": "Depset of Files of the Zig library directory for the target platform.",
    "zig_docs": "",
    "zig_hdrs_ccinfo": "zig headers CcInfo",
    "zig_version": "String, The Zig toolchain's version.",
    "zig_cache": "String, The Zig cache directory prefix used for the global and local cache.",
}

ZigToolchainInfo = provider(
    doc = DOC,
    fields = FIELDS,
)
