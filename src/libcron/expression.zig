//! Cron expressions matched against calendar minutes.

const std = @import("std");
const calendar = @import("calendar.zig");
const grammar = @import("parse.zig");
const time_zone = @import("time_zone.zig");
const wall_clock = @import("wall_clock.zig");

const DateTime = calendar.DateTime;
const DateTimeError = calendar.DateTimeError;

/// A parsed five-field cron expression.
pub const Expression = struct {
    minutes: u64,
    hours: u32,
    days_of_month: u32,
    months: u16,
    days_of_week: u8,
    /// Whether each field was written starting with `*`, as in `*` or `*/n`.
    /// The minute and hour flags decide how jobs behave across DST changes.
    minute_star: bool,
    hour_star: bool,
    day_of_month_star: bool,
    day_of_week_star: bool,

    /// Parses `minute hour day-of-month month day-of-week` or a macro such
    /// as `@daily`; the grammar is described in `parse.zig`.
    pub fn parse(source: []const u8) grammar.ParseError!Expression {
        var diagnostics: grammar.Diagnostics = .{};
        return grammar.parse(source, &diagnostics);
    }

    /// Like `parse`, and on failure fills `diagnostics` with the failing
    /// field and a short explanation.
    pub fn parseWithDiagnostics(source: []const u8, diagnostics: *grammar.Diagnostics) grammar.ParseError!Expression {
        return grammar.parse(source, diagnostics);
    }

    /// Returns whether `date_time` matches this expression.
    pub fn matches(self: Expression, date_time: DateTime) DateTimeError!bool {
        try date_time.validate();
        return self.matchesUnchecked(date_time);
    }

    fn matchesUnchecked(self: Expression, date_time: DateTime) bool {
        return has(self.minutes, date_time.minute, 0) and
            has(self.hours, date_time.hour, 0) and
            has(self.months, date_time.month.numeric(), 1) and
            self.dayMatches(date_time);
    }

    /// Returns the first matching calendar minute strictly after `after`.
    /// `null` means no matching minute exists in a Gregorian 400-year cycle or
    /// before the maximum representable year.
    pub fn next(self: Expression, after: DateTime) DateTimeError!?DateTime {
        try after.validate();
        var date_time = calendar.nextMinute(after) orelse return null;

        var days_checked: u32 = 0;
        while (days_checked < calendar.days_per_gregorian_cycle) : (days_checked += 1) {
            const first_day = days_checked == 0;
            if (has(self.months, date_time.month.numeric(), 1) and self.dayMatches(date_time)) {
                var hour: u8 = if (first_day) date_time.hour else 0;
                while (hour < 24) : (hour += 1) {
                    if (!has(self.hours, hour, 0)) continue;

                    var minute: u8 = if (first_day and hour == date_time.hour) date_time.minute else 0;
                    while (minute < 60) : (minute += 1) {
                        if (has(self.minutes, minute, 0)) {
                            return .{
                                .year = date_time.year,
                                .month = date_time.month,
                                .day = date_time.day,
                                .hour = hour,
                                .minute = minute,
                            };
                        }
                    }
                }
            }

            date_time = calendar.nextDay(date_time) orelse return null;
        }
        return null;
    }

    /// The first instant after `after_unix_seconds` at which a scheduler
    /// running all along fires this expression in `zone`, following the same
    /// DST rules: a fixed time skipped by spring-forward runs at the first
    /// minute after the gap, and a repeated hour runs only jobs whose minute
    /// or hour is `*`. `null` when that instant is past the year 65535.
    pub fn nextInstant(self: Expression, after_unix_seconds: i64, zone: time_zone.TimeZone) ?i64 {
        return wall_clock.nextInstant(self, after_unix_seconds, zone) catch null;
    }

    fn dayMatches(self: Expression, date_time: DateTime) bool {
        const day_of_month = has(self.days_of_month, date_time.day, 1);
        const day_of_week = has(self.days_of_week, calendar.weekday(date_time), 0);
        return if (self.day_of_month_star or self.day_of_week_star)
            day_of_month and day_of_week
        else
            day_of_month or day_of_week;
    }
};

fn has(mask: anytype, value: anytype, minimum: u8) bool {
    return mask & (@as(@TypeOf(mask), 1) << @intCast(value - minimum)) != 0;
}

