const std = @import("std");

const WorkerOptions = struct {
    zig_exe: []const u8,
    zig_version: []const u8,
};

const WorkRequest = struct {
    arguments: []const []const u8,
    request_id: i64,
    cancel: bool,
};

const WorkResponse = struct {
    exit_code: i32,
    output: []const u8,
    request_id: i64,
    was_cancelled: bool = false,
};

const RunResult = struct {
    exit_code: i32,
    output: []u8,
};

const ParsedOptions = struct {
    options: WorkerOptions,
    args: []const []const u8,
};

const Stream = enum { stdout, stderr };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();
    const raw_args = try init.minimal.args.toSlice(allocator);
    try mainImpl(allocator, io, raw_args);
}

fn mainImpl(allocator: std.mem.Allocator, io: std.Io, raw_args: []const []const u8) !void {
    var persistent = false;
    var startup_args: std.ArrayList([]const u8) = .empty;
    defer startup_args.deinit(allocator);

    for (raw_args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--persistent_worker")) {
            persistent = true;
        } else {
            try startup_args.append(allocator, arg);
        }
    }

    const remaining = try parseWorkerOptions(startup_args.items);
    const options = remaining.options;

    if (!persistent) {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(arena);
        try argv.append(arena, options.zig_exe);
        try appendExpandedArgs(arena, io, &argv, remaining.args);
        const result = try runZig(arena, io, argv.items);
        if (result.output.len > 0) {
            try writeAll(io, .stderr, result.output);
        }
        std.process.exit(@intCast(result.exit_code));
    }

    while (true) {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const line = (try readLine(arena, io)) orelse break;

        const request = parseWorkRequest(arena, line) catch |err| {
            const msg = try std.fmt.allocPrint(arena, "failed to parse WorkRequest: {s}\n", .{@errorName(err)});
            try writeWorkResponse(io, .{ .exit_code = 1, .output = msg, .request_id = 0 });
            continue;
        };

        if (request.cancel) {
            try writeWorkResponse(io, .{ .exit_code = 0, .output = "", .request_id = request.request_id, .was_cancelled = true });
            continue;
        }

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(arena);
        try argv.append(arena, options.zig_exe);
        try appendFilteredRequestArgs(arena, &argv, remaining.args);
        try appendFilteredRequestArgs(arena, &argv, request.arguments);
        try appendWorkerCacheArgs(arena, io, &argv, options.zig_version);

        const result = runZig(arena, io, argv.items) catch |err| result: {
            const msg = try std.fmt.allocPrint(arena, "failed to run zig: {s}\n", .{@errorName(err)});
            break :result RunResult{ .exit_code = 1, .output = msg };
        };

        try writeWorkResponse(io, .{
            .exit_code = result.exit_code,
            .output = result.output,
            .request_id = request.request_id,
        });
    }
}

fn parseWorkerOptions(args: []const []const u8) !ParsedOptions {
    var zig_exe: ?[]const u8 = null;
    var zig_version: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--zig-exe")) {
            i += 1;
            if (i >= args.len) return error.MissingZigExe;
            zig_exe = args[i];
        } else if (std.mem.eql(u8, args[i], "--zig-version")) {
            i += 1;
            if (i >= args.len) return error.MissingZigVersion;
            zig_version = args[i];
        } else {
            break;
        }
    }
    return .{
        .options = .{
            .zig_exe = zig_exe orelse return error.MissingZigExe,
            .zig_version = zig_version orelse "unknown",
        },
        .args = args[i..],
    };
}

fn appendExpandedArgs(allocator: std.mem.Allocator, io: std.Io, argv: *std.ArrayList([]const u8), args: []const []const u8) !void {
    for (args) |arg| {
        if (arg.len > 1 and arg[0] == '@' and !(arg.len > 2 and arg[1] == '@')) {
            const content = try readFileAlloc(allocator, io, arg[1..]);
            var it = std.mem.splitScalar(u8, content, '\n');
            while (it.next()) |line| {
                const trimmed = std.mem.trimEnd(u8, line, "\r");
                if (trimmed.len != 0) {
                    try argv.append(allocator, trimmed);
                }
            }
        } else {
            try argv.append(allocator, arg);
        }
    }
}

fn appendFilteredRequestArgs(allocator: std.mem.Allocator, argv: *std.ArrayList([]const u8), args: []const []const u8) !void {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--cache-dir") or std.mem.eql(u8, args[i], "--global-cache-dir")) {
            i += 1;
            continue;
        }
        try argv.append(allocator, args[i]);
    }
}

