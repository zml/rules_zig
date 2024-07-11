"""Rules to build and run Zig code.

Note, all Zig targets implicitly depend on an automatically generated Zig
module called `bazel_builtin` that exposes Bazel specific information such as
the current target name or current repository name.
"""

load("//zig/private:zig_binary.bzl", _zig_binary = "zig_binary", _BINARY_KIND = "BINARY_KIND")
load("//zig/private:zls_completion.bzl", _zls_completion = "zls_completion")
load(
    "//zig/private:zig_configure.bzl",
    _zig_configure = "zig_configure",
    _zig_configure_binary = "zig_configure_binary",
    _zig_configure_test = "zig_configure_test",
)
load("//zig/private:zig_module.bzl", _zig_module = "zig_module")
load("//zig/private:zig_test.bzl", _zig_test = "zig_test")

BINARY_KIND = _BINARY_KIND
zig_binary = _zig_binary
zig_library = _zig_module
zig_module = _zig_module
zig_test = _zig_test
zig_configure = _zig_configure
zig_configure_binary = _zig_configure_binary
zig_configure_test = _zig_configure_test
zls_completion = _zls_completion