test "day fields use cron wildcard and OR semantics" {
    const either_day = try Expression.parse("30 4 1,15 * 5");
    try std.testing.expect(try either_day.matches(try DateTime.init(2026, .jan, 1, 4, 30)));
    try std.testing.expect(try either_day.matches(try DateTime.init(2026, .jan, 2, 4, 30)));
    try std.testing.expect(!try either_day.matches(try DateTime.init(2026, .jan, 3, 4, 30)));

    const stepped_star = try Expression.parse("0 0 */2 * 1");
    try std.testing.expect(try stepped_star.matches(try DateTime.init(2026, .jan, 5, 0, 0)));
    try std.testing.expect(!try stepped_star.matches(try DateTime.init(2026, .jan, 12, 0, 0)));
    try std.testing.expect(!try stepped_star.matches(try DateTime.init(2026, .jan, 13, 0, 0)));
}

test "next is exclusive and crosses calendar boundaries" {
    const weekdays = try Expression.parse("*/15 9-17 * * 1-5");
    try std.testing.expectEqual(
        try DateTime.init(2026, .aug, 31, 9, 15),
        (try weekdays.next(try DateTime.init(2026, .aug, 31, 9, 0))).?,
    );
    try std.testing.expectEqual(
        try DateTime.init(2026, .sep, 7, 9, 0),
        (try weekdays.next(try DateTime.init(2026, .sep, 4, 17, 59))).?,
    );

    const leap_day = try Expression.parse("0 0 29 2 *");
    try std.testing.expectEqual(
        try DateTime.init(2024, .feb, 29, 0, 0),
        (try leap_day.next(try DateTime.init(2023, .mar, 1, 0, 0))).?,
    );
}

test "invalid dates and the end of the calendar are reported" {
    const daily = try Expression.parse("0 0 * * *");
    const invalid: DateTime = .{ .year = 2026, .month = .feb, .day = 30, .hour = 0, .minute = 0 };
    try std.testing.expectError(error.InvalidDateTime, daily.matches(invalid));
    try std.testing.expectError(error.InvalidDateTime, daily.next(invalid));

    try std.testing.expectEqual(null, try daily.next(try DateTime.init(std.math.maxInt(u16), .dec, 31, 23, 59)));
}

fn scanNext(expression: Expression, after: DateTime) ?DateTime {
    var candidate = after;
    // Nine years covers the longest gap of every expression tested below.
    for (0..9 * 366 * 1_440) |_| {
        candidate = calendar.nextMinute(candidate) orelse return null;
        if (expression.matchesUnchecked(candidate)) return candidate;
    }
    return null;
}

test "next agrees with a minute-by-minute scan" {
    const sources = [_][]const u8{
        "59 23 31 12 *",
        "0 0 29 2 *",
        "0 0 31 * *",
        "*/7 */5 */3 */2 */2",
        "30 4 1,15 * 5",
        "0 0 1 * 1",
        "0 0 */2 * 1",
        "*/59 */23 */30 */11 */6",
        "0 12 29 2 1",
        "* * * * *",
        "0 0 30 1-12/2 *",
        "15 3 28-31 2 *",
        "0 0 * 2 0-6/6",
        "0 0 1 1 *",
        "59 23 * * 6",
    };
    const starts = [_]DateTime{
        try DateTime.init(2023, .dec, 31, 23, 59),
        try DateTime.init(2024, .feb, 28, 23, 59),
        try DateTime.init(2024, .feb, 29, 0, 0),
        try DateTime.init(2024, .dec, 31, 23, 59),
        try DateTime.init(2025, .jun, 15, 12, 34),
        try DateTime.init(2099, .dec, 31, 23, 59),
        try DateTime.init(2100, .feb, 28, 23, 59),
        try DateTime.init(2399, .dec, 31, 23, 59),
    };
    for (sources) |source| {
        const expression = try Expression.parse(source);
        for (starts) |start| {
            const expected = scanNext(expression, start) orelse return error.TestScanTooShort;
            std.testing.expectEqual(expected, (try expression.next(start)).?) catch |err| {
                std.debug.print("{s} after {any}\n", .{ source, start });
                return err;
            };
        }
    }
}
