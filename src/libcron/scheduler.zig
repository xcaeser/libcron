//! The job collection and the loop that dispatches it every minute.

const std = @import("std");
const calendar = @import("calendar.zig");
const command = @import("command.zig");
const Expression = @import("expression.zig").Expression;
const TimeZone = @import("time_zone.zig").TimeZone;
const job_module = @import("job.zig");

const Invocation = job_module.Invocation;
const Job = job_module.Job;
const JobId = job_module.JobId;
const JobOptions = job_module.JobOptions;
const Observer = job_module.Observer;
const Outcome = job_module.Outcome;
const Task = job_module.Task;
const max_catch_up_minutes = @import("wall_clock.zig").max_catch_up_minutes;
const report = job_module.report;

pub const AddError = std.mem.Allocator.Error || error{
    InvalidCommand,
    JobIdExhausted,
};

/// Only cancellation ends a running scheduler; job failures go to the observer.
pub const RunError = std.Io.Cancelable || error{
    AlreadyRunning,
};

/// An in-memory scheduler. Jobs can be added, removed, paused, and unpaused
/// from any task at any time, also while `run` is active. Call `deinit` only
/// after `run` has returned.
pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    /// Guards every field below, and every field of their jobs except
    /// `in_flight`.
    mutex: std.Io.Mutex,
    /// Ordered by id. Each job is allocated on its own so running
    /// invocations keep a valid pointer after it is removed.
    jobs: std.ArrayList(*Job),
    /// Removed jobs whose last invocation has not finished yet.
    retired: std.ArrayList(*Job),
    /// Command strings that `replace` swapped out while the job was running.
    /// ponytail: freed once the job is idle; a `.concurrent` job that is
    /// never idle keeps them until it is removed.
    stale: std.ArrayList(Stale),
    next_id: u64,
    running: bool,

    pub fn init(allocator: std.mem.Allocator) Scheduler {
        return .{
            .allocator = allocator,
            .mutex = .init,
            .jobs = .empty,
            .retired = .empty,
            .stale = .empty,
            .next_id = 0,
            .running = false,
        };
    }

    pub fn deinit(self: *Scheduler) void {
        std.debug.assert(!self.running);
        for (self.jobs.items) |job| self.destroy(job);
        for (self.retired.items) |job| self.destroy(job);
        self.jobs.deinit(self.allocator);
        self.retired.deinit(self.allocator);
        self.stale.deinit(self.allocator);
        self.* = undefined;
    }

    /// Adds a job, which first runs at the next minute it matches. Command
    /// strings are copied; a callback's context must stay valid until the job
    /// is removed and its last outcome reported, or the scheduler is
    /// deinitialized.
    pub fn add(
        self: *Scheduler,
        io: std.Io,
        expression: Expression,
        task: Task,
        options: JobOptions,
    ) AddError!JobId {
        if (task == .command) try task.command.validate();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.next_id == std.math.maxInt(u64)) return error.JobIdExhausted;

        // Reserved so `remove` cannot fail.
        try self.retired.ensureTotalCapacity(self.allocator, self.jobs.items.len + self.retired.items.len + 1);
        try self.jobs.ensureUnusedCapacity(self.allocator, 1);
        const job = try self.allocator.create(Job);
        errdefer self.allocator.destroy(job);
        job.* = .{
            .id = @fromBackingInt(self.next_id),
            .expression = expression,
            .task = task,
            .options = options,
            .arena = .init(self.allocator),
            .paused = options.paused,
        };
        errdefer job.arena.deinit();
        if (task == .command) job.task = .{ .command = try command.dupe(task.command, job.arena.allocator()) };

        self.jobs.appendAssumeCapacity(job);
        self.next_id += 1;
        return job.id;
    }

    /// Changes a job's schedule, task, and options in place and returns
    /// whether it exists. The job keeps its id and its paused state
    /// (`options.paused` is ignored). Running invocations finish with the old
    /// task, and with `.skip` the job does not start again until they have;
    /// an old callback context must stay valid until then. The job's DST
    /// state carries over unless the new time zone reads a different local
    /// time, so replacing a job inside a repeated hour does not rerun it.
    pub fn replace(
        self: *Scheduler,
        io: std.Io,
        id: JobId,
        expression: Expression,
        task: Task,
        options: JobOptions,
    ) AddError!bool {
        if (task == .command) try task.command.validate();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const index = self.indexOf(id) orelse return false;
        const job = self.jobs.items[index];

        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        errdefer arena.deinit();
        const owned_task: Task = if (task == .command)
            .{ .command = try command.dupe(task.command, arena.allocator()) }
        else
            task;
        if (job.in_flight.load(.acquire) == 0)
            job.arena.deinit()
        else
            try self.stale.append(self.allocator, .{ .job = job, .arena = job.arena });

        if (job.seen) |seen| {
            const local = options.time_zone.toLocal(seen.unix_seconds) catch null;
            if (local == null or !std.meta.eql(local.?, seen.local)) job.wall = .{};
        }
        job.expression = expression;
        job.task = owned_task;
        job.options = options;
        job.arena = arena;
        return true;
    }

    /// Removes a job and returns whether it existed. A running invocation
    /// finishes and reports its outcome; the job is not dispatched again.
    pub fn remove(self: *Scheduler, io: std.Io, id: JobId) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const index = self.indexOf(id) orelse return false;
        const job = self.jobs.orderedRemove(index);
        if (job.in_flight.load(.acquire) == 0)
            self.destroy(job)
        else
            self.retired.appendAssumeCapacity(job);
        return true;
    }

    /// Stops dispatching a job until `unpause` and returns whether it exists.
    /// A running invocation is not interrupted.
    pub fn pause(self: *Scheduler, io: std.Io, id: JobId) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const index = self.indexOf(id) orelse return false;
        self.jobs.items[index].paused = true;
        return true;
    }

    /// Dispatches a paused job again from the next minute, without catching up
    /// minutes it matched while paused, and returns whether it exists.
    pub fn unpause(self: *Scheduler, io: std.Io, id: JobId) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const index = self.indexOf(id) orelse return false;
        self.jobs.items[index].paused = false;
        return true;
    }

    /// Runs until canceled. The caller-provided `io` must support concurrency.
    pub fn run(self: *Scheduler, io: std.Io, observer: ?Observer) RunError!void {
        {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            if (self.running) return error.AlreadyRunning;
            self.running = true;
            // Minutes that passed while stopped are not caught up.
            for (self.jobs.items) |job| job.wall = .{};
        }
        defer {
            self.mutex.lockUncancelable(io);
            self.running = false;
            self.mutex.unlock(io);
        }

        var jobs: std.Io.Group = .init;
        defer jobs.cancel(io);

        var last_minute = unixMinute(std.Io.Clock.real.now(io).nanoseconds);
        while (true) {
            const step = tick(std.Io.Clock.real.now(io).nanoseconds, last_minute);
            if (step.due_minute) |minute| {
                self.dispatchMinute(io, &jobs, minute, observer);
                last_minute = minute;
            }
            const deadline: std.Io.Clock.Timestamp = .{
                .raw = .{ .nanoseconds = step.deadline_ns },
                .clock = .real,
            };
            try deadline.wait(io);
        }
    }

    fn dispatchMinute(
        self: *Scheduler,
        io: std.Io,
        group: *std.Io.Group,
        unix_minute: i64,
        observer: ?Observer,
    ) void {
        self.sweep(io);
        // Only instants outside the years 1 through 65535 fail to convert.
        const unix_seconds = std.math.mul(i64, unix_minute, 60) catch return;
        var cursor: u64 = 0;
        while (self.nextDue(io, &cursor, unix_seconds)) |due| switch (due) {
            .skipped => |invocation| report(observer, invocation, .skipped_overlap),
            .claimed => |claimed| group.concurrent(
                io,
                job_module.execute,
                .{ claimed.job, claimed.task, claimed.termination_grace, io, claimed.invocation, observer },
            ) catch |err| {
                claimed.job.release();
                report(observer, claimed.invocation, .{ .dispatch_error = err });
            },
        };
    }

    const Due = union(enum) {
        skipped: Invocation,
        claimed: struct {
            job: *Job,
            task: Task,
            termination_grace: std.Io.Duration,
            invocation: Invocation,
        },
    };

    const Stale = struct {
        job: *Job,
        arena: std.heap.ArenaAllocator,
    };

    /// Finds the first job with an id at or after `cursor` that is due, and
    /// moves `cursor` past it. The lock is held only during the search, so
    /// the caller can start the job and notify the observer unlocked.
    fn nextDue(self: *Scheduler, io: std.Io, cursor: *u64, unix_seconds: i64) ?Due {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const start = std.sort.partitionPoint(*Job, self.jobs.items, cursor.*, idBefore);
        for (self.jobs.items[start..]) |job| {
            cursor.* = @backingInt(job.id) + 1;
            const local_time = job.options.time_zone.toLocal(unix_seconds) catch continue;
            job.seen = .{ .unix_seconds = unix_seconds, .local = local_time };
            // A paused job's wall clock keeps running, so unpausing it inside
            // a repeated hour does not rerun it and nothing is caught up.
            const due = job.wall.due(job.expression, local_time);
            if (job.paused or !due) continue;
            const invocation: Invocation = .{
                .job_id = job.id,
                .scheduled_unix_seconds = unix_seconds,
                .local_time = local_time,
            };
            if (!job.claim()) return .{ .skipped = invocation };
            return .{ .claimed = .{
                .job = job,
                .task = job.task,
                .termination_grace = job.options.termination_grace,
                .invocation = invocation,
            } };
        }
        return null;
    }

    fn idBefore(cursor: u64, job: *Job) bool {
        return @backingInt(job.id) < cursor;
    }

    /// Frees removed jobs and replaced command strings that no running
    /// invocation uses anymore.
    fn sweep(self: *Scheduler, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var stale_index: usize = 0;
        while (stale_index < self.stale.items.len) {
            if (self.stale.items[stale_index].job.in_flight.load(.acquire) == 0) {
                self.stale.swapRemove(stale_index).arena.deinit();
            } else stale_index += 1;
        }
        var index: usize = 0;
        while (index < self.retired.items.len) {
            const job = self.retired.items[index];
            if (job.in_flight.load(.acquire) == 0) {
                self.destroy(job);
                _ = self.retired.swapRemove(index);
            } else index += 1;
        }
    }

    fn indexOf(self: *Scheduler, id: JobId) ?usize {
        const index = std.sort.partitionPoint(*Job, self.jobs.items, @backingInt(id), idBefore);
        if (index == self.jobs.items.len or self.jobs.items[index].id != id) return null;
        return index;
    }

    fn destroy(self: *Scheduler, job: *Job) void {
        var index: usize = 0;
        while (index < self.stale.items.len) {
            if (self.stale.items[index].job == job) {
                self.stale.swapRemove(index).arena.deinit();
            } else index += 1;
        }
        job.arena.deinit();
        self.allocator.destroy(job);
    }
};

