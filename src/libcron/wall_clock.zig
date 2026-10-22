//! How cron follows a wall clock that jumps: DST changes, late wakes, and
//! clock steps, following cronie.

const std = @import("std");
const calendar = @import("calendar.zig");
const Expression = @import("expression.zig").Expression;
const time_zone = @import("time_zone.zig");

const DateTime = calendar.DateTime;
const TimeZone = time_zone.TimeZone;

/// Wall-clock steps of more than this many minutes, either way, are taken as
/// the new time without catching up or holding back.
pub const max_catch_up_minutes = 3 * 60;

/// One job's view of its wall clock between dispatched minutes. The rules
/// are spelled out on `Scheduler`.
pub const WallClock = struct {
    /// The latest wall-clock minute seen. It does not move back while the
    /// wall clock repeats.
    high: ?DateTime = null,

    /// Records that the wall clock reads `local` and returns the wall-clock
    /// minutes `expression` fires for now.
    pub fn advance(self: *WallClock, expression: Expression, local: DateTime) Fires {
        const only_local: Fires = .{ .expression = expression, .after = null, .until = local };
        const previous = self.high orelse {
            self.high = local;
            return only_local;
        };
        const step = calendar.epochMinute(local) - calendar.epochMinute(previous);
        const wildcard = expression.minute_star or expression.hour_star;
        if (step <= 0 and step >= -max_catch_up_minutes) return if (wildcard) only_local else .none;

        self.high = local;
        if (step == 1 or wildcard or step > max_catch_up_minutes or step < -max_catch_up_minutes) return only_local;
        return .{ .expression = expression, .after = previous, .until = local };
    }
};

/// Matching wall-clock minutes up to `until`, oldest first.
pub const Fires = struct {
    expression: Expression,
    /// Matches after this minute are left; `null` when only `until` is.
    after: ?DateTime,
    until: DateTime,
    done: bool = false,

    pub const none: Fires = .{ .expression = undefined, .after = null, .until = undefined, .done = true };

    pub fn next(self: *Fires) ?DateTime {
        if (self.done) return null;
        const after = self.after orelse {
            self.done = true;
            return if (self.expression.matches(self.until) catch unreachable) self.until else null;
        };
        const found = (self.expression.next(after) catch unreachable) orelse {
            self.done = true;
            return null;
        };
        if (calendar.epochMinute(found) > calendar.epochMinute(self.until)) {
            self.done = true;
            return null;
        }
        self.after = found;
        return found;
    }
};

/// The first instant after `after_unix_seconds` at which a scheduler that has
/// been running all along fires `expression` in `zone`.
pub fn nextInstant(expression: Expression, after_unix_seconds: i64, zone: TimeZone) TimeZoneError!?i64 {
    const after_minute = @divFloor(after_unix_seconds, 60);
    // Replaying the preceding three hours rebuilds the high-water mark that a
    // repeated wall-clock hour leaves behind.
    var minute = after_minute - max_catch_up_minutes;
    var clock: WallClock = .{ .high = try zone.toLocal(minute * 60) };
    while (true) {
        const first = minute + 1;
        const local = try zone.toLocal(first * 60);
        // The wall clock may have jumped since `minute`.
        var fires = clock.advance(expression, local);
        if (fires.next() != null and first > after_minute) return first * 60;
        const high = clock.high.?;

        // Until the next transition, the wall clock advances a minute a minute.
        const end: ?i64 = if (try zone.nextTransition(first * 60)) |at| std.math.divCeil(i64, at, 60) catch unreachable else null;
        const wildcard = expression.minute_star or expression.hour_star;
        const from = if (wildcard or calendar.epochMinute(local) >= calendar.epochMinute(high)) local else high;
        const candidate = (expression.next(from) catch unreachable) orelse return null;
        const fire = first + calendar.epochMinute(candidate) - calendar.epochMinute(local);
        if (end == null or fire < end.?) {
            if (fire > after_minute) return fire * 60;
            minute = fire;
            if (calendar.epochMinute(candidate) > calendar.epochMinute(high)) clock.high = candidate;
            continue;
        }
        minute = end.? - 1;
        const last = try zone.toLocal(minute * 60);
        if (calendar.epochMinute(last) > calendar.epochMinute(high)) clock.high = last;
    }
}

