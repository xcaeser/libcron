//! Croner command line and daemon.

const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");

const commands = @import("croner/commands.zig");
const serve = @import("croner/serve.zig");

pub fn main(init: std.process.Init) !void {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.UnsupportedOperatingSystem;
    const allocator = init.gpa;
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    defer stdout_writer.interface.flush() catch {};
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = Io.File.stdin().readerStreaming(init.io, &stdin_buffer);

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 1 and std.mem.eql(u8, args[1], "_serve")) {
        if (args.len != 3) return error.InvalidArguments;
        return serve.serve(init, args[2]);
    }
    var cli = try commands.buildCli(.{
        .io = init.io,
        .writer = &stdout_writer.interface,
        .reader = &stdin_reader.interface,
        .allocator = allocator,
    });
    defer cli.deinit();
    const arg_vector = try normalizedArgVector(init.arena.allocator(), args);
    var iterator = (std.process.Args{ .vector = arg_vector }).iterate();
    var app: commands.App = .{ .allocator = allocator, .io = init.io, .environ = init.environ_map };
    cli.execute(&iterator, .{ .data = &app }) catch |err| {
        if (err != error.Reported)
            stdout_writer.interface.print("error: {t}\n", .{err}) catch {};
        stdout_writer.interface.flush() catch {};
        std.process.exit(1);
    };
}

fn normalizedArgVector(allocator: std.mem.Allocator, args: []const [:0]const u8) ![][*:0]const u8 {
    const vector = try allocator.alloc([*:0]const u8, args.len);
    for (args, vector) |arg, *item| item.* = arg.ptr;

    // zli discovers a subcommand only before the first flag.
    if (args.len >= 4 and std.mem.eql(u8, args[1], "--config") and args[3].len > 0 and args[3][0] != '-') {
        vector[1] = args[3].ptr;
        vector[2] = args[1].ptr;
        vector[3] = args[2].ptr;
    } else if (args.len >= 3 and std.mem.startsWith(u8, args[1], "--config=") and args[2].len > 0 and args[2][0] != '-') {
        vector[1] = args[2].ptr;
        vector[2] = args[1].ptr;
    }
    return vector;
}

test "config flag may precede the subcommand" {
    const separate = [_][:0]const u8{ "croner", "--config", "project.json", "list" };
    const separate_vector = try normalizedArgVector(std.testing.allocator, &separate);
    defer std.testing.allocator.free(separate_vector);
    const expected_separate = [_][]const u8{ "croner", "list", "--config", "project.json" };
    for (expected_separate, separate_vector) |expected, actual|
        try std.testing.expectEqualStrings(expected, std.mem.span(actual));

    const joined = [_][:0]const u8{ "croner", "--config=project.json", "start", "sync" };
    const joined_vector = try normalizedArgVector(std.testing.allocator, &joined);
    defer std.testing.allocator.free(joined_vector);
    const expected_joined = [_][]const u8{ "croner", "start", "--config=project.json", "sync" };
    for (expected_joined, joined_vector) |expected, actual|
        try std.testing.expectEqualStrings(expected, std.mem.span(actual));
}

test {
    _ = @import("croner/config.zig");
    _ = @import("croner/state.zig");
    _ = @import("croner/protocol.zig");
    _ = @import("croner/log.zig");
    _ = @import("croner/next.zig");
    _ = @import("croner/supervisor.zig");
    _ = @import("croner/daemon.zig");
    _ = serve;
    _ = commands;
}
