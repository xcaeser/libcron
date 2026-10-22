//! Croner command line and daemon.

const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");

const commands = @import("croner/commands.zig");
const daemon = @import("croner/daemon.zig");

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
        return daemon.serve(init, args[2]);
    }
    var cli = try commands.buildCli(.{
        .io = init.io,
        .writer = &stdout_writer.interface,
        .reader = &stdin_reader.interface,
        .allocator = allocator,
    });
    defer cli.deinit();
    const arg_vector = try commands.normalizedArgVector(init.arena.allocator(), args);
    var iterator = (std.process.Args{ .vector = arg_vector }).iterate();
    var app: commands.App = .{ .allocator = allocator, .io = init.io, .environ = init.environ_map };
    cli.execute(&iterator, .{ .data = &app }) catch |err| {
        if (err != error.Reported)
            stdout_writer.interface.print("error: {t}\n", .{err}) catch {};
        stdout_writer.interface.flush() catch {};
        std.process.exit(1);
    };
}

test {
    _ = @import("croner/config.zig");
    _ = @import("croner/state.zig");
    _ = @import("croner/protocol.zig");
    _ = @import("croner/log.zig");
    _ = daemon;
    _ = commands;
}
