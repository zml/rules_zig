"""Implementation of the `zig_repository` repository rule."""

load("@bazel_tools//tools/build_defs/repo:utils.bzl", "update_attrs")
load(
    "//zig/private/common:zig_cache.bzl",
    "VAR_CACHE_PREFIX",
    "VAR_CACHE_PREFIX_LINUX",
    "VAR_CACHE_PREFIX_MACOS",
    "VAR_CACHE_PREFIX_WINDOWS",
    "env_zig_cache_prefix",
)

DOC = "Fetch and install a Zig toolchain."

ATTRS = {
    "url": attr.string(mandatory = True, doc = "The URL to the Zig SDK release archive."),
    "sha256": attr.string(mandatory = False, doc = "The expected SHA-256 of the downloaded artifact. Provide only one of `sha256` or `integrity`."),
    "integrity": attr.string(mandatory = False, doc = "The expected checksum of the downloaded artifact in Subresource Integrity format. Provide only one of `sha256` or `integrity`."),
    "zig_version": attr.string(mandatory = True, doc = "The Zig SDK version number."),
    "platform": attr.string(mandatory = True, doc = "The platform that the Zig SDK can execute on, e.g. `x86_64-linux` or `aarch64-macos`."),
}

ENV = [
    VAR_CACHE_PREFIX,
    VAR_CACHE_PREFIX_LINUX,
    VAR_CACHE_PREFIX_MACOS,
    VAR_CACHE_PREFIX_WINDOWS,
]

def _basename(path):
    return path.rpartition("/")[-1]

def _split_extension(basename):
    pos = basename.rfind(".")

    if pos <= 0:
        return (basename, "")

    from_end = len(basename) - pos
    return (basename[:-from_end], basename[-from_end:])

def _get_strip_prefix(*, url):
    basename0 = _basename(url)
    basename1, _ = _split_extension(basename0)
    basename2, ext2 = _split_extension(basename1)

    if ext2 == ".tar":
        strip_prefix = basename2
    else:
        strip_prefix = basename1

    return strip_prefix

def _get_integrity_args(*, sha256, integrity):
    result = {}

    if sha256 and integrity:
        fail("You may only specify one of `sha256` or `integrity`.")
    elif sha256:
        result["sha256"] = sha256
    elif integrity:
        result["integrity"] = integrity

    return result

def _zig_repository_impl(repository_ctx):
    cache_prefix = env_zig_cache_prefix(
        repository_ctx.os.environ,
        repository_ctx.attr.platform,
    )

    zig_exe = "zig"
    if repository_ctx.attr.platform.find("windows") != -1:
        zig_exe = "zig.exe"

    build_content = """\
# Generated by zig/private/repo/zig_repository.bzl

load("@rules_zig//zig:toolchain.bzl", "zig_toolchain")

zig_toolchain(
    name = "zig_toolchain",
    zig_exe = {zig_exe},
    zig_lib = "lib",
    zig_lib_srcs = glob(["lib/**"]),
    zig_h = "lib/zig.h",
    zig_version = {zig_version},
    zig_cache = {zig_cache},
)
""".format(
        zig_cache = repr(cache_prefix),
        zig_exe = repr(zig_exe),
        zig_version = repr(repository_ctx.attr.zig_version),
    )

    repository_ctx.file("BUILD.bazel", build_content)

    download_args = {
        "url": repository_ctx.attr.url,
        "stripPrefix": _get_strip_prefix(url = repository_ctx.attr.url),
    }
    integrity = _get_integrity_args(
        sha256 = repository_ctx.attr.sha256,
        integrity = repository_ctx.attr.integrity,
    )
    download_args.update(**integrity)

    download = repository_ctx.download_and_extract(**download_args)

    integrity_override = {} if integrity else {"integrity": download.integrity}

    return update_attrs(repository_ctx.attr, ATTRS.keys(), integrity_override)

zig_repository = repository_rule(
    _zig_repository_impl,
    attrs = ATTRS,
    doc = DOC,
    environ = ENV,
)
