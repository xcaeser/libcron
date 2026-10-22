//! In-memory job scheduling on wall-clock minutes.

const std = @import("std");
const calendar = @import("calendar.zig");
const Expression = @import("expression.zig").Expression;
const time_zone = @import("time_zone.zig");

const DateTime = calendar.DateTime;
const TimeZone = time_zone.TimeZone;
const TimeZoneError = time_zone.TimeZoneError;

pub const JobId = enum(u64) { _ };

pub const OverlapPolicy = enum {
    skip,
    concurrent,
};

pub const Invocation = struct {
    job_id: JobId,
    scheduled_unix_minute: i64,
    local_time: DateTime,
};

pub const Callback = struct {
    context: ?*anyopaque = null,
    run: *const fn (?*anyopaque, std.Io, Invocation) anyerror!void,
};

pub const Command = struct {
    argv: []const []const u8,
    cwd: std.process.Child.Cwd = .inherit,
    environ_map: ?*const std.process.Environ.Map = null,
};

pub const Task = union(enum) {
    callback: Callback,
    command: Command,
};

pub const JobOptions = struct {
    time_zone: TimeZone = .utc,
    overlap: OverlapPolicy = .skip,
};

/// What happened to one invocation. Durations are elapsed wall-clock time.
pub const Outcome = union(enum) {
    callback_success: std.Io.Duration,
    callback_error: struct { err: anyerror, duration: std.Io.Duration },
    command_terminated: struct { term: std.process.Child.Term, duration: std.Io.Duration },
    /// The command could not be spawned or waited for.
    command_error: anyerror,
    skipped_overlap,
    /// The `Io` could not start the task; the job runs again at its next match.
    dispatch_error: std.Io.ConcurrentError,

    /// Describes the outcome for a log line, as in `exited with code 0 after 1.5s`.
    pub fn format(self: Outcome, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .callback_success => |duration| try writer.print("succeeded after {f}", .{duration}),
            .callback_error => |failure| try writer.print("failed after {f}: {t}", .{ failure.duration, failure.err }),
            .command_terminated => |finished| try writer.print("{f} after {f}", .{ finished.term, finished.duration }),
            .command_error => |err| try writer.print("could not run: {t}", .{err}),
            .skipped_overlap => try writer.writeAll("skipped: the previous run is still active"),
            .dispatch_error => |err| try writer.print("not started: {t}", .{err}),
        }
    }
};

/// Receives results from scheduler and job tasks and therefore must be
/// thread-safe.
pub const Observer = struct {
    context: ?*anyopaque = null,
    notify: *const fn (?*anyopaque, Invocation, Outcome) void,
};

pub const AddError = std.mem.Allocator.Error || error{
    Running,
    InvalidCommand,
    JobIdExhausted,
};

/// Only cancellation ends a running scheduler; job failures go to the observer.
pub const RunError = std.Io.Cancelable || error{
    AlreadyRunning,
};