fn unixMinute(unix_nanoseconds: i96) i64 {
    return @intCast(@divFloor(unix_nanoseconds, std.time.ns_per_min));
}

const Tick = struct {
    due_minute: ?i64,
    deadline_ns: i96,
};

/// Decides what the run loop does after reading the real clock: which unix
/// minute to dispatch, if any, and when to read the clock again. A minute at
/// or before `last_minute` is never dispatched again, so a wall clock stepped
/// back, or a relative sleep that outlasts such a step, cannot rerun jobs. A
/// step back of three hours or more is taken as the new time instead of
/// leaving the scheduler idle until the clock catches up.
fn tick(now_ns: i96, last_minute: i64) Tick {
    const minute = unixMinute(now_ns);
    const due = minute > last_minute or last_minute - minute >= max_catch_up_minutes;
    const wake_minute = if (due) minute + 1 else last_minute + 1;
    return .{
        .due_minute = if (due) minute else null,
        .deadline_ns = @as(i96, wake_minute) * std.time.ns_per_min,
    };
}

const TestOutcomes = struct {
    callback_success: std.atomic.Value(u32) = .init(0),
    callback_error: std.atomic.Value(u32) = .init(0),
    skipped_overlap: std.atomic.Value(u32) = .init(0),
    command_exit: std.atomic.Value(i32) = .init(-1),
    dispatch_error: std.atomic.Value(u32) = .init(0),
    last_success_seconds: std.atomic.Value(i64) = .init(0),

    fn notify(context: ?*anyopaque, invocation: Invocation, outcome: Outcome) void {
        const self: *TestOutcomes = @ptrCast(@alignCast(context.?));
        switch (outcome) {
            .callback_success => {
                _ = self.callback_success.fetchAdd(1, .monotonic);
                self.last_success_seconds.store(invocation.scheduled_unix_seconds, .monotonic);
            },
            .callback_error => _ = self.callback_error.fetchAdd(1, .monotonic),
            .skipped_overlap => _ = self.skipped_overlap.fetchAdd(1, .monotonic),
            .command_terminated => |finished| switch (finished.term) {
                .exited => |code| self.command_exit.store(code, .monotonic),
                else => self.command_exit.store(-2, .monotonic),
            },
            .command_error => self.command_exit.store(-3, .monotonic),
            .dispatch_error => _ = self.dispatch_error.fetchAdd(1, .monotonic),
        }
    }

    fn observer(self: *TestOutcomes) Observer {
        return .{ .context = self, .notify = notify };
    }
};

