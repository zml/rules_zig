def _zig_cache_impl(repository_ctx):
    repository_ctx.file(".marker", "")
    repository_ctx.file("BUILD.bazel", """exports_files([".marker"])""")
    repository_ctx.file("WORKSPACE.bazel", "")

zig_cache = repository_rule(
    _zig_cache_impl,
)
