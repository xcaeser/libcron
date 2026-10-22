//! A job: what it runs, when it is due, and how one invocation executes.

const std = @import("std");
const calendar = @import("calendar.zig");
const command = @import("command.zig");
const Expression = @import("expression.zig").Expression;
const TimeZone = @import("time_zone.zig").TimeZone;
const WallClock = @import("wall_clock.zig").WallClock;

const DateTime = calendar.DateTime;

pub const JobId = enum(u64) { _ };

pub const OverlapPolicy = enum {
    skip,
    concurrent,
};

pub const Invocation = struct {
    job_id: JobId,
    /// The start of the minute the job was dispatched at, in seconds since
    /// the Unix epoch.
    scheduled_unix_seconds: i64,
    /// The wall-clock minute the run is for. After the clock jumps ahead it
    /// can be a skipped minute before `scheduled_unix_seconds`.
    local_time: DateTime,
};

pub const Callback = struct {
    context: ?*anyopaque = null,
    run: *const fn (?*anyopaque, std.Io, Invocation) anyerror!void,
};

pub const Task = union(enum) {
    callback: Callback,
    command: command.Command,
};

pub const JobOptions = struct {
    time_zone: TimeZone = .utc,
    overlap: OverlapPolicy = .skip,
    /// How long a canceled command's process group has between SIGTERM and
    /// SIGKILL.
    termination_grace: std.Io.Duration = .fromSeconds(10),
    /// Whether `Scheduler.add` creates the job paused. `Scheduler.replace`
    /// keeps the job's current state instead.
    paused: bool = false,
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
/// thread-safe. It is never called with the scheduler locked, so it may call
/// `Scheduler` methods.
pub const Observer = struct {
    context: ?*anyopaque = null,
    notify: *const fn (?*anyopaque, Invocation, Outcome) void,

    /// Calls `notify(context, invocation, outcome)` with `context` keeping its
    /// pointer type, as in `.init(&log, Log.record)`.
    pub fn init(context: anytype, comptime notify: anytype) Observer {
        const Context = @TypeOf(context);
        return .{
            .context = @ptrCast(@constCast(context)),
            .notify = struct {
                fn call(erased: ?*anyopaque, invocation: Invocation, outcome: Outcome) void {
                    const typed: Context = @ptrCast(@alignCast(erased));
                    notify(typed, invocation, outcome);
                }
            }.call,
        };
    }
};

pub const Job = struct {
    id: JobId,
    expression: Expression,
    /// Command strings live in `arena`; callback contexts stay the caller's.
    task: Task,
    options: JobOptions,
    arena: std.heap.ArenaAllocator,
    /// Invocations started and not finished. The job's memory is freed only
    /// once this is zero, so a removed job's last invocation completes.
    in_flight: std.atomic.Value(u32) = .init(0),
    paused: bool,
    wall: WallClock = .{},
    /// The instant the job's wall clock was last read, and what it read, so
    /// `Scheduler.replace` can tell whether a new time zone agrees.
    seen: ?struct { unix_seconds: i64, local: DateTime } = null,

    /// Counts a new invocation, or returns false when the overlap policy
    /// skips it because one is still running.
    pub fn claim(self: *Job) bool {
        if (self.options.overlap == .skip)
            return self.in_flight.cmpxchgStrong(0, 1, .acquire, .monotonic) == null;
        _ = self.in_flight.fetchAdd(1, .acquire);
        return true;
    }

    pub fn release(self: *Job) void {
        _ = self.in_flight.fetchSub(1, .release);
    }
};

/// Runs one invocation with the task and grace the job had when it was
/// dispatched, so `Scheduler.replace` may change the job meanwhile.
pub fn execute(
    job: *Job,
    task: Task,
    termination_grace: std.Io.Duration,
    io: std.Io,
    invocation: Invocation,
    observer: ?Observer,
) std.Io.Cancelable!void {
    // The job may be freed once released, so this runs last.
    defer job.release();
    const started = std.Io.Clock.Timestamp.now(io, .boot);

    switch (task) {
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
        .command => |spec| {
            const term = command.run(spec, io, termination_grace) catch |err| {
                if (err == error.Canceled) return error.Canceled;
                report(observer, invocation, .{ .command_error = err });
                return;
            };
            report(observer, invocation, .{ .command_terminated = .{
                .term = term,
                .duration = started.untilNow(io).raw,
            } });
        },
    }
}

pub fn report(observer: ?Observer, invocation: Invocation, outcome: Outcome) void {
    const sink = observer orelse return;
    sink.notify(sink.context, invocation, outcome);
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

test "typed observers receive their own context" {
    const Counter = struct {
        failures: u32 = 0,

        fn record(self: *@This(), _: Invocation, outcome: Outcome) void {
            if (outcome == .callback_error) self.failures += 1;
        }
    };
    var counter: Counter = .{};
    const observer: Observer = .init(&counter, Counter.record);
    const invocation: Invocation = .{
        .job_id = @fromBackingInt(1),
        .scheduled_unix_seconds = 0,
        .local_time = try DateTime.init(2026, .jan, 1, 0, 0),
    };
    observer.notify(observer.context, invocation, .{ .callback_error = .{ .err = error.Failed, .duration = .zero } });
    try std.testing.expectEqual(1, counter.failures);
}
