//! Command jobs: each runs as a child process in its own process group.

const std = @import("std");
const builtin = @import("builtin");

const posix = std.posix;
const Term = std.process.Child.Term;

pub const Command = struct {
    argv: []const []const u8,
    cwd: std.process.Child.Cwd = .inherit,
    environ_map: ?*const std.process.Environ.Map = null,

    /// Rejects what `Scheduler.add` would: an empty argv or program name, an
    /// empty working directory path, and NUL bytes in arguments, the path,
    /// or environment values.
    pub fn validate(self: Command) error{InvalidCommand}!void {
        if (self.argv.len == 0 or self.argv[0].len == 0) return error.InvalidCommand;
        for (self.argv) |arg| {
            if (std.mem.indexOfScalar(u8, arg, 0) != null) return error.InvalidCommand;
        }
        switch (self.cwd) {
            .path => |path| if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null)
                return error.InvalidCommand,
            .inherit, .dir => {},
        }
        if (self.environ_map) |environ_map| {
            for (environ_map.values()) |value| {
                if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidCommand;
            }
        }
    }
};

/// Copies the argument, path, and environment strings into `arena`.
pub fn dupe(command: Command, arena: std.mem.Allocator) std.mem.Allocator.Error!Command {
    const argv = try arena.alloc([]const u8, command.argv.len);
    for (argv, command.argv) |*copy, arg| copy.* = try arena.dupe(u8, arg);
    const environ_map = if (command.environ_map) |map| environ: {
        const copy = try arena.create(std.process.Environ.Map);
        copy.* = try map.clone(arena);
        break :environ copy;
    } else null;
    return .{
        .argv = argv,
        .cwd = switch (command.cwd) {
            .path => |path| .{ .path = try arena.dupe(u8, path) },
            .inherit, .dir => command.cwd,
        },
        .environ_map = environ_map,
    };
}

pub const RunError = std.process.SpawnError || std.process.Child.WaitError;

/// Runs `command` until it exits. On cancellation its process group gets
/// SIGTERM, and whatever is left of the group SIGKILL once `grace` has
/// passed; the command is reaped before `error.Canceled` is returned.
pub fn run(command: Command, io: std.Io, grace: std.Io.Duration) RunError!Term {
    // Spawning is not interruptible: a canceled spawn could leave an
    // unreaped child behind.
    const protection = io.swapCancelProtection(.blocked);
    const spawned = std.process.spawn(io, .{
        .argv = command.argv,
        .cwd = command.cwd,
        .environ_map = command.environ_map,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
        .pgid = 0,
    });
    _ = io.swapCancelProtection(protection);
    var child = try spawned;

    // `wait` forgets the pid even when canceled.
    const pid = child.id.?;
    io.checkCancel() catch |err| {
        terminate(io, pid, grace);
        return err;
    };
    return child.wait(io) catch |err| {
        if (err == error.Canceled) terminate(io, pid, grace);
        return err;
    };
}

fn terminate(io: std.Io, pid: posix.pid_t, grace: std.Io.Duration) void {
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);

    signalGroup(pid, .TERM);
    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{ .raw = grace, .clock = .awake });
    // ponytail: polls every 10ms; a pidfd or kqueue wait would wake at exit.
    var reaped = false;
    while (true) {
        if (!reaped) reaped = reap(pid, .poll);
        // The leader's children may still be cleaning up after it exits.
        if (reaped and !groupAlive(pid)) return;
        if (deadline.compare(.lte, .now(io, .awake))) break;
        io.sleep(.fromMilliseconds(10), .awake) catch unreachable;
    }
    // The group id stays reserved while any member is alive, even after the
    // leader is reaped, so this cannot reach an unrelated process group.
    signalGroup(pid, .KILL);
    if (!reaped) _ = reap(pid, .block);
}

fn signalGroup(pid: posix.pid_t, signal: posix.SIG) void {
    posix.kill(-pid, signal) catch {};
}

fn groupAlive(pid: posix.pid_t) bool {
    // macOS answers EPERM while the group holds only a zombie.
    posix.kill(-pid, @fromBackingInt(0)) catch |err| return err != error.ProcessNotFound;
    return true;
}

