//! Where a config's daemon keeps its socket, lock, log and pause state.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const resolveFromCwd = @import("config.zig").resolveFromCwd;

pub const unix_socket_path_max = if (builtin.os.tag == .macos) 104 else Io.net.UnixAddress.max_len;

pub const StatePaths = struct {
    allocator: Allocator,
    /// `$CRONER_HOME`, or `~/.croner`.
    home: []const u8,
    /// Identifies the config: a hash of its absolute path.
    key: []const u8,
    root: []const u8,
    socket: []const u8,
    lock: []const u8,
    log: []const u8,
    paused: []const u8,

    /// State lives under `$CRONER_HOME` (default `~/.croner`), keyed by the
    /// config's real path so `--config` from any directory, or through any
    /// symlink, finds the one daemon for that file.
    pub fn init(allocator: Allocator, io: Io, environ: *const std.process.Environ.Map, config_path: []const u8) !StatePaths {
        const home = if (environ.get("CRONER_HOME")) |croner_home|
            try allocator.dupe(u8, croner_home)
        else if (environ.get("HOME")) |user_home|
            try std.fs.path.join(allocator, &.{ user_home, ".croner" })
        else
            return error.HomeNotFound;
        errdefer allocator.free(home);
        if (!std.fs.path.isAbsolute(home)) return error.CronerHomeNotAbsolute;
        const canonical = try realConfigPath(allocator, io, config_path);
        defer allocator.free(canonical);
        const key = try std.fmt.allocPrint(allocator, "{x}", .{std.hash.Wyhash.hash(0, canonical)});
        errdefer allocator.free(key);
        const root = try std.fs.path.join(allocator, &.{ home, "run", key });
        errdefer allocator.free(root);
        const socket = try std.fs.path.join(allocator, &.{ root, "s" });
        errdefer allocator.free(socket);
        if (socket.len > unix_socket_path_max) return error.NameTooLong;
        const lock = try std.fs.path.join(allocator, &.{ root, "daemon.lock" });
        errdefer allocator.free(lock);
        const log = try std.fs.path.join(allocator, &.{ root, "croner.log" });
        errdefer allocator.free(log);
        const paused = try std.fs.path.join(allocator, &.{ root, "paused.json" });
        return .{
            .allocator = allocator,
            .home = home,
            .key = key,
            .root = root,
            .socket = socket,
            .lock = lock,
            .log = log,
            .paused = paused,
        };
    }

    pub fn deinit(self: *StatePaths) void {
        self.allocator.free(self.home);
        self.allocator.free(self.key);
        self.allocator.free(self.root);
        self.allocator.free(self.socket);
        self.allocator.free(self.lock);
        self.allocator.free(self.log);
        self.allocator.free(self.paused);
        self.* = undefined;
    }

    pub fn ensure(self: *const StatePaths, io: Io) !void {
        // Set by path: a Dir handle must be opened with `iterate` for fchmod to
        // work on Linux, where other handles are path-only.
        _ = try Io.Dir.cwd().createDirPathStatus(io, self.root, .fromMode(0o700));
        try Io.Dir.cwd().setFilePermissions(io, self.root, .fromMode(0o700), .{});
    }
};

