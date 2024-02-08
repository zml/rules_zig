const std = @import("std");
const log = std.log.scoped(.runfiles);

const discovery = @import("discovery.zig");
const Directory = @import("Directory.zig");
const RepoMapping = @import("RepoMapping.zig");

const Self = @This();

directory: Directory,
repo_mapping: ?RepoMapping,

/// Quoting the runfiles design:
///
/// > Every language's library will have a similar interface: a Create method
/// > that inspects the environment and/or `argv[0]` to determine the runfiles
/// > strategy (manifest-based or directory-based; see below), initializes
/// > runfiles handling and returns a Runfiles object
///
/// TODO: The manifest-based strategy is not yet implemented.
pub fn create(options: discovery.DiscoverOptions) !Self {
    var directory = discover: {
        const result = try discovery.discoverRunfiles(options) orelse
            return error.RunfilesNotFound;
        switch (result) {
            .manifest => |path| {
                _ = path;
                return error.NotImplemented;
            },
            .directory => |path| {
                defer options.allocator.free(path);
                break :discover try Directory.init(options.allocator, path);
            },
        }
    };
    errdefer directory.deinit(options.allocator);

    var repo_mapping: ?RepoMapping = null;
    {
        const repo_mapping_path = try directory.rlocationUnmapped(options.allocator, .{
            .repo = "",
            .path = "_repo_mapping",
        });
        defer options.allocator.free(repo_mapping_path);
        if (std.fs.cwd().access(repo_mapping_path, .{}) != error.FileNotFound)
            // Bazel <7 with bzlmod disabled does not generate a repo-mapping.
            repo_mapping = try RepoMapping.init(options.allocator, repo_mapping_path)
        else
            log.warn("No repository mapping found. This is likely an error if you are using Bazel version >=7 with bzlmod enabled.", .{});
    }

    return Self{
        .directory = directory,
        .repo_mapping = repo_mapping,
    };
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    self.directory.deinit(allocator);
    if (self.repo_mapping) |*repo_mapping| repo_mapping.deinit(allocator);
}

/// Quoting the runfiles design:
///
/// > Every language's library will have a similar interface: an
/// > Rlocation(string) method that expects a runfiles-root-relative path
/// > (case-sensitive on Linux/macOS, case-insensitive on Windows) and returns
/// > the absolute path of the file, which is normalized (and lowercase on
/// > Windows) and uses "/" as directory separator on every platform (including
/// > Windows)
///
/// TODO: Rpath validation is not yet implemented.
///
/// TODO: Path normalization, in particular lower-case and '/' normalization on
///   Windows, is not yet implemented.
pub fn rlocation(
    self: *const Self,
    allocator: std.mem.Allocator,
    rpath: []const u8,
    source: []const u8,
) ![]const u8 {
    var repo: []const u8 = "";
    var path: []const u8 = rpath;
    if (std.mem.indexOfScalar(u8, rpath, '/')) |pos| {
        repo = rpath[0..pos];
        path = rpath[pos + 1 ..];
        if (self.repo_mapping) |repo_mapping| {
            if (repo_mapping.lookup(.{ .source = source, .target = repo })) |mapped|
                repo = mapped;
            // NOTE, the spec states that we should fail if no mapping is found
            // and the repo name is not canonical. However, this always fails
            // in WORKSPACE mode and is apparently an issue in the spec and
            // common runfiles library implementations do not follow this
            // pattern.
        }
    }
    return try self.directory.rlocationUnmapped(allocator, .{
        .repo = repo,
        .path = path,
    });
}