fn appendWorkerCacheArgs(allocator: std.mem.Allocator, io: std.Io, argv: *std.ArrayList([]const u8), zig_version: []const u8) !void {
    const cache = try std.fs.path.join(allocator, &.{ "bazel-out", "rules_zig_worker_cache", zig_version });
    try std.Io.Dir.cwd().createDirPath(io, cache);
    try argv.append(allocator, "--cache-dir");
    try argv.append(allocator, cache);
    try argv.append(allocator, "--global-cache-dir");
    try argv.append(allocator, cache);
}

fn readFileAlloc(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(32 * 1024 * 1024));
}

fn runZig(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !RunResult {
    const result = try std.process.run(allocator, io, .{ .argv = argv });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, result.stdout);
    try output.appendSlice(allocator, result.stderr);

    return .{
        .exit_code = switch (result.term) {
            .exited => |code| @intCast(code),
            else => 1,
        },
        .output = try output.toOwnedSlice(allocator),
    };
}

fn parseWorkRequest(allocator: std.mem.Allocator, line: []const u8) !WorkRequest {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});

    const root = parsed.value.object;
    const args_value = root.get("arguments") orelse return error.MissingArguments;
    const args_array = args_value.array;
    var args = try allocator.alloc([]const u8, args_array.items.len);
    errdefer allocator.free(args);

    for (args_array.items, 0..) |item, i| {
        args[i] = item.string;
    }

    return .{
        .arguments = args,
        .request_id = if (root.get("requestId")) |v| v.integer else 0,
        .cancel = if (root.get("cancel")) |v| v.bool else false,
    };
}

fn writeWorkResponse(io: std.Io, response: WorkResponse) !void {
    try writeAll(io, .stdout, "{\"exitCode\":");
    var int_buf: [32]u8 = undefined;
    try writeAll(io, .stdout, try std.fmt.bufPrint(&int_buf, "{}", .{response.exit_code}));
    try writeAll(io, .stdout, ",\"output\":");
    try writeJsonString(io, response.output);
    try writeAll(io, .stdout, ",\"requestId\":");
    try writeAll(io, .stdout, try std.fmt.bufPrint(&int_buf, "{}", .{response.request_id}));
    if (response.was_cancelled) {
        try writeAll(io, .stdout, ",\"wasCancelled\":true");
    }
    try writeAll(io, .stdout, "}\n");
}

fn writeJsonString(io: std.Io, value: []const u8) !void {
    try writeAll(io, .stdout, "\"");
    for (value) |c| {
        switch (c) {
            '"' => try writeAll(io, .stdout, "\\\""),
            '\\' => try writeAll(io, .stdout, "\\\\"),
            '\n' => try writeAll(io, .stdout, "\\n"),
            '\r' => try writeAll(io, .stdout, "\\r"),
            '\t' => try writeAll(io, .stdout, "\\t"),
            else => {
                if (c < 0x20) {
                    var buf: [6]u8 = undefined;
                    try writeAll(io, .stdout, try std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}));
                } else {
                    try writeAll(io, .stdout, &[_]u8{c});
                }
            },
        }
    }
    try writeAll(io, .stdout, "\"");
}

fn readLine(allocator: std.mem.Allocator, io: std.Io) !?[]u8 {
    var line: std.ArrayList(u8) = .empty;
    errdefer line.deinit(allocator);
    var buf: [1]u8 = undefined;
    while (true) {
        const n = std.Io.File.stdin().readStreaming(io, &.{&buf}) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => |e| return e,
        };
        if (n == 0) {
            if (line.items.len == 0) {
                line.deinit(allocator);
                return null;
            }
            return try line.toOwnedSlice(allocator);
        }
        if (buf[0] == '\n') {
            if (line.items.len > 0 and line.items[line.items.len - 1] == '\r') {
                _ = line.pop();
            }
            return try line.toOwnedSlice(allocator);
        }
        try line.append(allocator, buf[0]);
    }
}

fn writeAll(io: std.Io, stream: Stream, bytes: []const u8) !void {
    switch (stream) {
        .stdout => try std.Io.File.writeStreamingAll(.stdout(), io, bytes),
        .stderr => try std.Io.File.writeStreamingAll(.stderr(), io, bytes),
    }
}