/// An in-memory, single-owner scheduler configured before `run` starts.
/// `run` must return before another method is called or the scheduler is
/// deinitialized.
pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    jobs: std.ArrayList(Job),
    next_id: u64,
    running: bool,

    pub fn init(allocator: std.mem.Allocator) Scheduler {
        return .{
            .allocator = allocator,
            .jobs = .empty,
            .next_id = 0,
            .running = false,
        };
    }

    pub fn deinit(self: *Scheduler) void {
        std.debug.assert(!self.running);
        self.jobs.deinit(self.allocator);
        self.* = undefined;
    }

    /// Stores a job specification by value. Any pointed-to data remains owned
    /// by the caller and must outlive `run`.
    pub fn add(
        self: *Scheduler,
        expression: Expression,
        task: Task,
        options: JobOptions,
    ) AddError!JobId {
        if (self.running) return error.Running;
        if (task == .command) {
            const command = task.command;
            if (command.argv.len == 0 or command.argv[0].len == 0)
                return error.InvalidCommand;
            for (command.argv) |arg| {
                if (std.mem.indexOfScalar(u8, arg, 0) != null) return error.InvalidCommand;
            }
            switch (command.cwd) {
                .path => |path| if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null)
                    return error.InvalidCommand,
                .inherit, .dir => {},
            }
            if (command.environ_map) |environ_map| {
                for (environ_map.values()) |value| {
                    if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidCommand;
                }
            }
        }
        if (self.next_id == std.math.maxInt(u64)) return error.JobIdExhausted;

        const id: JobId = @fromBackingInt(self.next_id);
        try self.jobs.append(self.allocator, .{
            .id = id,
            .expression = expression,
            .task = task,
            .options = options,
            .active = .init(false),
        });
        self.next_id += 1;
        return id;
    }

    pub fn remove(self: *Scheduler, id: JobId) error{Running}!bool {
        if (self.running) return error.Running;
        for (self.jobs.items, 0..) |job, index| {
            if (job.id == id) {
                _ = self.jobs.swapRemove(index);
                return true;
            }
        }
        return false;
    }

    /// Runs until canceled. The caller-provided `io` must support concurrency.
    pub fn run(self: *Scheduler, io: std.Io, observer: ?Observer) RunError!void {
        if (self.running) return error.AlreadyRunning;
        self.running = true;
        defer self.running = false;

        // Minutes that passed while stopped are not caught up.
        for (self.jobs.items) |*job| job.wall_time = null;

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
        // Only instants outside the years 1 through 65535 fail to convert.
        const unix_seconds = std.math.mul(i64, unix_minute, 60) catch return;
        for (self.jobs.items) |*job| {
            const local_time = job.options.time_zone.toLocal(unix_seconds) catch continue;
            if (!job.due(local_time)) continue;

            const invocation: Invocation = .{
                .job_id = job.id,
                .scheduled_unix_minute = unix_minute,
                .local_time = local_time,
            };
            const tracks_overlap = job.options.overlap == .skip;
            if (tracks_overlap and job.active.swap(true, .acq_rel)) {
                report(observer, invocation, .skipped_overlap);
                continue;
            }

            group.concurrent(io, executeJob, .{ job, io, invocation, observer }) catch |err| {
                if (tracks_overlap) job.active.store(false, .release);
                report(observer, invocation, .{ .dispatch_error = err });
            };
        }
    }
};

const Job = struct {
    id: JobId,
    expression: Expression,
    task: Task,
    options: JobOptions,
    active: std.atomic.Value(bool),
    /// The latest wall-clock minute dispatched. It does not move back while
    /// the wall clock repeats after a DST change.
    wall_time: ?DateTime = null,

    /// Applies cronie's rules for wall-clock steps. When the wall clock
    /// repeats, only jobs with a `*` minute or hour run again. When it jumps
    /// ahead by less than three hours (spring-forward, late wake), a
    /// fixed-time job that matched any skipped minute runs once. Larger steps
    /// either way are taken as the new time without catching up.
    fn due(self: *Job, local: DateTime) bool {
        const expression = self.expression;
        const matches = expression.matches(local) catch unreachable;
        const previous = self.wall_time orelse {
            self.wall_time = local;
            return matches;
        };
        const step = calendar.epochMinute(local) - calendar.epochMinute(previous);
        const wildcard = expression.minute_star or expression.hour_star;
        if (step <= 0 and step > -max_catch_up_minutes) return wildcard and matches;

        self.wall_time = local;
        if (step == 1 or wildcard or @abs(step) >= max_catch_up_minutes) return matches;
        const skipped = (expression.next(previous) catch unreachable) orelse return false;
        return calendar.epochMinute(skipped) <= calendar.epochMinute(local);
    }
};

const max_catch_up_minutes = 3 * 60;

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

