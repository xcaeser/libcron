//! Where a config's daemon keeps its socket, lock and log.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const resolveFromCwd = @import("config.zig").resolveFromCwd;

pub const unix_socket_path_max = if (builtin.os.tag == .macos) 104 else Io.net.UnixAddress.max_len;

pub const StatePaths = struct {
    allocator: Allocator,
    root: []const u8,
    socket: []const u8,
    lock: []const u8,
    log: []const u8,

    /// State lives under `$CRONER_HOME` (default `~/.croner`), keyed by the
    /// absolute config path so `--config` from any directory finds the daemon.
    pub fn init(allocator: Allocator, io: Io, environ: *const std.process.Environ.Map, config_path: []const u8) !StatePaths {
        const home = if (environ.get("CRONER_HOME")) |croner_home|
            try allocator.dupe(u8, croner_home)
        else if (environ.get("HOME")) |user_home|
            try std.fs.path.join(allocator, &.{ user_home, ".croner" })
        else
            return error.HomeNotFound;
        defer allocator.free(home);
        if (!std.fs.path.isAbsolute(home)) return error.CronerHomeNotAbsolute;
        const abs = try resolveFromCwd(allocator, io, config_path);
        defer allocator.free(abs);
        const key = std.hash.Wyhash.hash(0, abs);
        const key_text = try std.fmt.allocPrint(allocator, "{x}", .{key});
        defer allocator.free(key_text);
        const root = try std.fs.path.join(allocator, &.{ home, "run", key_text });
        errdefer allocator.free(root);
        const socket = try std.fs.path.join(allocator, &.{ root, "s" });
        errdefer allocator.free(socket);
        if (socket.len > unix_socket_path_max) return error.NameTooLong;
        const lock = try std.fs.path.join(allocator, &.{ root, "daemon.lock" });
        errdefer allocator.free(lock);
        const log = try std.fs.path.join(allocator, &.{ root, "croner.log" });
        return .{ .allocator = allocator, .root = root, .socket = socket, .lock = lock, .log = log };
    }

    pub fn deinit(self: *StatePaths) void {
        self.allocator.free(self.root);
        self.allocator.free(self.socket);
        self.allocator.free(self.lock);
        self.allocator.free(self.log);
        self.* = undefined;
    }

    pub fn ensure(self: *const StatePaths, io: Io) !void {
        var dir = try Io.Dir.cwd().createDirPathOpen(io, self.root, .{ .permissions = .fromMode(0o700) });
        defer dir.close(io);
        try dir.setPermissions(io, .fromMode(0o700));
    }
};

pub fn acquireStateLock(io: Io, state: *const StatePaths) !Io.File {
    return Io.Dir.createFileAbsolute(io, state.lock, .{
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
        .permissions = .fromMode(0o600),
    });
}

test "state paths live in the croner home, keyed by absolute config path" {
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("HOME", "/home/user");
    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const absolute_config = try std.fs.path.join(std.testing.allocator, &.{ cwd, "croner.json" });
    defer std.testing.allocator.free(absolute_config);

    var relative = try StatePaths.init(std.testing.allocator, std.testing.io, &environ, "./croner.json");
    defer relative.deinit();
    var absolute = try StatePaths.init(std.testing.allocator, std.testing.io, &environ, absolute_config);
    defer absolute.deinit();
    try std.testing.expectEqualStrings(relative.socket, absolute.socket);
    try std.testing.expect(std.mem.startsWith(u8, relative.root, "/home/user/.croner/run/"));

    try environ.put("CRONER_HOME", "/srv/croner");
    var custom = try StatePaths.init(std.testing.allocator, std.testing.io, &environ, absolute_config);
    defer custom.deinit();
    try std.testing.expect(std.mem.startsWith(u8, custom.root, "/srv/croner/run/"));
    try environ.put("CRONER_HOME", "relative");
    try std.testing.expectError(error.CronerHomeNotAbsolute, StatePaths.init(std.testing.allocator, std.testing.io, &environ, absolute_config));
}
