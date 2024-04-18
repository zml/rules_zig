"""Create a repository to hold the toolchains

This follows guidance here:
https://docs.bazel.build/versions/main/skylark/deploying.html#registering-toolchains
"
Note that in order to resolve toolchains in the analysis phase
Bazel needs to analyze all toolchain targets that are registered.
Bazel will not need to analyze all targets referenced by toolchain.toolchain attribute.
If in order to register toolchains you need to perform complex computation in the repository,
consider splitting the repository with toolchain targets
from the repository with <LANG>_toolchain targets.
Former will be always fetched,
and the latter will only be fetched when user actually needs to build <LANG> code.
"
The "complex computation" in our case is simply downloading large artifacts.
This guidance tells us how to avoid that: we put the toolchain targets in the alias repository
with only the toolchain attribute pointing into the platform-specific repositories.
"""

load("//zig/private/common:semver.bzl", "semver")

# Add more platforms as needed to mirror all the binaries
# published by the upstream project.
PLATFORMS = {
    "aarch64-linux": struct(
        compatible_with = [
            "@platforms//os:linux",
            "@platforms//cpu:aarch64",
        ],
    ),
    "aarch64-macos": struct(
        compatible_with = [
            "@platforms//os:macos",
            "@platforms//cpu:aarch64",
        ],
    ),
    "aarch64-windows": struct(
        compatible_with = [
            "@platforms//os:windows",
            "@platforms//cpu:aarch64",
        ],
    ),
    "x86_64-linux": struct(
        compatible_with = [
            "@platforms//os:linux",
            "@platforms//cpu:x86_64",
        ],
    ),
    "x86_64-macos": struct(
        compatible_with = [
            "@platforms//os:macos",
            "@platforms//cpu:x86_64",
        ],
    ),
    "x86_64-windows": struct(
        compatible_with = [
            "@platforms//os:windows",
            "@platforms//cpu:x86_64",
        ],
    ),
}

def sanitize_version(zig_version):
    """Replace any illegal workspace name characters in the Zig version."""
    return zig_version.replace("+", "_P")

def _calc_counter_digits(num):
    """Determine the number of digits required for the counter prefix.

    Uses at least four digits to avoid unnecessary invalidation when the number
    of toolchains changes in slightly in most common use-cases.
    """
    return max(4, len(repr(num)))

def _counter_prefix(count, *, width):
    """Render the counter prefix.

    Args:
      count: int, The counter value.
      width: int, The number of digits to use.
    """
    count_repr = repr(count)
    prefix = "0" * (width - len(count_repr))
    return prefix + count_repr

def _toolchains_repo_impl(repository_ctx):
    if len(repository_ctx.attr.zig_versions) < 1:
        fail("Must specify at least one Zig SDK version in `zig_versions`.")

    build_content = """\
# Generated by toolchains_repo.bzl
#
# These can be registered in the workspace file or passed to --extra_toolchains flag.
# By default all these toolchains are registered by the zig_register_toolchains macro
# so you don't normally need to interact with these targets.

load("@bazel_skylib//lib:selects.bzl", "selects")
load("@bazel_skylib//rules:common_settings.bzl", "string_flag")
"""

    build_content += """
# Use this build flag to select the Zig SDK version. E.g.
#
#     $ bazel build --@zig_toolchains//:version=0.11.0 //...
#
string_flag(
    name = "version",
    values = {zig_versions},
    build_setting_default = {default_version},
)
""".format(
        zig_versions = repr(repository_ctx.attr.zig_versions),
        default_version = repr(repository_ctx.attr.zig_versions[0]),
    )

    for zig_version in repository_ctx.attr.zig_versions:
        build_content += """
# Use this configuration setting in `select` or `target_compatible_with` to
# change the target based on the Zig version or declare compatibility with a
# specific set of versions.
config_setting(
    name = "{zig_version}",
    flag_values = {{
        ":version": "{zig_version}",
    }},
    visibility = ["//visibility:public"],
)
""".format(
            zig_version = zig_version,
        )

    grouped = semver.grouped(repository_ctx.attr.zig_versions)
    for grouping in ["major", "minor", "patch"]:
        for group, versions in getattr(grouped, grouping).items():
            build_content += """
# Use this configuration setting in `select` or `target_compatible_with` to
# change the target based on the Zig version or declare compatibility with a
# specific set of versions.
selects.config_setting_group(
    name = "any_{group}.release",
    match_any = {releases},
    visibility = ["//visibility:public"],
)
selects.config_setting_group(
    name = "any_{group}.pre_release",
    match_any = {pre_releases},
    visibility = ["//visibility:public"],
)
selects.config_setting_group(
    name = "any_{group}.",
    match_any = ["any_{group}.release", "any_{group}.pre_release"],
    visibility = ["//visibility:public"],
)
""".format(
                group = group,
                releases = repr(versions.release),
                pre_releases = repr(versions.pre_release),
            )

    counter_digits = _calc_counter_digits(len(repository_ctx.attr.zig_versions))

    for counter, zig_version in enumerate(repository_ctx.attr.zig_versions):
        sanitized_zig_version = sanitize_version(zig_version)
        for [platform, meta] in PLATFORMS.items():
            build_content += """
# Declare a toolchain Bazel will select for running the tool in an action
# on the execution platform.
toolchain(
    name = "{prefix}_{version}_{platform}_toolchain",
    exec_compatible_with = {compatible_with},
    target_settings = [":{version}"],
    toolchain = "@{user_repository_name}_{sanitized_version}_{platform}//:zig_toolchain",
    toolchain_type = "@rules_zig//zig:toolchain_type",
)
""".format(
                prefix = _counter_prefix(counter, width = counter_digits),
                version = zig_version,
                sanitized_version = sanitized_zig_version,
                platform = platform,
                name = repository_ctx.attr.name,
                user_repository_name = repository_ctx.attr.user_repository_name,
                compatible_with = meta.compatible_with,
            )

    # Base BUILD file for this repository
    repository_ctx.file("BUILD.bazel", build_content)

toolchains_repo = repository_rule(
    _toolchains_repo_impl,
    doc = """Creates a repository with toolchain definitions for all known platforms
     which can be registered or selected.""",
    attrs = {
        "user_repository_name": attr.string(doc = "what the user chose for the base name"),
        "zig_versions": attr.string_list(doc = "the defined Zig SDK versions"),
    },
)
