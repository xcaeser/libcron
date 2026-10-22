//! The `_serve` process: owns the jobs and answers control requests.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const libcron = @import("libcron");

const config = @import("config.zig");
const JobSpec = config.JobSpec;
const protocol = @import("protocol.zig");
const Request = protocol.Request;
const Response = protocol.Response;
const JobStatus = protocol.JobStatus;
const Status = protocol.Status;
const sendMessage = protocol.sendMessage;
const state_paths = @import("state.zig");
const StatePaths = state_paths.StatePaths;
const logEvent = @import("log.zig").logEvent;

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
    var daemon = Daemon.init(init.gpa, init.io, init.environ_map, config_path, &problem) catch |err| {
        if (err == error.InvalidConfig) logEvent(init.io, "{s}", .{problem.buffered()});
        return err;
    };
    defer daemon.deinit();
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
    logEvent(init.io, "daemon stopped", .{});
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
                else => sendError(daemon, stream, "could not resume \"{s}\": {t}", .{ id, err }),
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
            daemon.stopAll();
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

const RuntimeJob = struct {
    allocator: Allocator,
    io: Io,
    spec: JobSpec,
    owned_environ: ?std.process.Environ.Map,
    scheduler: libcron.Scheduler,
    future: ?Io.Future(libcron.RunError!void) = null,
    state: std.atomic.Value(Status),

    fn create(allocator: Allocator, io: Io, parent_env: *const std.process.Environ.Map, spec: JobSpec) !*RuntimeJob {
        var owned_spec = spec;
        errdefer owned_spec.deinit();
        const job = try allocator.create(RuntimeJob);
        errdefer allocator.destroy(job);
        job.* = undefined;
        job.allocator = allocator;
        job.io = io;
        job.spec = owned_spec;
        owned_spec.arena = null;
        errdefer job.spec.deinit();
        job.owned_environ = null;
        errdefer if (job.owned_environ) |*environ| environ.deinit();
        const environ_map = if (spec.env.len == 0)
            parent_env
        else blk: {
            job.owned_environ = try parent_env.clone(allocator);
            for (spec.env) |entry| try job.owned_environ.?.put(entry.key, entry.value);
            break :blk &job.owned_environ.?;
        };
        job.scheduler = libcron.Scheduler.init(allocator);
        errdefer job.scheduler.deinit();
        _ = try job.scheduler.add(spec.expression, .{ .command = .{
            .argv = spec.argv,
            .cwd = .{ .path = spec.cwd },
            .environ_map = environ_map,
        } }, .{ .time_zone = .utc, .overlap = spec.overlap });
        job.future = null;
        job.state = .init(.paused);
        return job;
    }

    fn start(self: *RuntimeJob) !void {
        switch (self.state.load(.acquire)) {
            .active => return,
            .offline => if (self.future) |*future| {
                _ = future.await(self.io) catch {};
                self.future = null;
            },
            .paused => {},
        }
        self.state.store(.active, .release);
        self.future = Io.concurrent(self.io, run, .{self}) catch |err| {
            self.state.store(.offline, .release);
            return err;
        };
    }

    fn stop(self: *RuntimeJob) void {
        if (self.future) |*future| {
            _ = future.cancel(self.io) catch {};
            self.future = null;
        }
        self.state.store(.paused, .release);
    }

    fn run(self: *RuntimeJob) libcron.RunError!void {
        self.scheduler.run(self.io, .{ .context = self, .notify = observerNotify }) catch |err| {
            if (err != error.Canceled) self.state.store(.offline, .release);
            return err;
        };
        self.state.store(.offline, .release);
    }

    fn deinit(self: *RuntimeJob) void {
        self.stop();
        self.scheduler.deinit();
        if (self.owned_environ) |*environ| environ.deinit();
        self.spec.deinit();
        self.allocator.destroy(self);
    }
};

fn observerNotify(context: ?*anyopaque, _: libcron.Invocation, outcome: libcron.Outcome) void {
    const job: *RuntimeJob = @ptrCast(@alignCast(context.?));
    logEvent(job.io, "{s} {f}", .{ job.spec.id, outcome });
}