/// The config file's real path, or its directory's real path joined with its
/// name when the file is missing (deleted while its daemon runs, say).
fn realConfigPath(allocator: Allocator, io: Io, config_path: []const u8) ![]u8 {
    if (Io.Dir.cwd().realPathFileAlloc(io, config_path, allocator)) |real| {
        defer allocator.free(real);
        return allocator.dupe(u8, real);
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    const absolute = try resolveFromCwd(allocator, io, config_path);
    defer allocator.free(absolute);
    const dir = std.fs.path.dirname(absolute) orelse return allocator.dupe(u8, absolute);
    const real_dir = Io.Dir.cwd().realPathFileAlloc(io, dir, allocator) catch |err| switch (err) {
        error.FileNotFound => return allocator.dupe(u8, absolute),
        else => return err,
    };
    defer allocator.free(real_dir);
    return std.fs.path.join(allocator, &.{ real_dir, std.fs.path.basename(absolute) });
}

pub fn acquireStateLock(io: Io, state: *const StatePaths) !Io.File {
    return Io.Dir.createFileAbsolute(io, state.lock, .{
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
        .permissions = .fromMode(0o600),
    });
}

/// How long a stopping daemon may hold its lock: longer than libcron's
/// default 10 second termination grace for running commands.
pub const stop_budget_seconds = 15;

/// Waits until no daemon holds the state lock, so a successor can take it.
pub fn waitForUnlock(io: Io, state: *const StatePaths) !void {
    for (0..stop_budget_seconds * 40) |_| {
        const lock = acquireStateLock(io, state) catch |err| switch (err) {
            error.WouldBlock => {
                try Io.sleep(io, .fromMilliseconds(25), .awake);
                continue;
            },
            error.FileNotFound => return,
            else => return err,
        };
        lock.close(io);
        return;
    }
    return error.Timeout;
}

/// Reads the ids of paused jobs; a missing file means none are paused.
pub fn loadPaused(allocator: Allocator, io: Io, path: []const u8) !std.json.Parsed([]const []const u8) {
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return std.json.parseFromSlice([]const []const u8, allocator, "[]", .{}),
        else => return err,
    };
    defer allocator.free(bytes);
    return std.json.parseFromSlice([]const []const u8, allocator, bytes, .{ .allocate = .alloc_always });
}

/// Replaces the paused-id file through a temporary file and a rename, so a
/// crash leaves either the old or the new list.
pub fn savePaused(allocator: Allocator, io: Io, path: []const u8, ids: []const []const u8) !void {
    var bytes = Io.Writer.Allocating.init(allocator);
    defer bytes.deinit();
    try std.json.Stringify.value(ids, .{}, &bytes.writer);
    var file = try Io.Dir.cwd().createFileAtomic(io, path, .{ .permissions = .fromMode(0o600), .replace = true });
    defer file.deinit(io);
    try file.file.writeStreamingAll(io, bytes.written());
    // Without this a power loss can leave the renamed file empty.
    try file.file.sync(io);
    try file.replace(io);
}

test "paused ids round trip through the state directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir, "paused.json" });
    defer std.testing.allocator.free(path);

    var missing = try loadPaused(std.testing.allocator, std.testing.io, path);
    defer missing.deinit();
    try std.testing.expectEqual(@as(usize, 0), missing.value.len);

    try savePaused(std.testing.allocator, std.testing.io, path, &.{ "sync", "id with \"quotes\"\n" });
    try savePaused(std.testing.allocator, std.testing.io, path, &.{ "backup", "id with \"quotes\"\n" });
    var loaded = try loadPaused(std.testing.allocator, std.testing.io, path);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 2), loaded.value.len);
    try std.testing.expectEqualStrings("backup", loaded.value[0]);
    try std.testing.expectEqualStrings("id with \"quotes\"\n", loaded.value[1]);
}

fn testKey(environ: *const std.process.Environ.Map, dir: []const u8, name: []const u8) ![]u8 {
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir, name });
    defer std.testing.allocator.free(path);
    var state = try StatePaths.init(std.testing.allocator, std.testing.io, environ, path);
    defer state.deinit();
    return std.testing.allocator.dupe(u8, state.key);
}

test "a config reached through a symlink shares its daemon state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "real");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "real/croner.json", .data = "{}" });
    try tmp.dir.symLink(std.testing.io, "real", "link", .{ .is_directory = true });
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("CRONER_HOME", "/srv/croner");

    const real = try testKey(&environ, dir, "real/croner.json");
    defer std.testing.allocator.free(real);
    const linked = try testKey(&environ, dir, "link/croner.json");
    defer std.testing.allocator.free(linked);
    try std.testing.expectEqualStrings(real, linked);

    // A missing file is keyed through its directory's real path.
    const real_missing = try testKey(&environ, dir, "real/missing.json");
    defer std.testing.allocator.free(real_missing);
    const linked_missing = try testKey(&environ, dir, "link/missing.json");
    defer std.testing.allocator.free(linked_missing);
    try std.testing.expectEqualStrings(real_missing, linked_missing);
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