fn successfulTestCallback(_: ?*anyopaque, _: std.Io, _: Invocation) anyerror!void {}

fn failingTestCallback(_: ?*anyopaque, _: std.Io, _: Invocation) anyerror!void {
    return error.ExpectedCallbackFailure;
}

fn blockingTestCallback(_: ?*anyopaque, io: std.Io, _: Invocation) anyerror!void {
    try std.Io.sleep(io, .fromSeconds(60), .awake);
}

/// Dispatches minutes one at a time to a single callback job.
const TestClock = struct {
    scheduler: Scheduler,
    outcomes: TestOutcomes = .{},

    fn init(schedule: []const u8, zone: TimeZone) !TestClock {
        var scheduler = Scheduler.init(std.testing.allocator);
        errdefer scheduler.deinit();
        _ = try scheduler.add(
            std.testing.io,
            try Expression.parse(schedule),
            .{ .callback = .{ .run = successfulTestCallback } },
            .{ .time_zone = zone },
        );
        return .{ .scheduler = scheduler };
    }

    fn deinit(self: *TestClock) void {
        self.scheduler.deinit();
    }

    fn dispatch(self: *TestClock, unix_minute: i64) !void {
        var group: std.Io.Group = .init;
        defer group.cancel(std.testing.io);
        self.scheduler.dispatchMinute(std.testing.io, &group, unix_minute, self.outcomes.observer());
        try group.await(std.testing.io);
    }

    fn dispatchRange(self: *TestClock, first: i64, end: i64) !void {
        var minute = first;
        while (minute < end) : (minute += 1) try self.dispatch(minute);
    }

    fn fired(self: *TestClock) u32 {
        return self.outcomes.callback_success.load(.monotonic);
    }
};

