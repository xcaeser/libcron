//! Five-field cron expression parsing, evaluation, and scheduling.
//!
//! `Expression` is allocation-free. `Scheduler` stores in-memory jobs and uses
//! a caller-provided `std.Io` for sleeping, concurrency, and child processes.

const calendar = @import("libcron/calendar.zig");
const command = @import("libcron/command.zig");
const expression = @import("libcron/expression.zig");
const grammar = @import("libcron/parse.zig");
const time_zone = @import("libcron/time_zone.zig");
const job = @import("libcron/job.zig");
const scheduler = @import("libcron/scheduler.zig");
const wall_clock = @import("libcron/wall_clock.zig");

pub const Month = calendar.Month;
pub const DateTime = calendar.DateTime;
pub const DateTimeError = calendar.DateTimeError;

pub const ParseError = grammar.ParseError;
pub const Diagnostics = grammar.Diagnostics;
pub const Expression = expression.Expression;

pub const TimeZone = time_zone.TimeZone;
pub const TimeZoneError = time_zone.TimeZoneError;

pub const JobId = job.JobId;
pub const OverlapPolicy = job.OverlapPolicy;
pub const Invocation = job.Invocation;
pub const Callback = job.Callback;
pub const Command = command.Command;
pub const Task = job.Task;
pub const JobOptions = job.JobOptions;
pub const Outcome = job.Outcome;
pub const Observer = job.Observer;
pub const AddError = scheduler.AddError;
pub const RunError = scheduler.RunError;
pub const Scheduler = scheduler.Scheduler;

test {
    _ = calendar;
    _ = command;
    _ = expression;
    _ = grammar;
    _ = time_zone;
    _ = job;
    _ = scheduler;
    _ = wall_clock;
}