const Daemon = struct {
    allocator: Allocator,
    io: Io,
    parent_env: *const std.process.Environ.Map,
    config_path: []const u8,
    jobs: std.ArrayList(*RuntimeJob),

    fn init(
        allocator: Allocator,
        io: Io,
        parent_env: *const std.process.Environ.Map,
        config_path: []const u8,
        problem: *Io.Writer,
    ) !Daemon {
        const config_absolute = try config.resolveFromCwd(allocator, io, config_path);
        var result: Daemon = .{
            .allocator = allocator,
            .io = io,
            .parent_env = parent_env,
            .config_path = config_absolute,
            .jobs = .empty,
        };
        errdefer result.deinit();
        var specs = try config.loadConfig(allocator, io, result.config_path, problem);
        defer specs.deinit();
        try result.jobs.ensureTotalCapacity(allocator, specs.items.items.len);
        for (specs.items.items) |*spec| {
            const runtime = try RuntimeJob.create(allocator, io, parent_env, spec.move());
            runtime.start() catch |err| {
                runtime.deinit();
                return err;
            };
            result.jobs.appendAssumeCapacity(runtime);
        }
        return result;
    }

    fn deinit(self: *Daemon) void {
        for (self.jobs.items) |job| job.deinit();
        self.jobs.deinit(self.allocator);
        self.allocator.free(self.config_path);
        self.* = undefined;
    }

    fn find(self: *Daemon, id: []const u8) ?*RuntimeJob {
        for (self.jobs.items) |job| if (std.mem.eql(u8, job.spec.id, id)) return job;
        return null;
    }

    fn setRunning(self: *Daemon, id: []const u8, running: bool) !void {
        const job = self.find(id) orelse return error.UnknownJob;
        if (running) try job.start() else job.stop();
    }

    fn stopAll(self: *Daemon) void {
        for (self.jobs.items) |job| job.stop();
    }

    fn reload(self: *Daemon, problem: *Io.Writer) !void {
        var specs = try config.loadConfig(self.allocator, self.io, self.config_path, problem);
        errdefer specs.deinit();
        const Existing = struct {
            job: *RuntimeJob,
            retained: bool = false,
            was_active: bool = false,
        };
        var existing_by_id = std.StringHashMap(Existing).init(self.allocator);
        defer existing_by_id.deinit();
        try existing_by_id.ensureTotalCapacity(@intCast(self.jobs.items.len));
        for (self.jobs.items) |job| existing_by_id.putAssumeCapacity(job.spec.id, .{ .job = job });
        var next: std.ArrayList(*RuntimeJob) = .empty;
        var created: std.ArrayList(*RuntimeJob) = .empty;
        errdefer {
            for (created.items) |job| job.deinit();
            created.deinit(self.allocator);
            next.deinit(self.allocator);
        }
        try next.ensureTotalCapacity(self.allocator, specs.items.items.len);
        try created.ensureTotalCapacity(self.allocator, specs.items.items.len);
        for (specs.items.items) |*candidate| {
            if (existing_by_id.getPtr(candidate.id)) |existing| {
                if (existing.job.spec.eql(candidate)) {
                    existing.retained = true;
                    next.appendAssumeCapacity(existing.job);
                    continue;
                }
            }
            const runtime = try RuntimeJob.create(self.allocator, self.io, self.parent_env, candidate.move());
            created.appendAssumeCapacity(runtime);
            next.appendAssumeCapacity(runtime);
        }
        var existing_iterator = existing_by_id.valueIterator();
        while (existing_iterator.next()) |existing| {
            existing.was_active = !existing.retained and existing.job.state.load(.acquire) == .active;
            if (existing.was_active) existing.job.stop();
        }
        for (created.items) |job| job.start() catch |err| {
            for (created.items) |created_job| created_job.stop();
            var restore_iterator = existing_by_id.valueIterator();
            while (restore_iterator.next()) |existing| {
                if (existing.was_active) existing.job.start() catch |restart_err|
                    logEvent(self.io, "{s} failed to resume after reload: {t}", .{ existing.job.spec.id, restart_err });
            }
            return err;
        };
        var cleanup_iterator = existing_by_id.valueIterator();
        while (cleanup_iterator.next()) |existing| {
            if (!existing.retained) existing.job.deinit();
        }
        self.jobs.deinit(self.allocator);
        self.jobs = next;
        created.deinit(self.allocator);
        specs.deinit();
    }

    fn status(self: *const Daemon, allocator: Allocator) ![]JobStatus {
        const result = try allocator.alloc(JobStatus, self.jobs.items.len);
        for (self.jobs.items, 0..) |job, i| result[i] = .{
            .id = job.spec.id,
            .schedule = job.spec.schedule,
            .status = job.state.load(.acquire),
        };
        return result;
    }
};