fn utcMinute(year: u16, month: calendar.Month, day: u8, hour: u8, minute: u8) i64 {
    return calendar.epochMinute(.{ .year = year, .month = month, .day = day, .hour = hour, .minute = minute });
}

fn footerTz(footer: []const u8) std.Tz {
    return .{
        .allocator = std.testing.allocator,
        .transitions = &.{},
        .timetypes = &.{.{ .offset = 0, .flags = 0, .name_data = .{ 'S', 'T', 'D', 0, 0, 0 } }},
        .leapseconds = &.{},
        .footer = footer,
    };
}

test "run loop never dispatches a minute twice when the wall clock steps back" {
    const minute_ns: i96 = std.time.ns_per_min;
    const last: i64 = 29_000_000;
    try std.testing.expectEqual(
        Tick{ .due_minute = last + 1, .deadline_ns = (last + 2) * minute_ns },
        tick((last + 1) * minute_ns + 5, last),
    );
    try std.testing.expectEqual(
        Tick{ .due_minute = null, .deadline_ns = (last + 1) * minute_ns },
        tick(last * minute_ns + 30 * std.time.ns_per_s, last),
    );
    try std.testing.expectEqual(
        Tick{ .due_minute = null, .deadline_ns = (last + 1) * minute_ns },
        tick((last - 10) * minute_ns, last),
    );
    try std.testing.expectEqual(
        Tick{ .due_minute = last + 90, .deadline_ns = (last + 91) * minute_ns },
        tick((last + 90) * minute_ns, last),
    );
    try std.testing.expectEqual(
        Tick{ .due_minute = last - 180, .deadline_ns = (last - 179) * minute_ns },
        tick((last - 180) * minute_ns, last),
    );
    try std.testing.expectEqual(-1, unixMinute(-1));
}

test "fixed-time jobs run once and wildcard jobs every real quarter hour across DST" {
    const Transition = struct {
        schedule: []const u8,
        /// The UTC minute the fixed-time job must run at.
        expected: i64,
    };
    const cases = [_]struct { footer: []const u8, spring: Transition, fall: Transition }{
        .{
            .footer = "CET-1CEST,M3.5.0,M10.5.0/3",
            .spring = .{ .schedule = "30 2 * * *", .expected = utcMinute(2026, .mar, 29, 1, 0) },
            .fall = .{ .schedule = "30 2 * * *", .expected = utcMinute(2026, .oct, 25, 0, 30) },
        },
        .{
            .footer = "EST5EDT,M3.2.0,M11.1.0",
            .spring = .{ .schedule = "30 2 * * *", .expected = utcMinute(2026, .mar, 8, 7, 0) },
            .fall = .{ .schedule = "30 1 * * *", .expected = utcMinute(2026, .nov, 1, 5, 30) },
        },
        .{
            .footer = "AEST-10AEDT,M10.1.0,M4.1.0/3",
            .spring = .{ .schedule = "30 2 * * *", .expected = utcMinute(2026, .oct, 3, 16, 0) },
            .fall = .{ .schedule = "30 2 * * *", .expected = utcMinute(2026, .apr, 4, 15, 30) },
        },
        .{
            .footer = "<+1030>-10:30<+11>-11,M10.1.0,M4.1.0",
            .spring = .{ .schedule = "15 2 * * *", .expected = utcMinute(2026, .oct, 3, 15, 30) },
            .fall = .{ .schedule = "45 1 * * *", .expected = utcMinute(2026, .apr, 4, 14, 45) },
        },
        .{
            .footer = "IST-1GMT0,M10.5.0,M3.5.0/1",
            .spring = .{ .schedule = "30 1 * * *", .expected = utcMinute(2026, .mar, 29, 1, 0) },
            .fall = .{ .schedule = "30 1 * * *", .expected = utcMinute(2026, .oct, 25, 0, 30) },
        },
    };
    for (cases) |case| {
        const tz = footerTz(case.footer);
        const zone = try TimeZone.fromTz(&tz);
        for ([_]Transition{ case.spring, case.fall }) |transition| {
            errdefer std.debug.print("{s} {s}\n", .{ case.footer, transition.schedule });
            // Neighbouring days run at least 23 hours away, outside this window.
            const first = transition.expected - 12 * 60;
            const end = transition.expected + 12 * 60;

            var daily = try TestClock.init(transition.schedule, zone);
            defer daily.deinit();
            try daily.dispatchRange(first, end);
            try std.testing.expectEqual(1, daily.fired());
            try std.testing.expectEqual(transition.expected * 60, daily.outcomes.last_success_seconds.load(.monotonic));

            var quarter_hourly = try TestClock.init("*/15 * * * *", zone);
            defer quarter_hourly.deinit();
            try quarter_hourly.dispatchRange(first, end);
            try std.testing.expectEqual(24 * 4, quarter_hourly.fired());
        }
    }
}

