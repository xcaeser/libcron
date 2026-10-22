//! The daemon's jobs: one libcron scheduler, a table from config job id to
//! scheduler job, and pause, resume and reload by id.

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

fn contains(ids: []const []const u8, id: []const u8) bool {
    for (ids) |candidate| if (std.mem.eql(u8, candidate, id)) return true;
    return false;
}

const Entry = struct {
    spec: JobSpec,
    job_id: libcron.JobId,
    paused: bool,
};

pub const Daemon = struct {
    allocator: Allocator,
    io: Io,
    parent_env: *const std.process.Environ.Map,
    config_path: []const u8,
    /// Ids of paused jobs, saved so pauses survive restarts. Borrowed.
    paused_path: []const u8,
    scheduler: libcron.Scheduler,
    entries: std.ArrayList(Entry),
    /// The config id of every job ever added, so the outcome of a run that
    /// outlives a reload still names its job. The observer reads it from job
    /// tasks, hence the mutex.
    // ponytail: grows by one id per job a reload adds; reloads are rare.
    names: std.AutoHashMapUnmanaged(libcron.JobId, []const u8),
    names_mutex: Io.Mutex,
    run_future: ?Io.Future(libcron.RunError!void),
    running: std.atomic.Value(bool),
    /// Why the config could not be loaded, while that leaves the daemon with
    /// no jobs. The daemon stays up so `croner reload` can recover; a
    /// service manager would otherwise restart it in a loop.
    problem: ?[]u8,

    /// Loads the config and adds its jobs, paused as `paused_path` records.
    /// Call `start` once the daemon is at its final address.
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
            .scheduler = .init(allocator),
            .entries = .empty,
            .names = .empty,
            .names_mutex = .init,
            .run_future = null,
            .running = .init(false),
            .problem = null,
        };
        errdefer result.deinit();
        var specs = config.loadConfig(allocator, io, parent_env, result.config_path, problem) catch |err| switch (err) {
            error.InvalidConfig => {
                try result.setProblem(problem.buffered());
                return result;
            },
            else => return err,
        };
        defer specs.deinit();
        var paused = try result.loadPaused();
        defer if (paused) |*ids| ids.deinit();
        const paused_ids: []const []const u8 = if (paused) |ids| ids.value else &.{};
        try result.entries.ensureTotalCapacity(allocator, specs.items.items.len);
        for (specs.items.items) |*spec| {
            const is_paused = contains(paused_ids, spec.id);
            const job_id = try result.addJob(spec, is_paused);
            result.entries.appendAssumeCapacity(.{ .spec = spec.move(), .job_id = job_id, .paused = is_paused });
        }
        return result;
    }

    /// The saved paused ids, or none, logged, when the file is unreadable.
    fn loadPaused(self: *Daemon) !?std.json.Parsed([]const []const u8) {
        return state_paths.loadPaused(self.allocator, self.io, self.paused_path) catch |err| switch (err) {
            error.OutOfMemory => err,
            else => {
                logEvent(self.io, "pausing no job: could not read {s}: {t}", .{ self.paused_path, err });
                return null;
            },
        };
    }

    pub fn deinit(self: *Daemon) void {
        self.shutdown();
        self.scheduler.deinit();
        for (self.entries.items) |*entry| entry.spec.deinit();
        self.entries.deinit(self.allocator);
        var names = self.names.valueIterator();
        while (names.next()) |name| self.allocator.free(name.*);
        self.names.deinit(self.allocator);
        if (self.problem) |text| self.allocator.free(text);
        self.allocator.free(self.config_path);
        self.* = undefined;
    }

    fn setProblem(self: *Daemon, text: []const u8) !void {
        const copy = try self.allocator.dupe(u8, text);
        if (self.problem) |old| self.allocator.free(old);
        self.problem = copy;
        logEvent(self.io, "{s}; no jobs run until croner reload succeeds", .{text});
    }

    pub fn start(self: *Daemon) !void {
        self.running.store(true, .release);
        self.run_future = Io.concurrent(self.io, run, .{self}) catch |err| {
            self.running.store(false, .release);
            return err;
        };
    }

    /// Stops the scheduler. Running commands get SIGTERM, then SIGKILL once
    /// their grace period ends.
    pub fn shutdown(self: *Daemon) void {
        if (self.run_future) |*future| {
            _ = future.cancel(self.io) catch {};
            self.run_future = null;
        }
    }

    fn run(self: *Daemon) libcron.RunError!void {
        defer self.running.store(false, .release);
        return self.scheduler.run(self.io, .init(self, notify));
    }

    fn notify(self: *Daemon, invocation: libcron.Invocation, outcome: libcron.Outcome) void {
        self.names_mutex.lockUncancelable(self.io);
        defer self.names_mutex.unlock(self.io);
        logEvent(self.io, "{s} {f}", .{ self.names.get(invocation.job_id) orelse "?", outcome });
    }

    fn addJob(self: *Daemon, spec: *const JobSpec, paused: bool) !libcron.JobId {
        const name = try self.allocator.dupe(u8, spec.id);
        errdefer self.allocator.free(name);
        {
            self.names_mutex.lockUncancelable(self.io);
            defer self.names_mutex.unlock(self.io);
            try self.names.ensureUnusedCapacity(self.allocator, 1);
        }
        var environ: ?std.process.Environ.Map = null;
        defer if (environ) |*map| map.deinit();
        const job_id = try self.scheduler.add(self.io, spec.expression, try self.commandTask(spec, &environ), .{
            .time_zone = spec.time_zone,
            .overlap = spec.overlap,
            .paused = paused,
        });
        self.names_mutex.lockUncancelable(self.io);
        defer self.names_mutex.unlock(self.io);
        self.names.putAssumeCapacity(job_id, name);
        return job_id;
    }

    /// Gives job `job_id` the spec's schedule and command; it keeps its id
    /// and its pause.
    fn replaceJob(self: *Daemon, job_id: libcron.JobId, spec: *const JobSpec) !void {
        var environ: ?std.process.Environ.Map = null;
        defer if (environ) |*map| map.deinit();
        _ = try self.scheduler.replace(self.io, job_id, spec.expression, try self.commandTask(spec, &environ), .{
            .time_zone = spec.time_zone,
            .overlap = spec.overlap,
        });
    }

    /// The spec's command; `environ` holds its merged environment until the
    /// scheduler has copied it.
    fn commandTask(self: *Daemon, spec: *const JobSpec, environ: *?std.process.Environ.Map) !libcron.Task {
        if (spec.env.len > 0) {
            environ.* = try self.parent_env.clone(self.allocator);
            for (spec.env) |entry| try environ.*.?.put(entry.key, entry.value);
        }
        return .{ .command = .{
            .argv = spec.argv,
            .cwd = .{ .path = spec.cwd },
            .environ_map = if (environ.*) |*map| map else self.parent_env,
        } };
    }

    fn indexOf(self: *const Daemon, id: []const u8) ?usize {
        for (self.entries.items, 0..) |entry, index| if (std.mem.eql(u8, entry.spec.id, id)) return index;
        return null;
    }

    fn savePaused(self: *Daemon) !void {
        var ids: std.ArrayList([]const u8) = .empty;
        defer ids.deinit(self.allocator);
        for (self.entries.items) |entry| {
            if (entry.paused) try ids.append(self.allocator, entry.spec.id);
        }
        try state_paths.savePaused(self.allocator, self.io, self.paused_path, ids.items);
    }

    pub fn setRunning(self: *Daemon, id: []const u8, running: bool) !void {
        const entry = &self.entries.items[self.indexOf(id) orelse return error.UnknownJob];
        if (entry.paused == !running) return;
        _ = if (running) self.scheduler.unpause(self.io, entry.job_id) else self.scheduler.pause(self.io, entry.job_id);
        entry.paused = !running;
        try self.savePaused();
    }

    /// Applies the config by job id: an unchanged job is left alone, a
    /// changed one is replaced in place and keeps its id and pause, a removed
    /// one is removed, and a new one is added, paused if the saved paused ids
    /// list it. New jobs are added first and removed again if anything fails;
    /// replacements cannot be undone, so they come next, and only running out
    /// of memory can stop them partway, with each entry updated as its job is.
    pub fn reload(self: *Daemon, problem: *Io.Writer) !void {
        var specs = config.loadConfig(self.allocator, self.io, self.parent_env, self.config_path, problem) catch |err| {
            if (err == error.InvalidConfig and self.problem != null) try self.setProblem(problem.buffered());
            return err;
        };
        defer specs.deinit();
        const new_specs = specs.items.items;
        var paused = try self.loadPaused();
        defer if (paused) |*ids| ids.deinit();
        const paused_ids: []const []const u8 = if (paused) |ids| ids.value else &.{};
        const Target = union(enum) {
            existing: usize,
            added: struct { job_id: libcron.JobId, paused: bool },
        };
        const targets = try self.allocator.alloc(Target, new_specs.len);
        defer self.allocator.free(targets);
        const kept = try self.allocator.alloc(bool, self.entries.items.len);
        defer self.allocator.free(kept);
        @memset(kept, false);
        var next: std.ArrayList(Entry) = try .initCapacity(self.allocator, new_specs.len);
        errdefer next.deinit(self.allocator);

        var planned: usize = 0;
        errdefer for (targets[0..planned]) |target| switch (target) {
            .existing => {},
            .added => |added| _ = self.scheduler.remove(self.io, added.job_id),
        };
        for (new_specs, targets) |*spec, *target| {
            if (self.indexOf(spec.id)) |index| {
                target.* = .{ .existing = index };
                kept[index] = true;
            } else {
                const is_paused = contains(paused_ids, spec.id);
                target.* = .{ .added = .{ .job_id = try self.addJob(spec, is_paused), .paused = is_paused } };
            }
            planned += 1;
        }
        for (new_specs, targets) |*spec, target| switch (target) {
            .existing => |index| {
                const entry = &self.entries.items[index];
                if (entry.spec.eql(spec)) continue;
                try self.replaceJob(entry.job_id, spec);
                entry.spec.deinit();
                entry.spec = spec.move();
            },
            .added => {},
        };

        for (new_specs, targets) |*spec, target| next.appendAssumeCapacity(switch (target) {
            .existing => |index| self.entries.items[index],
            .added => |added| .{ .spec = spec.move(), .job_id = added.job_id, .paused = added.paused },
        });
        for (self.entries.items, kept) |*entry, keep| {
            if (keep) continue;
            _ = self.scheduler.remove(self.io, entry.job_id);
            entry.spec.deinit();
        }
        self.entries.deinit(self.allocator);
        self.entries = next;
        if (self.problem) |text| {
            self.allocator.free(text);
            self.problem = null;
        }
        self.savePaused() catch |err| logEvent(self.io, "could not save paused jobs: {t}", .{err});
    }

    pub fn status(self: *const Daemon, allocator: Allocator) ![]JobStatus {
        const running = self.running.load(.acquire);
        const result = try allocator.alloc(JobStatus, self.entries.items.len);
        for (self.entries.items, result) |entry, *item| item.* = .{
            .id = entry.spec.id,
            .schedule = entry.spec.schedule,
            .status = if (!running) .offline else if (entry.paused) .paused else .active,
        };
        return result;
    }
};

