"""Unit tests for Zig module extension."""

load("@bazel_skylib//lib:partial.bzl", "partial")
load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//zig/private/bzlmod:zig.bzl", "DEFAULT_VERSION", "handle_tags")

def _zig_versions_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(
        env,
        (None, [DEFAULT_VERSION]),
        handle_tags(struct(modules = [])),
        "should fall back to the default Zig SDK version",
    )

    asserts.equals(
        env,
        (None, ["0.1.0"]),
        handle_tags(struct(
            modules = [
                struct(
                    tags = struct(
                        toolchain = [
                            struct(
                                default = False,
                                zig_version = "0.1.0",
                            ),
                        ],
                    ),
                ),
            ],
        )),
        "should choose a single configured version",
    )

    return unittest.end(env)

_zig_versions_test = unittest.make(
    _zig_versions_test_impl,
)

def bzlmod_zig_test_suite(name):
    unittest.suite(
        name,
        partial.make(_zig_versions_test, size = "small"),
    )