test "late wakes catch up fixed-time jobs skipped by less than three hours" {
    var fixed = try TestClock.init("0,10 4 * * *", .utc);
    defer fixed.deinit();
    try fixed.dispatch(utcMinute(2026, .jan, 1, 3, 59));
    try fixed.dispatch(utcMinute(2026, .jan, 1, 4, 30));
    try std.testing.expectEqual(1, fixed.fired());
    try fixed.dispatch(utcMinute(2026, .jan, 1, 4, 31));
    try fixed.dispatch(utcMinute(2026, .jan, 2, 8, 0));
    try std.testing.expectEqual(1, fixed.fired());

    var wildcard = try TestClock.init("*/20 4 * * *", .utc);
    defer wildcard.deinit();
    try wildcard.dispatch(utcMinute(2026, .jan, 1, 4, 0));
    try wildcard.dispatch(utcMinute(2026, .jan, 1, 4, 30));
    try std.testing.expectEqual(1, wildcard.fired());
}

test "scheduler lifecycle and single-minute callback dispatch" {
    var scheduler = Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    const every_minute = try Expression.parse("* * * * *");
    try std.testing.expectError(
        error.InvalidCommand,
        scheduler.add(std.testing.io, every_minute, .{ .command = .{ .argv = &.{} } }, .{}),
    );
    try std.testing.expectError(
        error.InvalidCommand,
        scheduler.add(std.testing.io, every_minute, .{ .command = .{ .argv = &.{ "echo", "bad\x00argument" } } }, .{}),
    );
    try std.testing.expectError(
        error.InvalidCommand,
        scheduler.add(std.testing.io, every_minute, .{ .command = .{ .argv = &.{"echo"}, .cwd = .{ .path = "" } } }, .{}),
    );
    try std.testing.expectError(
        error.InvalidCommand,
        scheduler.add(std.testing.io, every_minute, .{ .command = .{ .argv = &.{"echo"}, .cwd = .{ .path = "bad\x00path" } } }, .{}),
    );
    var invalid_environ = std.process.Environ.Map.init(std.testing.allocator);
    defer invalid_environ.deinit();
    try invalid_environ.put("KEY", "bad\x00value");
    try std.testing.expectError(
        error.InvalidCommand,
        scheduler.add(std.testing.io, every_minute, .{ .command = .{ .argv = &.{"echo"}, .environ_map = &invalid_environ } }, .{}),
    );
    const success_id = try scheduler.add(
        std.testing.io,
        every_minute,
        .{ .callback = .{ .run = successfulTestCallback } },
        .{},
    );
    const failure_id = try scheduler.add(
        std.testing.io,
        every_minute,
        .{ .callback = .{ .run = failingTestCallback } },
        .{},
    );
    try std.testing.expect(@backingInt(failure_id) > @backingInt(success_id));

    var outcomes: TestOutcomes = .{};
    var group: std.Io.Group = .init;
    defer group.cancel(std.testing.io);
    scheduler.dispatchMinute(std.testing.io, &group, 0, outcomes.observer());
    try group.await(std.testing.io);
    try std.testing.expectEqual(1, outcomes.callback_success.load(.monotonic));
    try std.testing.expectEqual(1, outcomes.callback_error.load(.monotonic));

    try std.testing.expect(scheduler.remove(std.testing.io, success_id));
    try std.testing.expect(!scheduler.remove(std.testing.io, success_id));
}