const TimeZoneError = time_zone.TimeZoneError;

fn footerTz(footer: []const u8) std.Tz {
    return .{
        .allocator = std.testing.allocator,
        .transitions = &.{},
        .timetypes = &.{.{ .offset = 0, .flags = 0, .name_data = .{ 'S', 'T', 'D', 0, 0, 0 } }},
        .leapseconds = &.{},
        .footer = footer,
    };
}

fn utcMinute(year: u16, month: calendar.Month, day: u8, hour: u8, minute: u8) i64 {
    return calendar.epochMinute(.{ .year = year, .month = month, .day = day, .hour = hour, .minute = minute });
}

test "nextInstant agrees with a minute-by-minute replay of the wall-clock rules" {
    const zones = [_]struct { footer: []const u8, transitions: [2]i64 }{
        .{ .footer = "CET-1CEST,M3.5.0,M10.5.0/3", .transitions = .{ utcMinute(2026, .mar, 29, 1, 0), utcMinute(2026, .oct, 25, 1, 0) } },
        .{ .footer = "EST5EDT,M3.2.0,M11.1.0", .transitions = .{ utcMinute(2026, .mar, 8, 7, 0), utcMinute(2026, .nov, 1, 6, 0) } },
        .{ .footer = "AEST-10AEDT,M10.1.0,M4.1.0/3", .transitions = .{ utcMinute(2026, .oct, 3, 16, 0), utcMinute(2026, .apr, 4, 16, 0) } },
        .{ .footer = "<+1030>-10:30<+11>-11,M10.1.0,M4.1.0", .transitions = .{ utcMinute(2026, .oct, 3, 15, 30), utcMinute(2026, .apr, 4, 15, 0) } },
        .{ .footer = "IST-1GMT0,M10.5.0,M3.5.0/1", .transitions = .{ utcMinute(2026, .mar, 29, 1, 0), utcMinute(2026, .oct, 25, 1, 0) } },
    };
    const sources = [_][]const u8{
        "30 2 * * *", "30 1 * * *", "45 1 * * *", "*/15 * * * *", "0 * * * *", "* 2 * * *", "0 3 * * 0",
    };
    for (zones) |case| {
        const tz = footerTz(case.footer);
        const zone = try TimeZone.fromTz(&tz);
        for (case.transitions) |transition| {
            for (sources) |source| {
                errdefer std.debug.print("{s} {s} near minute {d}\n", .{ case.footer, source, transition });
                const expression = try Expression.parse(source);

                // Every minute the scheduler would fire, replayed from two
                // days before the transition to nine days after.
                const replay_first = transition - 2 * 1_440;
                var fires: std.ArrayList(i64) = .empty;
                defer fires.deinit(std.testing.allocator);
                var clock: WallClock = .{};
                var minute = replay_first;
                while (minute < transition + 9 * 1_440) : (minute += 1) {
                    var due = clock.advance(expression, try zone.toLocal(minute * 60));
                    if (due.next() != null) try fires.append(std.testing.allocator, minute);
                }

                var start = (transition - 1_440) * 60 + 17;
                while (start < (transition + 1_440) * 60) : (start += 7 * 60 + 13) {
                    const expected = for (fires.items) |fire| {
                        if (fire * 60 > start) break fire * 60;
                    } else unreachable;
                    try std.testing.expectEqual(expected, try nextInstant(expression, start, zone));
                }
            }
        }
    }
}

test "nextInstant in fixed zones is the next matching minute" {
    const daily = try Expression.parse("30 9 * * *");
    const zone = try TimeZone.fixedOffset(-5 * 3_600);
    const after = utcMinute(2026, .jan, 1, 14, 30) * 60;
    try std.testing.expectEqual(after + 1_440 * 60, try nextInstant(daily, after, zone));
    try std.testing.expectEqual(after, try nextInstant(daily, after - 1, zone));
    try std.testing.expectEqual(after, try nextInstant(daily, after - 1_440 * 60 + 59, zone));
}
