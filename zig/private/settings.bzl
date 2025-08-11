"""Implementation of the settings rule."""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("//zig/private/providers:zig_settings_info.bzl", "ZigSettingsInfo")

DOC = """\
Collection of all Zig build settings.

This rule is only intended for internal use.
It collects the values of all relevant build settings,
such as `@rules_zig//zig/settings:mode`.

You can build the settings target to obtain a JSON file
capturing all configured Zig build settings.
"""

ATTRS = {
    "mode": attr.label(
        doc = "The release mode setting.",
        mandatory = True,
    ),
    "linkmode": attr.label(
        doc = "The link mode setting.",
        mandatory = True,
    ),
    "single_threaded": attr.label(
        doc = "The Zig single-threaded setting.",
        mandatory = True,
    ),
    "strip": attr.bool(
        doc = "The strip setting.",
        mandatory = True,
    ),
    "copts": attr.label(
        doc = "Command line compiler options.",
        mandatory = True,
    ),
}

MODE_VALUES = ["auto", "debug", "release_safe", "release_small", "release_fast"]

LINKMODE_VALUES = ["zig", "cc"]

def _settings_impl(ctx):
    args = [
        "--build-id=sha1",
    ]

    mode = ctx.attr.mode[BuildSettingInfo].value
    if (mode == "auto"):
        mode = ctx.var["COMPILATION_MODE"] == "opt" and "release_safe" or "debug"
    args.extend(["-O", {
        "debug": "Debug",
        "release_safe": "ReleaseSafe",
        "release_small": "ReleaseSmall",
        "release_fast": "ReleaseFast",
    }[mode]])

    strip = ctx.attr.strip
    if (strip):
        args.append("-fstrip")

    single_threaded = ctx.attr.single_threaded[BuildSettingInfo].value
    if (single_threaded):
        args.append("-fsingle-threaded")

    copts = ctx.attr.copts[BuildSettingInfo].value
    args.extend(copts)

    linkmode = ctx.attr.linkmode[BuildSettingInfo].value

    settings_info = ZigSettingsInfo(
        mode = mode,
        single_threaded = single_threaded,
        strip = strip,
        linkmode = linkmode,
        args = args,
    )

    settings_json = ctx.actions.declare_file(ctx.label.name + ".json")
    ctx.actions.write(settings_json, json.encode(settings_info), is_executable = False)

    default_info = DefaultInfo(
        files = depset([settings_json]),
    )

    return [
        default_info,
        settings_info,
    ]

settings = rule(
    _settings_impl,
    attrs = ATTRS,
    doc = DOC,
)

string_list_repeatable_flag = rule(
    implementation = lambda ctx: BuildSettingInfo(value = ctx.build_setting_value),
    build_setting = config.string_list(flag = True, repeatable = True),
    attrs = {
        "scope": attr.string(
            doc = "The scope indicates where a flag can propagate to",
            default = "universal",
        ),
    },
    doc = "A string list-typed build setting that can be set on the command line",
)