fn executeJob(
    job: *Job,
    io: std.Io,
    invocation: Invocation,
    observer: ?Observer,
) std.Io.Cancelable!void {
    defer if (job.options.overlap == .skip) job.active.store(false, .release);
    const started = std.Io.Clock.Timestamp.now(io, .boot);

    switch (job.task) {
        .callback => |callback| {
            callback.run(callback.context, io, invocation) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                report(observer, invocation, .{ .callback_error = .{
                    .err = err,
                    .duration = started.untilNow(io).raw,
                } });
                return;
            };
            report(observer, invocation, .{ .callback_success = started.untilNow(io).raw });
        },
        .command => |command| {
            const previous_cancel_protection = io.swapCancelProtection(.blocked);
            const child_result = std.process.spawn(io, .{
                .argv = command.argv,
                .cwd = command.cwd,
                .environ_map = command.environ_map,
                .stdin = .ignore,
                .stdout = .inherit,
                .stderr = .inherit,
            });
            _ = io.swapCancelProtection(previous_cancel_protection);

            var child = child_result catch |err| {
                if (err == error.Canceled) return error.Canceled;
                report(observer, invocation, .{ .command_error = err });
                return;
            };
            var kill_child = child;
            defer kill_child.kill(io);

            try io.checkCancel();

            const term = child.wait(io) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                report(observer, invocation, .{ .command_error = err });
                return;
            };
            kill_child.id = null;
            report(observer, invocation, .{ .command_terminated = .{
                .term = term,
                .duration = started.untilNow(io).raw,
            } });
        },
    }
}

fn report(observer: ?Observer, invocation: Invocation, outcome: Outcome) void {
    const sink = observer orelse return;
    sink.notify(sink.context, invocation, outcome);
}

