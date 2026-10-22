//! The daemon's jobs: one scheduler per job, pause and resume by id, and
//! reload as a reconciliation by id.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const libcron = @import("libcron");

const config = @import("config.zig");
const JobSpec = config.JobSpec;
const protocol = @import("protocol.zig");
const JobStatus = protocol.JobStatus;
const Status = protocol.Status;
const state_paths = @import("state.zig");
const logEvent = @import("log.zig").logEvent;

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
        _ = try job.scheduler.add(io, spec.expression, .{ .command = .{
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

    pub fn deinit(self: *RuntimeJob) void {
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

fn contains(ids: []const []const u8, id: []const u8) bool {
    for (ids) |candidate| if (std.mem.eql(u8, candidate, id)) return true;
    return false;
}

pub const Daemon = struct {
    allocator: Allocator,
    io: Io,
    parent_env: *const std.process.Environ.Map,
    config_path: []const u8,
    /// Ids of paused jobs, saved so pauses survive restarts. Borrowed.
    paused_path: []const u8,
    jobs: std.ArrayList(*RuntimeJob),

    pub fn init(
        allocator: Allocator,
        io: Io,
        parent_env: *const std.process.Environ.Map,
        config_path: []const u8,
        paused_path: []const u8,
        problem: *Io.Writer,
    ) !Daemon {
        const config_absolute = try config.resolveFromCwd(allocator, io, config_path);
        var result: Daemon = .{
            .allocator = allocator,
            .io = io,
            .parent_env = parent_env,
            .config_path = config_absolute,
            .paused_path = paused_path,
            .jobs = .empty,
        };
        errdefer result.deinit();
        var specs = try config.loadConfig(allocator, io, result.config_path, problem);
        defer specs.deinit();
        var paused = state_paths.loadPaused(allocator, io, paused_path) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => blk: {
                logEvent(io, "starting every job: could not read {s}: {t}", .{ paused_path, err });
                break :blk null;
            },
        };
        defer if (paused) |*ids| ids.deinit();
        const paused_ids: []const []const u8 = if (paused) |ids| ids.value else &.{};
        try result.jobs.ensureTotalCapacity(allocator, specs.items.items.len);
        for (specs.items.items) |*spec| {
            const runtime = try RuntimeJob.create(allocator, io, parent_env, spec.move());
            result.jobs.appendAssumeCapacity(runtime);
            if (!contains(paused_ids, runtime.spec.id)) try runtime.start();
        }
        return result;
    }

    fn savePaused(self: *Daemon) !void {
        var ids: std.ArrayList([]const u8) = .empty;
        defer ids.deinit(self.allocator);
        for (self.jobs.items) |job| {
            if (job.state.load(.acquire) == .paused) try ids.append(self.allocator, job.spec.id);
        }
        try state_paths.savePaused(self.allocator, self.io, self.paused_path, ids.items);
    }

    pub fn deinit(self: *Daemon) void {
        for (self.jobs.items) |job| job.deinit();
        self.jobs.deinit(self.allocator);
        self.allocator.free(self.config_path);
        self.* = undefined;
    }

    pub fn find(self: *Daemon, id: []const u8) ?*RuntimeJob {
        for (self.jobs.items) |job| if (std.mem.eql(u8, job.spec.id, id)) return job;
        return null;
    }

    pub fn setRunning(self: *Daemon, id: []const u8, running: bool) !void {
        const job = self.find(id) orelse return error.UnknownJob;
        if (running) try job.start() else job.stop();
        try self.savePaused();
    }

    pub fn stopAll(self: *Daemon) void {
        for (self.jobs.items) |job| job.stop();
    }

    pub fn reload(self: *Daemon, problem: *Io.Writer) !void {
        var specs = try config.loadConfig(self.allocator, self.io, self.config_path, problem);
        errdefer specs.deinit();
        const Existing = struct {
            job: *RuntimeJob,
            retained: bool = false,
            was_active: bool = false,
            was_paused: bool = false,
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
            existing.was_paused = existing.job.state.load(.acquire) == .paused;
            existing.was_active = !existing.retained and existing.job.state.load(.acquire) == .active;
            if (existing.was_active) existing.job.stop();
        }
        for (created.items) |job| {
            // A paused job stays paused when its definition changes.
            if (existing_by_id.get(job.spec.id)) |existing| if (existing.was_paused) continue;
            job.start() catch |err| {
                for (created.items) |created_job| created_job.stop();
                var restore_iterator = existing_by_id.valueIterator();
                while (restore_iterator.next()) |existing| {
                    if (existing.was_active) existing.job.start() catch |restart_err|
                        logEvent(self.io, "{s} failed to resume after reload: {t}", .{ existing.job.spec.id, restart_err });
                }
                return err;
            };
        }
        var cleanup_iterator = existing_by_id.valueIterator();
        while (cleanup_iterator.next()) |existing| {
            if (!existing.retained) existing.job.deinit();
        }
        self.jobs.deinit(self.allocator);
        self.jobs = next;
        created.deinit(self.allocator);
        specs.deinit();
        self.savePaused() catch |err| logEvent(self.io, "could not save paused jobs: {t}", .{err});
    }

    pub fn status(self: *const Daemon, allocator: Allocator) ![]JobStatus {
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
    const dir = std.fs.path.dirname(path).?;
    const paused_path = try std.fs.path.join(std.testing.allocator, &.{ dir, "paused.json" });
    defer std.testing.allocator.free(paused_path);
    var daemon = try Daemon.init(std.testing.allocator, std.testing.io, &environ, path, paused_path, &problem);
    defer daemon.deinit();

    const keep = daemon.find("keep").?;
    const change = daemon.find("change").?;
    try std.testing.expect(keep.owned_environ == null);
    try daemon.setRunning("keep", false);
    try std.testing.expect(keep.future == null);
    try daemon.setRunning("keep", true);
    try std.testing.expect(keep.future != null);
    try daemon.setRunning("keep", false);
    try daemon.setRunning("change", false);
    try daemon.setRunning("remove", false);

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
    try std.testing.expect(daemon.find("change").?.future == null);
    try std.testing.expect(daemon.find("remove") == null);
    var saved = try state_paths.loadPaused(std.testing.allocator, std.testing.io, paused_path);
    defer saved.deinit();
    try std.testing.expectEqual(@as(usize, 2), saved.value.len);
    try std.testing.expectEqualStrings("keep", saved.value[0]);
    try std.testing.expectEqualStrings("change", saved.value[1]);
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

    // Shutting down pauses nothing on disk; a restart resumes what the user did not pause.
    var restarted = try Daemon.init(std.testing.allocator, std.testing.io, &environ, path, paused_path, &problem);
    defer restarted.deinit();
    try std.testing.expectEqual(Status.paused, restarted.find("keep").?.state.load(.acquire));
    try std.testing.expectEqual(Status.paused, restarted.find("change").?.state.load(.acquire));
    try std.testing.expectEqual(Status.active, restarted.find("new").?.state.load(.acquire));
}