/// Returns whether `pid` has exited and been reaped.
fn reap(pid: posix.pid_t, mode: enum { poll, block }) bool {
    var status: if (builtin.link_libc) c_int else i32 = undefined;
    const flags: u32 = switch (mode) {
        .poll => posix.W.NOHANG,
        .block => 0,
    };
    while (true) {
        const rc = posix.system.waitpid(pid, &status, @intCast(flags));
        switch (posix.errno(rc)) {
            .SUCCESS => return rc != 0,
            .INTR => continue,
            // Already reaped, or not our child: nothing left to wait for.
            else => return true,
        }
    }
}

test "cancellation stops a command that ignores SIGTERM, with its process group" {
    if (!std.process.can_spawn or builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;

    var random: [8]u8 = undefined;
    io.random(&random);
    var path_buffer: [64]u8 = undefined;
    const pid_path = try std.fmt.bufPrint(&path_buffer, "/tmp/libcron-group-{x}.pid", .{random});
    defer std.Io.Dir.deleteFileAbsolute(io, pid_path) catch {};
    var script_buffer: [256]u8 = undefined;
    const script = try std.fmt.bufPrint(
        &script_buffer,
        "trap '' TERM; sleep 60 & echo $$ > {s}.tmp && mv {s}.tmp {s}; wait",
        .{ pid_path, pid_path, pid_path },
    );

    var future = try std.Io.concurrent(io, run, .{
        Command{ .argv = &.{ "/bin/sh", "-c", script } },
        io,
        std.Io.Duration.fromMilliseconds(100),
    });
    var pid_text_buffer: [32]u8 = undefined;
    const pid_text = for (0..500) |_| {
        if (std.Io.Dir.cwd().readFile(io, pid_path, &pid_text_buffer)) |text| break text else |err| switch (err) {
            error.FileNotFound => try io.sleep(.fromMilliseconds(10), .awake),
            else => return err,
        }
    } else return error.CommandDidNotStart;
    const pid = try std.fmt.parseInt(posix.pid_t, std.mem.trimEnd(u8, pid_text, "\n"), 10);

    const canceled_at = std.Io.Clock.Timestamp.now(io, .awake);
    try std.testing.expectError(error.Canceled, future.cancel(io));
    try std.testing.expect(canceled_at.untilNow(io).raw.toSeconds() < 5);

    // The orphaned `sleep` is reaped by init shortly after SIGKILL.
    for (0..500) |_| {
        posix.kill(-pid, @fromBackingInt(0)) catch |err| switch (err) {
            error.ProcessNotFound => return,
            // macOS answers EPERM while the group holds only a zombie.
            error.PermissionDenied => {},
            else => return err,
        };
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    return error.ProcessGroupSurvived;
}

test "the grace period covers the whole group after its leader exits" {
    if (!std.process.can_spawn or builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;

    var random: [8]u8 = undefined;
    io.random(&random);
    var ready_buffer: [64]u8 = undefined;
    const ready = try std.fmt.bufPrint(&ready_buffer, "/tmp/libcron-grace-{x}.ready", .{random});
    var cleaned_buffer: [64]u8 = undefined;
    const cleaned = try std.fmt.bufPrint(&cleaned_buffer, "/tmp/libcron-grace-{x}.cleaned", .{random});
    defer std.Io.Dir.deleteFileAbsolute(io, ready) catch {};
    defer std.Io.Dir.deleteFileAbsolute(io, cleaned) catch {};
    // The leader dies on SIGTERM at once; its child needs a second to clean up.
    var script_buffer: [256]u8 = undefined;
    const script = try std.fmt.bufPrint(
        &script_buffer,
        "/bin/sh -c 'trap \"sleep 1; touch {s}; exit 0\" TERM; touch {s}; while :; do sleep 0.1; done'; true",
        .{ cleaned, ready },
    );

    var future = try std.Io.concurrent(io, run, .{
        Command{ .argv = &.{ "/bin/sh", "-c", script } },
        io,
        std.Io.Duration.fromSeconds(5),
    });
    for (0..500) |_| {
        if (std.Io.Dir.accessAbsolute(io, ready, .{})) |_| break else |_| try io.sleep(.fromMilliseconds(10), .awake);
    } else return error.CommandDidNotStart;

    try std.testing.expectError(error.Canceled, future.cancel(io));
    try std.Io.Dir.accessAbsolute(io, cleaned, .{});
}
