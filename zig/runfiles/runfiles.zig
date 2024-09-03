//! Implements a Bazel runfiles library for rules_zig. Follows the runfiles
//! specification as of the [original design][runfiles-design], and the
//! [extended design for bzlmod support][runfiles-bzlmod].
//!
//! [runfiles-design]: https://docs.google.com/document/d/e/2PACX-1vSDIrFnFvEYhKsCMdGdD40wZRBX3m3aZ5HhVj4CtHPmiXKDCxioTUbYsDydjKtFDAzER5eg7OjJWs3V/pub
//! [runfiles-bzlmod]: https://github.com/bazelbuild/proposals/blob/53c5691c3f08011f0abf1d840d5824a3bbe039e2/designs/2022-07-21-locating-runfiles-with-bzlmod.md#2-extend-the-runfiles-libraries-to-take-repository-mappings-into-account
//!
//! Read the [Zig Runfiles Guide](#G;) for further information.
//!
//!zig-autodoc-guide: guide.md

const builtin = @import("builtin");
const std = @import("std");

pub const Runfiles = @import("src/Runfiles.zig");

/// Ensure argv and env are available to the standard library when built as a
/// library.
const init_array_section = switch (builtin.object_format) {
    .macho => "__DATA,__init_array",
    .elf => ".init_array",
    else => "",
};

const fix_argv linksection(init_array_section) = &struct {
    pub fn call(argc: c_int, argv: [*c][*:0]u8, envp: [*:null]?[*:0]u8) callconv(.C) void {
        std.os.argv = argv[0..@intCast(argc)];
        std.os.environ = @ptrCast(envp[0..std.mem.len(envp)]);
    }
}.call;

comptime {
    if (builtin.output_mode != .Exe) {
        switch (builtin.object_format) {
            .elf, .macho => _ = fix_argv,
            else => {},
        }
    }
}

test {
    _ = @import("src/Directory.zig");
    _ = @import("src/discovery.zig");
    _ = @import("src/Manifest.zig");
    _ = @import("src/RepoMapping.zig");
    _ = @import("src/RPath.zig");
    _ = @import("src/Runfiles.zig");
}

test Runfiles {
    var allocator = std.testing.allocator;

    var r_ = try Runfiles.create(.{ .allocator = allocator }) orelse
        return error.RunfilesNotFound;
    defer r_.deinit(allocator);

    // Runfiles lookup is subject to repository remapping. You must pass the
    // name of the repository relative to which the runfiles path is valid.
    // Use the auto-generated `bazel_builtin` module to obtain it.
    const source_repo = @import("bazel_builtin").current_repository;
    const r = r_.withSourceRepo(source_repo);

    // Runfiles paths have the form `WORKSPACE/PACKAGE/FILE`.
    // Use `$(rlocationpath ...)` expansion in your `BUILD.bazel` file to
    // obtain one. You can forward it to your executable using the `env` or
    // `args` attribute, or by embedding it in a generated file.
    const rpath = "rules_zig/zig/runfiles/test-data.txt";

    const allocated_path = try r.rlocationAlloc(allocator, rpath) orelse
        // Runfiles path lookup may return `null`.
        return error.RPathNotFound;
    defer allocator.free(allocated_path);

    const file = std.fs.openFileAbsolute(allocated_path, .{}) catch |e| switch (e) {
        error.FileNotFound => {
            // Runfiles path lookup may return a non-existent path.
            return error.RPathNotFound;
        },
        else => |e_| return e_,
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 4096);
    defer allocator.free(content);

    try std.testing.expectEqualStrings("Hello World!\n", content);
}
