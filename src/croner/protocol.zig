//! Newline-delimited JSON requests and responses over the daemon's Unix socket.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const state_paths = @import("state.zig");
const StatePaths = state_paths.StatePaths;
const acquireStateLock = state_paths.acquireStateLock;

const max_message_bytes = 1024 * 1024;

pub const control_io_timeout: Io.Clock.Duration = .{ .clock = .awake, .raw = .fromSeconds(5) };

pub const Request = union(enum) {
    ping,
    list,
    start: []const u8,
    stop: []const u8,
    reload,
    shutdown,
};

pub const JobStatus = struct { id: []const u8, schedule: []const u8, status: Status };
pub const Status = enum(u8) { active, paused, offline };
pub const Response = union(enum) {
    pid: u64,
    ok: []const u8,
    jobs: []const JobStatus,
    @"error": []const u8,
};

pub fn jsonWrite(comptime T: type, value: T, allocator: Allocator) ![]u8 {
    var writer = Io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();
    try std.json.Stringify.value(value, .{ .emit_null_optional_fields = false }, &writer.writer);
    try writer.writer.writeByte('\n');
    return writer.toOwnedSlice();
}

fn readMessage(stream: *Io.net.Stream, io: Io, allocator: Allocator) ![]u8 {
    return readMessageTimeout(stream, io, allocator, .none);
}

pub fn readMessageTimeout(stream: *Io.net.Stream, io: Io, allocator: Allocator, timeout: Io.Timeout) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const read_len = @min(chunk.len, max_message_bytes - result.items.len + 1);
        var data = [_][]u8{chunk[0..read_len]};
        const count = (try (try io.operateTimeout(.{ .net_read = .{
            .socket_handle = stream.socket.handle,
            .data = &data,
        } }, timeout)).net_read).data_len;
        if (count == 0) return error.EndOfStream;
        const bytes = chunk[0..count];
        if (std.mem.indexOfScalar(u8, bytes, '\n')) |index| {
            if (result.items.len + index > max_message_bytes) return error.MessageTooLarge;
            try result.appendSlice(allocator, bytes[0..index]);
            return result.toOwnedSlice(allocator);
        }
        if (result.items.len + bytes.len > max_message_bytes) return error.MessageTooLarge;
        try result.appendSlice(allocator, bytes);
    }
}

pub fn sendMessage(stream: *Io.net.Stream, io: Io, comptime T: type, value: T, allocator: Allocator) !void {
    const bytes = try jsonWrite(T, value, allocator);
    defer allocator.free(bytes);
    if (bytes.len > max_message_bytes + 1) return error.MessageTooLarge;
    const timeout: Io.Timeout = .{ .deadline = .fromNow(io, control_io_timeout) };
    var offset: usize = 0;
    while (offset < bytes.len) {
        const data = [_][]const u8{bytes[offset..]};
        const count = try (try io.operateTimeout(.{ .net_write = .{
            .socket_handle = stream.socket.handle,
            .data = &data,
        } }, timeout)).net_write;
        if (count == 0) return error.EndOfStream;
        offset += count;
    }
}

fn connectState(io: Io, state: *const StatePaths) !Io.net.Stream {
    const stat = Io.Dir.cwd().statFile(io, state.socket, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };
    if (stat.kind != .unix_domain_socket) return error.FileNotFound;
    const address = try Io.net.UnixAddress.init(state.socket);
    return address.connect(io);
}

pub fn request(allocator: Allocator, io: Io, state: *const StatePaths, message: Request) !std.json.Parsed(Response) {
    var stream = try connectState(io, state);
    defer stream.close(io);
    try sendMessage(&stream, io, Request, message, allocator);
    const line = try readMessageTimeout(
        &stream,
        io,
        allocator,
        .{ .deadline = .fromNow(io, control_io_timeout) },
    );
    defer allocator.free(line);
    return std.json.parseFromSlice(Response, allocator, line, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResponse,
    };
}

pub fn daemonSocketAvailable(io: Io, state: *const StatePaths) !bool {
    var stream = connectState(io, state) catch |err| switch (err) {
        error.ConnectionRefused, error.FileNotFound => return false,
        else => return err,
    };
    stream.close(io);
    return true;
}

pub fn listenState(io: Io, state: *const StatePaths) !Io.net.Server {
    const address = try Io.net.UnixAddress.init(state.socket);
    return address.listen(io, .{}) catch |err| switch (err) {
        error.AddressInUse => {
            if (try daemonSocketAvailable(io, state)) return error.AlreadyRunning;
            Io.Dir.deleteFileAbsolute(io, state.socket) catch |delete_err| switch (delete_err) {
                error.FileNotFound => {},
                else => return delete_err,
            };
            return address.listen(io, .{});
        },
        else => return err,
    };
}