test "daemon pause and reload reconcile by stable job id" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const initial = "{\"jobs\":[{\"id\":\"keep\",\"schedule\":\"* * * * *\",\"action\":{\"command\":{\"argv\":[\"/usr/bin/true\"]}}},{\"id\":\"change\",\"schedule\":\"* * * * *\",\"action\":{\"command\":{\"argv\":[\"/usr/bin/true\"]}}},{\"id\":\"remove\",\"schedule\":\"* * * * *\",\"action\":{\"command\":{\"argv\":[\"/usr/bin/true\"]}}}]}";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "croner.json", .data = initial });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "croner.json", std.testing.allocator);
    defer std.testing.allocator.free(path);
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    var problem_buffer: [512]u8 = undefined;
    var problem: Io.Writer = .fixed(&problem_buffer);
    var daemon = try Daemon.init(std.testing.allocator, std.testing.io, &environ, path, &problem);
    defer daemon.deinit();

    const keep = daemon.find("keep").?;
    const change = daemon.find("change").?;
    try std.testing.expect(keep.owned_environ == null);
    try daemon.setRunning("keep", false);
    try std.testing.expect(keep.future == null);
    try daemon.setRunning("keep", true);
    try std.testing.expect(keep.future != null);
    try daemon.setRunning("keep", false);

    const invalid = "{\"jobs\":[{\"id\":\"keep\",\"schedule\":\"* * * * *\",\"action\":{\"command\":{\"argv\":[\"/usr/bin/true\"]}}},{\"id\":\"keep\",\"schedule\":\"* * * * *\",\"action\":{\"command\":{\"argv\":[\"/usr/bin/true\"]}}}]}";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "croner.json", .data = invalid });
    try std.testing.expectError(error.InvalidConfig, daemon.reload(&problem));
    try std.testing.expect(daemon.find("keep").? == keep);
    try std.testing.expect(daemon.find("change").? == change);
    try std.testing.expect(keep.future == null);

    const updated = "{\"jobs\":[{\"id\":\"keep\",\"schedule\":\"* * * * *\",\"action\":{\"command\":{\"argv\":[\"/usr/bin/true\"]}}},{\"id\":\"change\",\"schedule\":\"*/2 * * * *\",\"action\":{\"command\":{\"argv\":[\"/usr/bin/true\"]}}},{\"id\":\"new\",\"schedule\":\"* * * * *\",\"action\":{\"command\":{\"argv\":[\"/usr/bin/true\"],\"env\":{\"CRONER_TEST\":\"1\"}}}}]}";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "croner.json", .data = updated });
    try daemon.reload(&problem);
    try std.testing.expect(daemon.find("keep").? == keep);
    try std.testing.expect(keep.future == null);
    try std.testing.expect(daemon.find("change").? != change);
    try std.testing.expect(daemon.find("change").?.future != null);
    try std.testing.expect(daemon.find("remove") == null);
    const new_job = daemon.find("new").?;
    try std.testing.expect(new_job.future != null);
    try std.testing.expectEqualStrings("1", new_job.owned_environ.?.get("CRONER_TEST").?);

    const failed = new_job;
    failed.stop();
    failed.scheduler.running = true;
    try failed.start();
    try std.testing.expectError(error.AlreadyRunning, failed.future.?.await(std.testing.io));
    try std.testing.expectEqual(Status.offline, failed.state.load(.acquire));
    const statuses = try daemon.status(std.testing.allocator);
    defer std.testing.allocator.free(statuses);
    try std.testing.expectEqualStrings("new", statuses[2].id);
    try std.testing.expectEqual(Status.offline, statuses[2].status);

    failed.scheduler.running = false;
    try failed.start();
    try std.testing.expectEqual(Status.active, failed.state.load(.acquire));
    daemon.stopAll();
    for (daemon.jobs.items) |job| {
        try std.testing.expect(job.future == null);
        try std.testing.expectEqual(Status.paused, job.state.load(.acquire));
    }
}
