//! The `_serve` process: detaches, takes the state lock, owns the log and
//! answers control requests until a shutdown request or a signal.

const std = @import("std");
const Io = std.Io;

const protocol = @import("protocol.zig");
const Request = protocol.Request;
const Response = protocol.Response;
const sendMessage = protocol.sendMessage;
const state_paths = @import("state.zig");
const StatePaths = state_paths.StatePaths;
const logEvent = @import("log.zig").logEvent;
const Daemon = @import("daemon.zig").Daemon;

var signal_write_fd = std.atomic.Value(std.posix.fd_t).init(-1);

fn signalHandler(_: std.posix.SIG) callconv(.c) void {
    const fd = signal_write_fd.load(.monotonic);
    if (fd >= 0) {
        var byte = [_]u8{1};
        _ = std.posix.system.write(fd, &byte, 1);
    }
}

fn installSignalHandlers() void {
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = signalHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &action, null);
    std.posix.sigaction(.TERM, &action, null);
}

pub fn serve(init: std.process.Init, config_path: []const u8) !void {
    switch (std.posix.errno(std.posix.system.setsid())) {
        .SUCCESS => {},
        // Only a process group leader gets EPERM; launchd and systemd start services that way.
        .PERM => {},
        else => return error.DetachFailed,
    }
    const fds = try Io.Threaded.pipe2(.{ .CLOEXEC = true });
    const signal_reader = Io.File{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    const signal_writer = Io.File{ .handle = fds[1], .flags = .{ .nonblocking = false } };
    defer signal_reader.close(init.io);
    defer signal_writer.close(init.io);
    signal_write_fd.store(fds[1], .release);
    defer signal_write_fd.store(-1, .release);
    installSignalHandlers();
    var state = try StatePaths.init(init.gpa, init.io, init.environ_map, config_path);
    defer state.deinit();
    try state.ensure(init.io);
    const state_lock = state_paths.acquireStateLock(init.io, &state) catch |err| switch (err) {
        error.WouldBlock => return error.AlreadyRunning,
        else => return err,
    };
    defer state_lock.close(init.io);
    try redirectToLog(init.io, state.log);
    var problem_buffer: [1024]u8 = undefined;
    var problem: Io.Writer = .fixed(&problem_buffer);
    var daemon = Daemon.init(init.gpa, init.io, init.environ_map, config_path, state.paused, &problem) catch |err| {
        if (err == error.InvalidConfig) logEvent(init.io, "{s}", .{problem.buffered()});
        return err;
    };
    // Runs after the daemon's jobs have exited, just before the lock is released.
    defer logEvent(init.io, "daemon stopped", .{});
    defer daemon.deinit();
    try daemon.start();
    var server = try protocol.listenState(init.io, &state);
    defer {
        server.deinit(init.io);
        Io.Dir.deleteFileAbsolute(init.io, state.socket) catch {};
    }
    logEvent(init.io, "daemon started", .{});
    const Event = union(enum) {
        server: anyerror!void,
        signal: anyerror!void,
    };
    var events: [2]Event = undefined;
    var select: Io.Select(Event) = .init(init.io, &events);
    try select.concurrent(.server, runServer, .{ &daemon, &server });
    defer select.cancelDiscard();
    try select.concurrent(.signal, waitForSignal, .{ signal_reader, init.io });
    const event = try select.await();
    switch (event) {
        .server => |result| result catch |err| if (err != error.Canceled) return err,
        .signal => {},
    }
}

/// Points stdout and stderr, which jobs inherit, at the log, whoever launched the daemon.
fn redirectToLog(io: Io, path: []const u8) !void {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .APPEND = true,
        .CLOEXEC = true,
    }, 0o600);
    defer (Io.File{ .handle = fd, .flags = .{ .nonblocking = false } }).close(io);
    for ([_]std.posix.fd_t{ std.posix.STDOUT_FILENO, std.posix.STDERR_FILENO }) |target| {
        if (std.posix.errno(std.posix.system.dup2(fd, target)) != .SUCCESS) return error.LogRedirectFailed;
    }
}

fn handleRequest(daemon: *Daemon, stream: *Io.net.Stream, request_bytes: []const u8, shutdown: *bool) !void {
    var parsed = std.json.parseFromSlice(Request, daemon.allocator, request_bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        try sendMessage(stream, daemon.io, Response, .{ .@"error" = "invalid request" }, daemon.allocator);
        return;
    };
    defer parsed.deinit();
    switch (parsed.value) {
        .ping => try sendMessage(
            stream,
            daemon.io,
            Response,
            .{ .pid = @intCast(std.posix.system.getpid()) },
            daemon.allocator,
        ),
        .list => {
            const statuses = try daemon.status(daemon.allocator);
            defer daemon.allocator.free(statuses);
            try sendMessage(stream, daemon.io, Response, .{ .jobs = statuses }, daemon.allocator);
        },
        .start, .stop => |id| {
            const running = parsed.value == .start;
            daemon.setRunning(id, running) catch |err| return switch (err) {
                error.UnknownJob => sendError(daemon, stream, "no job \"{s}\" in {s}", .{ id, daemon.config_path }),
                else => sendError(daemon, stream, "could not {s} \"{s}\": {t}", .{ if (running) "resume" else "pause", id, err }),
            };
            try sendMessage(stream, daemon.io, Response, .{ .ok = if (running) "started" else "stopped" }, daemon.allocator);
        },
        .reload => {
            var problem_buffer: [1024]u8 = undefined;
            var problem: Io.Writer = .fixed(&problem_buffer);
            daemon.reload(&problem) catch |err| return switch (err) {
                error.InvalidConfig => sendError(daemon, stream, "{s}", .{problem.buffered()}),
                else => sendError(daemon, stream, "reload failed: {t}", .{err}),
            };
            try sendMessage(stream, daemon.io, Response, .{ .ok = "reloaded" }, daemon.allocator);
        },
        .shutdown => {
            // Reply first: stopping waits out the jobs' termination grace,
            // longer than the client's request timeout.
            shutdown.* = true;
            try sendMessage(stream, daemon.io, Response, .{ .ok = "stopped" }, daemon.allocator);
        },
    }
}

fn sendError(daemon: *Daemon, stream: *Io.net.Stream, comptime format: []const u8, args: anytype) !void {
    var buffer: [1024]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    writer.print(format, args) catch {};
    try sendMessage(stream, daemon.io, Response, .{ .@"error" = writer.buffered() }, daemon.allocator);
}

fn runServer(daemon: *Daemon, server: *Io.net.Server) !void {
    var shutdown = false;
    while (!shutdown) {
        var stream = server.accept(daemon.io) catch |err| switch (err) {
            error.Canceled => break,
            else => return err,
        };
        defer stream.close(daemon.io);
        const bytes = protocol.readMessageTimeout(
            &stream,
            daemon.io,
            daemon.allocator,
            .{ .deadline = .fromNow(daemon.io, protocol.control_io_timeout) },
        ) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            continue;
        };
        defer daemon.allocator.free(bytes);
        handleRequest(daemon, &stream, bytes, &shutdown) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
        };
    }
}

fn waitForSignal(file: Io.File, io: Io) anyerror!void {
    var byte: [1]u8 = undefined;
    const data = [_][]u8{byte[0..]};
    _ = try file.readStreaming(io, &data);
}