test "protocol messages round trip" {
    // A short home keeps the socket path within the OS limit however deep the checkout is.
    var random: [8]u8 = undefined;
    std.testing.io.random(&random);
    var home_buffer: [64]u8 = undefined;
    const home = try std.fmt.bufPrint(&home_buffer, "/tmp/croner-test-{x}", .{std.mem.readInt(u64, &random, .little)});
    defer Io.Dir.cwd().deleteTree(std.testing.io, home) catch {};
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("CRONER_HOME", home);
    var state = try StatePaths.init(std.testing.allocator, std.testing.io, &environ, "/project/croner.json");
    defer state.deinit();
    try state.ensure(std.testing.io);
    const socket_path = state.socket;
    const address = try Io.net.UnixAddress.init(socket_path);
    try Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = socket_path, .data = "stale" });
    const state_lock = try acquireStateLock(std.testing.io, &state);
    defer state_lock.close(std.testing.io);
    try std.testing.expectError(error.WouldBlock, acquireStateLock(std.testing.io, &state));
    try std.testing.expect(!(try daemonSocketAvailable(std.testing.io, &state)));
    var server = try listenState(std.testing.io, &state);
    defer {
        server.deinit(std.testing.io);
        Io.Dir.deleteFileAbsolute(std.testing.io, socket_path) catch {};
    }
    var client = try address.connect(std.testing.io);
    defer client.close(std.testing.io);
    var peer = try server.accept(std.testing.io);
    defer peer.close(std.testing.io);
    try std.testing.expectError(
        error.Timeout,
        readMessageTimeout(&peer, std.testing.io, std.testing.allocator, .{
            .deadline = .{ .clock = .awake, .raw = .zero },
        }),
    );

    try sendMessage(&client, std.testing.io, Request, .{ .start = "sync" }, std.testing.allocator);
    const request_bytes = try readMessage(&peer, std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(request_bytes);
    var request_parsed = try std.json.parseFromSlice(Request, std.testing.allocator, request_bytes, .{});
    defer request_parsed.deinit();
    try std.testing.expectEqualStrings("sync", request_parsed.value.start);

    try sendMessage(&peer, std.testing.io, Response, .{ .ok = "started" }, std.testing.allocator);
    const response_bytes = try readMessage(&client, std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(response_bytes);
    var response_parsed = try std.json.parseFromSlice(Response, std.testing.allocator, response_bytes, .{});
    defer response_parsed.deinit();
    try std.testing.expectEqualStrings("started", response_parsed.value.ok);

    const payload = try std.testing.allocator.alloc(u8, max_message_bytes);
    defer std.testing.allocator.free(payload);
    @memset(payload, 'x');
    const WriteExactMessage = struct {
        fn run(stream: *Io.net.Stream, io: Io, bytes: []const u8) !void {
            var buffer: [4096]u8 = undefined;
            var writer = stream.writer(io, &buffer);
            try writer.interface.writeAll(bytes);
            try writer.interface.writeByte('\n');
            try writer.interface.flush();
        }
    };
    var write_future = try Io.concurrent(std.testing.io, WriteExactMessage.run, .{ &client, std.testing.io, payload });
    errdefer _ = write_future.cancel(std.testing.io) catch {};
    const exact = try readMessage(&peer, std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(exact);
    try write_future.await(std.testing.io);
    try std.testing.expectEqualSlices(u8, payload, exact);

    const wire_oversized = try std.testing.allocator.alloc(u8, max_message_bytes + 1);
    defer std.testing.allocator.free(wire_oversized);
    @memset(wire_oversized, 'x');
    var oversized_future = try Io.concurrent(std.testing.io, WriteExactMessage.run, .{
        &client,
        std.testing.io,
        wire_oversized,
    });
    errdefer _ = oversized_future.cancel(std.testing.io) catch {};
    try std.testing.expectError(
        error.MessageTooLarge,
        readMessage(&peer, std.testing.io, std.testing.allocator),
    );
    try oversized_future.await(std.testing.io);

    const oversized = try std.testing.allocator.alloc(u8, max_message_bytes);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'x');
    try std.testing.expectError(
        error.MessageTooLarge,
        sendMessage(&client, std.testing.io, Response, .{ .ok = oversized }, std.testing.allocator),
    );
    try std.testing.expectError(error.AlreadyRunning, listenState(std.testing.io, &state));
    server.deinit(std.testing.io);
    server = try listenState(std.testing.io, &state);
}
