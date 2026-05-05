const std = @import("std");
const builtin = @import("builtin");

const is_zig_0_16_or_later = builtin.zig_version.major == 0 and builtin.zig_version.minor >= 16;

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

pub const main = if (is_zig_0_16_or_later) main_016 else main_pre_016;

fn main_pre_016() !void {
    const allocator = std.heap.page_allocator;
    const raw_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, raw_args);
    try mainImpl(allocator, raw_args, null);
}

fn main_016(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    const raw_args = try init.minimal.args.toSlice(allocator);
    try mainImpl(allocator, raw_args, init.io);
}

fn mainImpl(allocator: std.mem.Allocator, raw_args: anytype, io: anytype) !void {
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
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(allocator);
        try argv.append(allocator, options.zig_exe);
        try appendExpandedArgs(allocator, io, &argv, remaining.args);
        const result = try runZig(allocator, io, argv.items);
        defer allocator.free(result.output);
        if (result.output.len > 0) {
            try writeAll(io, .stderr, result.output);
        }
        std.process.exit(@intCast(result.exit_code));
    }

    while (try readLine(allocator, io)) |line| {
        defer allocator.free(line);

        const request = parseWorkRequest(allocator, line) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "failed to parse WorkRequest: {s}\n", .{@errorName(err)});
            defer allocator.free(msg);
            try writeWorkResponse(io, .{ .exit_code = 1, .output = msg, .request_id = 0 });
            continue;
        };
        defer freeWorkRequest(allocator, request);

        if (request.cancel) {
            try writeWorkResponse(io, .{ .exit_code = 0, .output = "", .request_id = request.request_id, .was_cancelled = true });
            continue;
        }

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(allocator);
        try argv.append(allocator, options.zig_exe);
        try appendFilteredRequestArgs(allocator, &argv, remaining.args);
        try appendFilteredRequestArgs(allocator, &argv, request.arguments);
        try appendWorkerCacheArgs(allocator, io, &argv, options.zig_version);

        const result = runZig(allocator, io, argv.items) catch |err| result: {
            const msg = try std.fmt.allocPrint(allocator, "failed to run zig: {s}\n", .{@errorName(err)});
            break :result RunResult{ .exit_code = 1, .output = msg };
        };
        defer allocator.free(result.output);

        try writeWorkResponse(io, .{
            .exit_code = result.exit_code,
            .output = result.output,
            .request_id = request.request_id,
        });
    }
}

const ParsedOptions = struct {
    options: WorkerOptions,
    args: []const []const u8,
};

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

fn appendExpandedArgs(allocator: std.mem.Allocator, io: anytype, argv: *std.ArrayList([]const u8), args: []const []const u8) !void {
    for (args) |arg| {
        if (arg.len > 1 and arg[0] == '@' and !(arg.len > 2 and arg[1] == '@')) {
            const content = try readFileAlloc(allocator, io, arg[1..]);
            defer allocator.free(content);
            var it = std.mem.splitScalar(u8, content, '\n');
            while (it.next()) |line| {
                const trimmed = std.mem.trimEnd(u8, line, "\r");
                if (trimmed.len != 0) {
                    try argv.append(allocator, try allocator.dupe(u8, trimmed));
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

fn appendWorkerCacheArgs(allocator: std.mem.Allocator, io: anytype, argv: *std.ArrayList([]const u8), zig_version: []const u8) !void {
    const cache = try std.fs.path.join(allocator, &.{ "bazel-out", "rules_zig_worker_cache", zig_version });
    try makePath(io, cache);
    try argv.append(allocator, "--cache-dir");
    try argv.append(allocator, cache);
    try argv.append(allocator, "--global-cache-dir");
    try argv.append(allocator, cache);
}

fn readFileAlloc(allocator: std.mem.Allocator, io: anytype, path: []const u8) ![]u8 {
    if (is_zig_0_16_or_later) {
        return try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(32 * 1024 * 1024));
    } else {
        return try std.fs.cwd().readFileAlloc(allocator, path, 32 * 1024 * 1024);
    }
}

fn makePath(io: anytype, path: []const u8) !void {
    if (is_zig_0_16_or_later) {
        try std.Io.Dir.cwd().createDirPath(io, path);
    } else {
        try std.fs.cwd().makePath(path);
    }
}

const RunResult = struct {
    exit_code: i32,
    output: []u8,
};

fn runZig(allocator: std.mem.Allocator, io: anytype, argv: []const []const u8) !RunResult {
    const result = if (is_zig_0_16_or_later)
        try std.process.run(allocator, io, .{ .argv = argv })
    else
        try std.process.Child.run(.{ .allocator = allocator, .argv = argv });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, result.stdout);
    try output.appendSlice(allocator, result.stderr);

    return .{
        .exit_code = termExitCode(result.term),
        .output = try output.toOwnedSlice(allocator),
    };
}

fn termExitCode(term: std.process.Child.Term) i32 {
    if (is_zig_0_16_or_later) {
        return switch (term) {
            .exited => |code| @intCast(code),
            else => 1,
        };
    } else {
        return switch (term) {
            .Exited => |code| @intCast(code),
            else => 1,
        };
    }
}

fn parseWorkRequest(allocator: std.mem.Allocator, line: []const u8) !WorkRequest {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const args_value = root.get("arguments") orelse return error.MissingArguments;
    const args_array = args_value.array;
    var args = try allocator.alloc([]const u8, args_array.items.len);
    errdefer allocator.free(args);

    for (args_array.items, 0..) |item, i| {
        args[i] = try allocator.dupe(u8, item.string);
    }

    return .{
        .arguments = args,
        .request_id = if (root.get("requestId")) |v| v.integer else 0,
        .cancel = if (root.get("cancel")) |v| v.bool else false,
    };
}

fn freeWorkRequest(allocator: std.mem.Allocator, request: WorkRequest) void {
    for (request.arguments) |arg| {
        allocator.free(arg);
    }
    allocator.free(request.arguments);
}

const Stream = enum { stdout, stderr };

fn writeWorkResponse(io: anytype, response: WorkResponse) !void {
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

fn writeJsonString(io: anytype, value: []const u8) !void {
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

fn readLine(allocator: std.mem.Allocator, io: anytype) !?[]u8 {
    var line: std.ArrayList(u8) = .empty;
    errdefer line.deinit(allocator);
    var buf: [1]u8 = undefined;
    while (true) {
        const n = readStdin(io, &buf) catch |err| switch (err) {
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

fn readStdin(io: anytype, buffer: []u8) !usize {
    if (is_zig_0_16_or_later) {
        return try std.Io.File.stdin().readStreaming(io, &.{buffer});
    } else {
        return try std.fs.File.stdin().read(buffer);
    }
}

fn writeAll(io: anytype, stream: Stream, bytes: []const u8) !void {
    if (is_zig_0_16_or_later) {
        switch (stream) {
            .stdout => try std.Io.File.writeStreamingAll(.stdout(), io, bytes),
            .stderr => try std.Io.File.writeStreamingAll(.stderr(), io, bytes),
        }
    } else {
        switch (stream) {
            .stdout => try std.fs.File.stdout().writeAll(bytes),
            .stderr => try std.fs.File.stderr().writeAll(bytes),
        }
    }
}