/// Reads the scheduler's own flag: a job added or replaced paused must never
/// be dispatchable, even for the instant before a separate `pause`.
fn schedulerPaused(daemon: *const Daemon, job_id: libcron.JobId) bool {
    for (daemon.scheduler.jobs.items) |job| if (job.id == job_id) return job.paused;
    unreachable;
}

fn expectStatus(daemon: *const Daemon, id: []const u8, expected: Status) !void {
    const statuses = try daemon.status(std.testing.allocator);
    defer std.testing.allocator.free(statuses);
    for (statuses) |item| if (std.mem.eql(u8, item.id, id)) return std.testing.expectEqual(expected, item.status);
    return error.TestUnexpectedResult;
}

test "one scheduler pauses, resumes and reloads jobs by id" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const initial = "{\"jobs\":[{\"id\":\"keep\",\"schedule\":\"* * * * *\",\"action\":{\"command\":{\"argv\":[\"/usr/bin/true\"]}}},{\"id\":\"change\",\"schedule\":\"* * * * *\",\"action\":{\"command\":{\"argv\":[\"/usr/bin/true\"]}}},{\"id\":\"remove\",\"schedule\":\"* * * * *\",\"action\":{\"command\":{\"argv\":[\"/usr/bin/true\"]}}}]}";
    try tmp.dir.writeFile(io, .{ .sub_path = "croner.json", .data = initial });
    const path = try tmp.dir.realPathFileAlloc(io, "croner.json", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const paused_path = try std.fs.path.join(std.testing.allocator, &.{ std.fs.path.dirname(path).?, "paused.json" });
    defer std.testing.allocator.free(paused_path);
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    var problem_buffer: [512]u8 = undefined;
    var problem: Io.Writer = .fixed(&problem_buffer);
    var daemon = try Daemon.init(std.testing.allocator, io, &environ, path, paused_path, &problem);
    defer daemon.deinit();
    try daemon.start();

    try expectStatus(&daemon, "keep", .active);
    try daemon.setRunning("keep", false);
    try expectStatus(&daemon, "keep", .paused);
    try daemon.setRunning("keep", true);
    try expectStatus(&daemon, "keep", .active);
    try daemon.setRunning("keep", false);
    try daemon.setRunning("change", false);
    try daemon.setRunning("remove", false);
    try std.testing.expectError(error.UnknownJob, daemon.setRunning("nope", false));
    const keep_id = daemon.entries.items[daemon.indexOf("keep").?].job_id;
    const change_id = daemon.entries.items[daemon.indexOf("change").?].job_id;
    const remove_id = daemon.entries.items[daemon.indexOf("remove").?].job_id;

    const invalid = "{\"jobs\":[{\"id\":\"keep\",\"schedule\":\"* * * * *\",\"action\":{\"command\":{\"argv\":[\"/usr/bin/true\"]}}},{\"id\":\"keep\",\"schedule\":\"* * * * *\",\"action\":{\"command\":{\"argv\":[\"/usr/bin/true\"]}}}]}";
    try tmp.dir.writeFile(io, .{ .sub_path = "croner.json", .data = invalid });
    try std.testing.expectError(error.InvalidConfig, daemon.reload(&problem));
    try std.testing.expectEqual(@as(usize, 3), daemon.entries.items.len);
    try std.testing.expectEqual(change_id, daemon.entries.items[daemon.indexOf("change").?].job_id);

    const updated = "{\"jobs\":[{\"id\":\"keep\",\"schedule\":\"* * * * *\",\"action\":{\"command\":{\"argv\":[\"/usr/bin/true\"]}}},{\"id\":\"change\",\"schedule\":\"*/2 * * * *\",\"action\":{\"command\":{\"argv\":[\"/usr/bin/true\"]}}},{\"id\":\"new\",\"schedule\":\"* * * * *\",\"action\":{\"command\":{\"argv\":[\"/usr/bin/true\"],\"env\":{\"CRONER_TEST\":\"1\"}}}}]}";
    try tmp.dir.writeFile(io, .{ .sub_path = "croner.json", .data = updated });
    try daemon.reload(&problem);
    try std.testing.expectEqual(keep_id, daemon.entries.items[daemon.indexOf("keep").?].job_id);
    try expectStatus(&daemon, "keep", .paused);
    // A changed job is replaced in place: same id, still paused.
    try std.testing.expectEqual(change_id, daemon.entries.items[daemon.indexOf("change").?].job_id);
    try expectStatus(&daemon, "change", .paused);
    try std.testing.expect(schedulerPaused(&daemon, change_id));
    try std.testing.expect(daemon.indexOf("remove") == null);
    try std.testing.expect(!daemon.scheduler.remove(io, remove_id));
    try expectStatus(&daemon, "new", .active);
    var saved = try state_paths.loadPaused(std.testing.allocator, io, paused_path);
    defer saved.deinit();
    try std.testing.expectEqual(@as(usize, 2), saved.value.len);
    try std.testing.expectEqualStrings("keep", saved.value[0]);
    try std.testing.expectEqualStrings("change", saved.value[1]);

    daemon.shutdown();
    try expectStatus(&daemon, "new", .offline);

    // Shutting down pauses nothing on disk; a restart resumes what the user did not pause.
    var restarted = try Daemon.init(std.testing.allocator, io, &environ, path, paused_path, &problem);
    defer restarted.deinit();
    try restarted.start();
    try expectStatus(&restarted, "keep", .paused);
    try expectStatus(&restarted, "change", .paused);
    try expectStatus(&restarted, "new", .active);
}