test "scheduler applies overlap policies and cancellation cleanup" {
    const every_minute = try Expression.parse("* * * * *");

    var skipped = Scheduler.init(std.testing.allocator);
    defer skipped.deinit();
    _ = try skipped.add(
        std.testing.io,
        every_minute,
        .{ .callback = .{ .run = blockingTestCallback } },
        .{ .overlap = .skip },
    );
    var skipped_outcomes: TestOutcomes = .{};
    var skipped_group: std.Io.Group = .init;
    defer skipped_group.cancel(std.testing.io);
    skipped.dispatchMinute(std.testing.io, &skipped_group, 0, skipped_outcomes.observer());
    skipped.dispatchMinute(std.testing.io, &skipped_group, 1, skipped_outcomes.observer());
    try std.testing.expectEqual(1, skipped_outcomes.skipped_overlap.load(.monotonic));

    var concurrent = Scheduler.init(std.testing.allocator);
    defer concurrent.deinit();
    _ = try concurrent.add(
        std.testing.io,
        every_minute,
        .{ .callback = .{ .run = successfulTestCallback } },
        .{ .overlap = .concurrent },
    );
    var concurrent_outcomes: TestOutcomes = .{};
    var concurrent_group: std.Io.Group = .init;
    defer concurrent_group.cancel(std.testing.io);
    concurrent.dispatchMinute(std.testing.io, &concurrent_group, 0, concurrent_outcomes.observer());
    concurrent.dispatchMinute(std.testing.io, &concurrent_group, 1, concurrent_outcomes.observer());
    try concurrent_group.await(std.testing.io);
    try std.testing.expectEqual(2, concurrent_outcomes.callback_success.load(.monotonic));

    var canceled = Scheduler.init(std.testing.allocator);
    defer canceled.deinit();
    _ = try canceled.add(
        std.testing.io,
        every_minute,
        .{ .callback = .{ .run = blockingTestCallback } },
        .{},
    );
    var canceled_group: std.Io.Group = .init;
    canceled.dispatchMinute(std.testing.io, &canceled_group, 0, null);
    try std.testing.expectEqual(1, canceled.jobs.items[0].in_flight.load(.acquire));
    canceled_group.cancel(std.testing.io);
    try std.testing.expectEqual(0, canceled.jobs.items[0].in_flight.load(.acquire));

    var run_future = try std.Io.concurrent(
        std.testing.io,
        Scheduler.run,
        .{ &canceled, std.testing.io, null },
    );
    try std.testing.expectError(error.Canceled, run_future.cancel(std.testing.io));
    try std.testing.expect(!canceled.running);
}

test "scheduler reports child process termination" {
    if (!std.process.can_spawn or @import("builtin").os.tag == .windows) return error.SkipZigTest;

    var scheduler = Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();
    _ = try scheduler.add(
        std.testing.io,
        try Expression.parse("* * * * *"),
        .{ .command = .{ .argv = &.{ "/bin/sh", "-c", "exit 7" } } },
        .{},
    );

    var outcomes: TestOutcomes = .{};
    var group: std.Io.Group = .init;
    defer group.cancel(std.testing.io);
    scheduler.dispatchMinute(std.testing.io, &group, 0, outcomes.observer());
    try group.await(std.testing.io);
    try std.testing.expectEqual(7, outcomes.command_exit.load(.monotonic));
}

