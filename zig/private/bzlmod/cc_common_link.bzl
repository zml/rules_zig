def _cc_common_link(rctx):
    rctx.file("BUILD.bazel", "")
    rctx.file("cc_common_link.bzl", """\
def cc_common_link(*args, **kwargs):
    return cc_common.link(*args, **kwargs)
""")

cc_common_link = repository_rule(
    implementation = _cc_common_link,
)
