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

pub const Outcome = union(enum) {
    callback_success,
    callback_error: anyerror,
    command_terminated: std.process.Child.Term,
    command_error: anyerror,
    skipped_overlap,
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

pub const RunError = std.Io.Cancelable || std.Io.ConcurrentError || TimeZoneError || error{
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

        var jobs: std.Io.Group = .init;
        defer jobs.cancel(io);

        const minute_ns: i96 = std.time.ns_per_min;
        while (true) {
            const now = std.Io.Clock.real.now(io);
            const deadline_ns = (@divFloor(now.nanoseconds, minute_ns) + 1) * minute_ns;
            const deadline: std.Io.Clock.Timestamp = .{
                .raw = .{ .nanoseconds = deadline_ns },
                .clock = .real,
            };
            try deadline.wait(io);

            const current = std.Io.Clock.real.now(io);
            const unix_minute = std.math.cast(i64, @divFloor(current.nanoseconds, minute_ns)) orelse
                return error.DateOutOfRange;
            try self.dispatchMinute(io, &jobs, unix_minute, observer);
        }
    }

    fn dispatchMinute(
        self: *Scheduler,
        io: std.Io,
        group: *std.Io.Group,
        unix_minute: i64,
        observer: ?Observer,
    ) RunError!void {
        const unix_seconds = std.math.mul(i64, unix_minute, 60) catch return error.DateOutOfRange;
        for (self.jobs.items) |*job| {
            const local_time = try job.options.time_zone.toLocal(unix_seconds);
            if (!(job.expression.matches(local_time) catch unreachable)) continue;

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
                return err;
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
};

fn executeJob(
    job: *Job,
    io: std.Io,
    invocation: Invocation,
    observer: ?Observer,
) std.Io.Cancelable!void {
    defer if (job.options.overlap == .skip) job.active.store(false, .release);

    switch (job.task) {
        .callback => |callback| {
            callback.run(callback.context, io, invocation) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                report(observer, invocation, .{ .callback_error = err });
                return;
            };
            report(observer, invocation, .callback_success);
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
            report(observer, invocation, .{ .command_terminated = term });
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

    fn notify(context: ?*anyopaque, invocation: Invocation, outcome: Outcome) void {
        _ = invocation;
        const self: *TestOutcomes = @ptrCast(@alignCast(context.?));
        switch (outcome) {
            .callback_success => _ = self.callback_success.fetchAdd(1, .monotonic),
            .callback_error => _ = self.callback_error.fetchAdd(1, .monotonic),
            .skipped_overlap => _ = self.skipped_overlap.fetchAdd(1, .monotonic),
            .command_terminated => |term| switch (term) {
                .exited => |code| self.command_exit.store(code, .monotonic),
                else => self.command_exit.store(-2, .monotonic),
            },
            .command_error => self.command_exit.store(-3, .monotonic),
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
    try scheduler.dispatchMinute(std.testing.io, &group, 0, outcomes.observer());
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
    try skipped.dispatchMinute(std.testing.io, &skipped_group, 0, skipped_outcomes.observer());
    try skipped.dispatchMinute(std.testing.io, &skipped_group, 1, skipped_outcomes.observer());
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
    try concurrent.dispatchMinute(std.testing.io, &concurrent_group, 0, concurrent_outcomes.observer());
    try concurrent.dispatchMinute(std.testing.io, &concurrent_group, 1, concurrent_outcomes.observer());
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
    try canceled.dispatchMinute(std.testing.io, &canceled_group, 0, null);
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
    try scheduler.dispatchMinute(std.testing.io, &group, 0, outcomes.observer());
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
    try scheduler.dispatchMinute(std.testing.io, &group, 0, outcomes.observer());
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