const TestOutcomes = struct {
    callback_success: std.atomic.Value(u32) = .init(0),
    callback_error: std.atomic.Value(u32) = .init(0),
    skipped_overlap: std.atomic.Value(u32) = .init(0),
    command_exit: std.atomic.Value(i32) = .init(-1),
    dispatch_error: std.atomic.Value(u32) = .init(0),
    last_success_minute: std.atomic.Value(i64) = .init(0),

    fn notify(context: ?*anyopaque, invocation: Invocation, outcome: Outcome) void {
        const self: *TestOutcomes = @ptrCast(@alignCast(context.?));
        switch (outcome) {
            .callback_success => {
                _ = self.callback_success.fetchAdd(1, .monotonic);
                self.last_success_minute.store(invocation.scheduled_unix_minute, .monotonic);
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
            try std.testing.expectEqual(transition.expected, daily.outcomes.last_success_minute.load(.monotonic));

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
        scheduler.add(every_minute, .{ .command = .{ .argv = &.{} } }, .{}),
    );
    try std.testing.expectError(
        error.InvalidCommand,
        scheduler.add(every_minute, .{ .command = .{ .argv = &.{ "echo", "bad\x00argument" } } }, .{}),
    );
    try std.testing.expectError(
        error.InvalidCommand,
        scheduler.add(every_minute, .{ .command = .{ .argv = &.{"echo"}, .cwd = .{ .path = "" } } }, .{}),
    );
    try std.testing.expectError(
        error.InvalidCommand,
        scheduler.add(every_minute, .{ .command = .{ .argv = &.{"echo"}, .cwd = .{ .path = "bad\x00path" } } }, .{}),
    );
    var invalid_environ = std.process.Environ.Map.init(std.testing.allocator);
    defer invalid_environ.deinit();
    try invalid_environ.put("KEY", "bad\x00value");
    try std.testing.expectError(
        error.InvalidCommand,
        scheduler.add(every_minute, .{ .command = .{ .argv = &.{"echo"}, .environ_map = &invalid_environ } }, .{}),
    );
    const success_id = try scheduler.add(
        every_minute,
        .{ .callback = .{ .run = successfulTestCallback } },
        .{},
    );
    const failure_id = try scheduler.add(
        every_minute,
        .{ .callback = .{ .run = failingTestCallback } },
        .{},
    );
    try std.testing.expect(@backingInt(failure_id) > @backingInt(success_id));

    scheduler.running = true;
    try std.testing.expectError(error.Running, scheduler.remove(success_id));
    try std.testing.expectError(
        error.Running,
        scheduler.add(every_minute, .{ .callback = .{ .run = successfulTestCallback } }, .{}),
    );
    scheduler.running = false;

    var outcomes: TestOutcomes = .{};
    var group: std.Io.Group = .init;
    defer group.cancel(std.testing.io);
    scheduler.dispatchMinute(std.testing.io, &group, 0, outcomes.observer());
    try group.await(std.testing.io);
    try std.testing.expectEqual(1, outcomes.callback_success.load(.monotonic));
    try std.testing.expectEqual(1, outcomes.callback_error.load(.monotonic));

    try std.testing.expect(try scheduler.remove(success_id));
    try std.testing.expect(!(try scheduler.remove(success_id)));
}

test "scheduler applies overlap policies and cancellation cleanup" {
    const every_minute = try Expression.parse("* * * * *");

    var skipped = Scheduler.init(std.testing.allocator);
    defer skipped.deinit();
    _ = try skipped.add(
        every_minute,
        .{ .callback = .{ .run = successfulTestCallback } },
        .{ .overlap = .skip },
    );
    var skipped_outcomes: TestOutcomes = .{};
    var skipped_group: std.Io.Group = .init;
    defer skipped_group.cancel(std.testing.io);
    skipped.dispatchMinute(std.testing.io, &skipped_group, 0, skipped_outcomes.observer());
    skipped.dispatchMinute(std.testing.io, &skipped_group, 1, skipped_outcomes.observer());
    try skipped_group.await(std.testing.io);
    try std.testing.expectEqual(1, skipped_outcomes.callback_success.load(.monotonic));
    try std.testing.expectEqual(1, skipped_outcomes.skipped_overlap.load(.monotonic));

    var concurrent = Scheduler.init(std.testing.allocator);
    defer concurrent.deinit();
    _ = try concurrent.add(
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
        every_minute,
        .{ .callback = .{ .run = blockingTestCallback } },
        .{},
    );
    var canceled_group: std.Io.Group = .init;
    canceled.dispatchMinute(std.testing.io, &canceled_group, 0, null);
    try std.testing.expect(canceled.jobs.items[0].active.load(.acquire));
    canceled_group.cancel(std.testing.io);
    try std.testing.expect(!canceled.jobs.items[0].active.load(.acquire));

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
        try Expression.parse("* * * * *"),
        .{ .command = .{ .argv = &argv } },
        .{},
    );

    var outcomes: TestOutcomes = .{};
    var group: std.Io.Group = .init;
    defer group.cancel(std.testing.io);
    scheduler.dispatchMinute(std.testing.io, &group, 0, outcomes.observer());
    try std.testing.expect(scheduler.jobs.items[0].active.load(.acquire));

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
    try std.testing.expect(!scheduler.jobs.items[0].active.load(.acquire));
    try std.testing.expectEqual(-1, outcomes.command_exit.load(.monotonic));
}

test "dispatch errors are reported and the job runs at its next match" {
    var scheduler = Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();
    const every_minute = try Expression.parse("* * * * *");
    for (0..2) |_| _ = try scheduler.add(every_minute, .{ .callback = .{ .run = successfulTestCallback } }, .{});

    var outcomes: TestOutcomes = .{};
    var group: std.Io.Group = .init;
    defer group.cancel(std.testing.io);
    scheduler.dispatchMinute(std.Io.failing, &group, 0, outcomes.observer());
    try std.testing.expectEqual(2, outcomes.dispatch_error.load(.monotonic));

    scheduler.dispatchMinute(std.testing.io, &group, 1, outcomes.observer());
    try group.await(std.testing.io);
    try std.testing.expectEqual(2, outcomes.callback_success.load(.monotonic));
}

test "outcomes describe themselves for log lines" {
    const cases = [_]struct { outcome: Outcome, text: []const u8 }{
        .{ .outcome = .{ .callback_success = .fromMilliseconds(1_500) }, .text = "succeeded after 1.5s" },
        .{
            .outcome = .{ .callback_error = .{ .err = error.Timeout, .duration = .fromSeconds(2) } },
            .text = "failed after 2s: Timeout",
        },
        .{
            .outcome = .{ .command_terminated = .{ .term = .{ .exited = 7 }, .duration = .fromSeconds(90) } },
            .text = "exited with code 7 after 1m30s",
        },
        .{ .outcome = .{ .command_error = error.FileNotFound }, .text = "could not run: FileNotFound" },
        .{ .outcome = .skipped_overlap, .text = "skipped: the previous run is still active" },
        .{ .outcome = .{ .dispatch_error = error.ConcurrencyUnavailable }, .text = "not started: ConcurrencyUnavailable" },
    };
    for (cases) |case| {
        var buffer: [128]u8 = undefined;
        try std.testing.expectEqualStrings(case.text, try std.fmt.bufPrint(&buffer, "{f}", .{case.outcome}));
    }
}