test "scheduler cancellation cleans up a running child command" {
    if (!std.process.can_spawn or @import("builtin").os.tag == .windows) return error.SkipZigTest;

    var scheduler = Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();

    var marker_bytes: [12]u8 = undefined;
    std.testing.io.random(&marker_bytes);
    var marker_path_buf: [128]u8 = undefined;
    const marker_path = try std.fmt.bufPrint(
        &marker_path_buf,
        "/tmp/libcron-cancel-{x}.ready",
        .{marker_bytes},
    );
    std.Io.Dir.deleteFileAbsolute(std.testing.io, marker_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, marker_path) catch {};
    var shell_command_buf: [256]u8 = undefined;
    const shell_command = try std.fmt.bufPrint(
        &shell_command_buf,
        "printf ready > {s}; exec /bin/sleep 60",
        .{marker_path},
    );
    const argv = [_][]const u8{ "/bin/sh", "-c", shell_command };
    _ = try scheduler.add(
        std.testing.io,
        try Expression.parse("* * * * *"),
        .{ .command = .{ .argv = &argv } },
        .{},
    );

    var outcomes: TestOutcomes = .{};
    var group: std.Io.Group = .init;
    defer group.cancel(std.testing.io);
    scheduler.dispatchMinute(std.testing.io, &group, 0, outcomes.observer());
    try std.testing.expectEqual(1, scheduler.jobs.items[0].in_flight.load(.acquire));

    var child_started = false;
    for (0..100) |_| {
        if (std.Io.Dir.accessAbsolute(std.testing.io, marker_path, .{})) |_| {
            child_started = true;
            break;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expect(child_started);

    group.cancel(std.testing.io);
    try std.testing.expectEqual(0, scheduler.jobs.items[0].in_flight.load(.acquire));
    try std.testing.expectEqual(-1, outcomes.command_exit.load(.monotonic));
}

test "dispatch errors are reported and the job runs at its next match" {
    var scheduler = Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();
    const every_minute = try Expression.parse("* * * * *");
    for (0..2) |_| _ = try scheduler.add(std.testing.io, every_minute, .{ .callback = .{ .run = successfulTestCallback } }, .{});

    var outcomes: TestOutcomes = .{};
    var group: std.Io.Group = .init;
    defer group.cancel(std.testing.io);
    scheduler.dispatchMinute(std.Io.failing, &group, 0, outcomes.observer());
    try std.testing.expectEqual(2, outcomes.dispatch_error.load(.monotonic));

    scheduler.dispatchMinute(std.testing.io, &group, 1, outcomes.observer());
    try group.await(std.testing.io);
    try std.testing.expectEqual(2, outcomes.callback_success.load(.monotonic));
}

fn gatedTestCallback(context: ?*anyopaque, io: std.Io, _: Invocation) anyerror!void {
    const gate: *std.Io.Event = @ptrCast(@alignCast(context.?));
    try gate.wait(io);
}

test "a removed job's running invocation finishes and the job is freed" {
    const io = std.testing.io;
    var scheduler = Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();
    var gate: std.Io.Event = .unset;
    const id = try scheduler.add(
        io,
        try Expression.parse("* * * * *"),
        .{ .callback = .{ .context = &gate, .run = gatedTestCallback } },
        .{},
    );

    var outcomes: TestOutcomes = .{};
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    scheduler.dispatchMinute(io, &group, 0, outcomes.observer());
    try std.testing.expect(scheduler.remove(io, id));
    try std.testing.expectEqual(1, scheduler.retired.items.len);
    try std.testing.expect(!scheduler.remove(io, id));
    scheduler.dispatchMinute(io, &group, 1, outcomes.observer());
    try std.testing.expectEqual(0, outcomes.skipped_overlap.load(.monotonic));

    gate.set(io);
    try group.await(io);
    try std.testing.expectEqual(1, outcomes.callback_success.load(.monotonic));
    scheduler.dispatchMinute(io, &group, 2, outcomes.observer());
    try std.testing.expectEqual(0, scheduler.retired.items.len);
}

test "paused jobs do not run and do not catch up when unpaused" {
    const io = std.testing.io;
    var clock = try TestClock.init("0,10 4 * * *", .utc);
    defer clock.deinit();
    const id = clock.scheduler.jobs.items[0].id;

    try clock.dispatch(utcMinute(2026, .jan, 1, 3, 59));
    try std.testing.expect(clock.scheduler.pause(io, id));
    try clock.dispatch(utcMinute(2026, .jan, 1, 4, 0));
    try std.testing.expect(clock.scheduler.unpause(io, id));
    try clock.dispatch(utcMinute(2026, .jan, 1, 4, 5));
    try std.testing.expectEqual(0, clock.fired());
    try clock.dispatch(utcMinute(2026, .jan, 1, 4, 10));
    try std.testing.expectEqual(1, clock.fired());

    try std.testing.expect(!clock.scheduler.pause(io, @fromBackingInt(99)));
    try std.testing.expect(!clock.scheduler.unpause(io, @fromBackingInt(99)));
}

const RemovingObserver = struct {
    scheduler: *Scheduler,
    removed: bool = false,

    fn notify(context: ?*anyopaque, invocation: Invocation, _: Outcome) void {
        const self: *RemovingObserver = @ptrCast(@alignCast(context.?));
        self.removed = self.scheduler.remove(std.testing.io, invocation.job_id);
    }
};

test "observers may call back into the scheduler" {
    var scheduler = Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();
    _ = try scheduler.add(
        std.testing.io,
        try Expression.parse("* * * * *"),
        .{ .callback = .{ .run = successfulTestCallback } },
        .{},
    );
    var observer: RemovingObserver = .{ .scheduler = &scheduler };
    var group: std.Io.Group = .init;
    scheduler.dispatchMinute(std.Io.failing, &group, 0, .{ .context = &observer, .notify = RemovingObserver.notify });
    try std.testing.expect(observer.removed);
    try std.testing.expectEqual(0, scheduler.jobs.items.len);
}

test "jobs can be added, paused, unpaused, and removed while run is active" {
    const io = std.testing.io;
    var scheduler = Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();
    var run_future = try std.Io.concurrent(io, Scheduler.run, .{ &scheduler, io, null });
    defer _ = run_future.cancel(io) catch {};

    const id = try scheduler.add(
        io,
        try Expression.parse("@yearly"),
        .{ .command = .{ .argv = &.{"/bin/true"} } },
        .{},
    );
    try std.testing.expect(scheduler.pause(io, id));
    try std.testing.expect(scheduler.unpause(io, id));
    try std.testing.expect(scheduler.remove(io, id));
}

const ConcurrencyProbe = struct {
    gate: std.Io.Event = .unset,
    running: std.atomic.Value(u32) = .init(0),
    peak: std.atomic.Value(u32) = .init(0),

    fn run(context: ?*anyopaque, io: std.Io, _: Invocation) anyerror!void {
        const self: *ConcurrencyProbe = @ptrCast(@alignCast(context.?));
        _ = self.peak.fetchMax(self.running.fetchAdd(1, .monotonic) + 1, .monotonic);
        defer _ = self.running.fetchSub(1, .monotonic);
        try self.gate.wait(io);
    }
};

test "a replaced skip job does not overlap its running invocation" {
    const io = std.testing.io;
    var scheduler = Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();
    var probe: ConcurrencyProbe = .{};
    const every_minute = try Expression.parse("* * * * *");
    const task: Task = .{ .callback = .{ .context = &probe, .run = ConcurrencyProbe.run } };
    const id = try scheduler.add(io, every_minute, task, .{});

    var outcomes: TestOutcomes = .{};
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    scheduler.dispatchMinute(io, &group, 0, outcomes.observer());
    try std.testing.expect(try scheduler.replace(io, id, try Expression.parse("*/2 * * * *"), task, .{}));
    scheduler.dispatchMinute(io, &group, 2, outcomes.observer());
    try std.testing.expectEqual(1, outcomes.skipped_overlap.load(.monotonic));
    probe.gate.set(io);
    try group.await(io);
    try std.testing.expectEqual(1, probe.peak.load(.monotonic));
    try std.testing.expectEqual(id, scheduler.jobs.items[0].id);
    try std.testing.expect(!try scheduler.replace(io, @fromBackingInt(99), every_minute, task, .{}));
}

test "a replaced job keeps its paused state and its DST state" {
    const io = std.testing.io;
    const paris_tz = footerTz("CET-1CEST,M3.5.0,M10.5.0/3");
    var clock = try TestClock.init("30 2 * * *", try TimeZone.fromTz(&paris_tz));
    defer clock.deinit();
    const id = clock.scheduler.jobs.items[0].id;
    const fall = utcMinute(2026, .oct, 25, 1, 0);
    try clock.dispatchRange(fall - 120, fall + 10);
    try std.testing.expectEqual(1, clock.fired());

    // A reload loads the same zone again: a different object, the same rules.
    const reloaded_tz = footerTz("CET-1CEST,M3.5.0,M10.5.0/3");
    const task: Task = .{ .callback = .{ .run = successfulTestCallback } };
    try std.testing.expect(try clock.scheduler.replace(io, id, try Expression.parse("30 2 * * *"), task, .{
        .time_zone = try TimeZone.fromTz(&reloaded_tz),
    }));
    try clock.dispatchRange(fall + 10, fall + 120);
    try std.testing.expectEqual(1, clock.fired());

    try std.testing.expect(clock.scheduler.pause(io, id));
    try std.testing.expect(try clock.scheduler.replace(io, id, try Expression.parse("* * * * *"), task, .{}));
    try clock.dispatch(fall + 121);
    try std.testing.expectEqual(1, clock.fired());
}

test "replacing a job's time zone with one at another local time restarts its wall clock" {
    var clock = try TestClock.init("0 11 * * *", .utc);
    defer clock.deinit();
    try clock.dispatchRange(utcMinute(2026, .jan, 1, 9, 50), utcMinute(2026, .jan, 1, 10, 1));
    try std.testing.expect(try clock.scheduler.replace(
        std.testing.io,
        clock.scheduler.jobs.items[0].id,
        try Expression.parse("0 11 * * *"),
        .{ .callback = .{ .run = successfulTestCallback } },
        .{ .time_zone = try TimeZone.fixedOffset(2 * 3_600) },
    ));
    // 10:01 UTC is 12:01 in the new zone; 11:00 there was never skipped.
    try clock.dispatch(utcMinute(2026, .jan, 1, 10, 1));
    try std.testing.expectEqual(0, clock.fired());
}

test "a job added paused does not run until unpaused" {
    const io = std.testing.io;
    var scheduler = Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();
    const id = try scheduler.add(
        io,
        try Expression.parse("* * * * *"),
        .{ .callback = .{ .run = successfulTestCallback } },
        .{ .paused = true },
    );
    var outcomes: TestOutcomes = .{};
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    scheduler.dispatchMinute(io, &group, 0, outcomes.observer());
    try group.await(io);
    try std.testing.expectEqual(0, outcomes.callback_success.load(.monotonic));
    try std.testing.expect(scheduler.unpause(io, id));
    scheduler.dispatchMinute(io, &group, 1, outcomes.observer());
    try group.await(io);
    try std.testing.expectEqual(1, outcomes.callback_success.load(.monotonic));
}

test "pausing inside a repeated hour does not rerun a fixed-time job" {
    const io = std.testing.io;
    const paris_tz = footerTz("CET-1CEST,M3.5.0,M10.5.0/3");
    var clock = try TestClock.init("30 2 * * *", try TimeZone.fromTz(&paris_tz));
    defer clock.deinit();
    const id = clock.scheduler.jobs.items[0].id;
    const fall = utcMinute(2026, .oct, 25, 1, 0);
    // Through 02:04 in the second pass of 02:00-02:59.
    try clock.dispatchRange(fall - 120, fall + 5);
    try std.testing.expect(clock.scheduler.pause(io, id));
    try clock.dispatch(fall + 5);
    try std.testing.expect(clock.scheduler.unpause(io, id));
    try clock.dispatchRange(fall + 6, fall + 120);
    try std.testing.expectEqual(1, clock.fired());
}