test "an invalid config leaves the daemon up with no jobs until a reload succeeds" {
    // A reload that adds a job the saved paused ids list adds it paused.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "croner.json", .data = "{\"jobs\":[{\"id\":\"x\",\"schedule\":\"0 25 * * *\",\"action\":{\"command\":{\"argv\":[\"/usr/bin/true\"]}}}]}" });
    const path = try tmp.dir.realPathFileAlloc(io, "croner.json", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const paused_path = try std.fs.path.join(std.testing.allocator, &.{ std.fs.path.dirname(path).?, "paused.json" });
    defer std.testing.allocator.free(paused_path);
    try state_paths.savePaused(std.testing.allocator, io, paused_path, &.{"x"});
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    var problem_buffer: [512]u8 = undefined;
    var problem: Io.Writer = .fixed(&problem_buffer);
    var daemon = try Daemon.init(std.testing.allocator, io, &environ, path, paused_path, &problem);
    defer daemon.deinit();
    try daemon.start();
    try std.testing.expectEqual(@as(usize, 0), daemon.entries.items.len);
    try std.testing.expect(std.mem.endsWith(u8, daemon.problem.?, "hour values must be within 0-23"));

    try tmp.dir.writeFile(io, .{ .sub_path = "croner.json", .data = "{\"jobs\":[{\"id\":\"x\",\"schedule\":\"0 23 * * *\",\"action\":{\"command\":{\"argv\":[\"/usr/bin/true\"]}}}]}" });
    problem = .fixed(&problem_buffer);
    try daemon.reload(&problem);
    try std.testing.expect(daemon.problem == null);
    try expectStatus(&daemon, "x", .paused);
    try std.testing.expect(schedulerPaused(&daemon, daemon.entries.items[0].job_id));
}
