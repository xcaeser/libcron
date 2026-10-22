//! Five-field cron expression parsing and calendar matching.

const std = @import("std");
const calendar = @import("calendar.zig");

const DateTime = calendar.DateTime;
const DateTimeError = calendar.DateTimeError;

pub const ParseError = error{
    InvalidFieldCount,
    InvalidSyntax,
    ValueOutOfRange,
    InvalidRange,
    InvalidStep,
};

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

    /// Parses `minute hour day-of-month month day-of-week`.
    pub fn parse(source: []const u8) ParseError!Expression {
        var fields: [5][]const u8 = undefined;
        var tokens = std.mem.tokenizeAny(u8, source, " \t");
        for (&fields) |*field| field.* = tokens.next() orelse return error.InvalidFieldCount;
        if (tokens.next() != null) return error.InvalidFieldCount;

        const minutes = try parseField(fields[0], 0, 59);
        const hours = try parseField(fields[1], 0, 23);
        const days_of_month = try parseField(fields[2], 1, 31);
        const months = try parseField(fields[3], 1, 12);
        const days_of_week = try parseField(fields[4], 0, 6);

        return .{
            .minutes = @intCast(minutes.mask),
            .hours = @intCast(hours.mask),
            .days_of_month = @intCast(days_of_month.mask),
            .months = @intCast(months.mask),
            .days_of_week = @intCast(days_of_week.mask),
            .minute_star = minutes.star,
            .hour_star = hours.star,
            .day_of_month_star = days_of_month.star,
            .day_of_week_star = days_of_week.star,
        };
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

    fn dayMatches(self: Expression, date_time: DateTime) bool {
        const day_of_month = has(self.days_of_month, date_time.day, 1);
        const day_of_week = has(self.days_of_week, calendar.weekday(date_time), 0);
        return if (self.day_of_month_star or self.day_of_week_star)
            day_of_month and day_of_week
        else
            day_of_month or day_of_week;
    }
};

const ParsedField = struct {
    mask: u64,
    star: bool,
};

fn parseField(source: []const u8, minimum: u8, maximum: u8) ParseError!ParsedField {
    if (source.len == 0) return error.InvalidSyntax;

    if (source[0] == '*') {
        if (source.len == 1) return .{ .mask = fullMask(minimum, maximum), .star = true };
        if (source.len < 3 or source[1] != '/' or std.mem.indexOfScalar(u8, source[2..], '/') != null)
            return error.InvalidSyntax;

        const step = try parseStep(source[2..]);
        return .{ .mask = steppedMask(minimum, maximum, step), .star = true };
    }

    var mask: u64 = 0;
    var parts = std.mem.splitScalar(u8, source, ',');
    while (parts.next()) |part| {
        if (part.len == 0) return error.InvalidSyntax;

        const slash = std.mem.indexOfScalar(u8, part, '/');
        const base = if (slash) |index| part[0..index] else part;
        const step = if (slash) |index| blk: {
            if (std.mem.indexOfScalar(u8, part[index + 1 ..], '/') != null) return error.InvalidSyntax;
            break :blk try parseStep(part[index + 1 ..]);
        } else 1;

        if (std.mem.indexOfScalar(u8, base, '-')) |dash| {
            if (std.mem.indexOfScalar(u8, base[dash + 1 ..], '-') != null) return error.InvalidSyntax;
            const start = try parseValue(base[0..dash], minimum, maximum);
            const end = try parseValue(base[dash + 1 ..], minimum, maximum);
            if (start > end) return error.InvalidRange;
            mask |= steppedMask(start, end, step) << @intCast(start - minimum);
        } else {
            if (slash != null) return error.InvalidSyntax;
            const value = try parseValue(base, minimum, maximum);
            mask |= @as(u64, 1) << @intCast(value - minimum);
        }
    }

    return .{ .mask = mask, .star = false };
}

fn parseValue(source: []const u8, minimum: u8, maximum: u8) ParseError!u8 {
    for (source) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidSyntax;
    const value = std.fmt.parseUnsigned(u16, source, 10) catch |err| switch (err) {
        error.InvalidCharacter => return error.InvalidSyntax,
        error.Overflow => return error.ValueOutOfRange,
    };
    if (value < minimum or value > maximum) return error.ValueOutOfRange;
    return @intCast(value);
}

fn parseStep(source: []const u8) ParseError!u16 {
    for (source) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidSyntax;
    const step = std.fmt.parseUnsigned(u16, source, 10) catch |err| switch (err) {
        error.InvalidCharacter => return error.InvalidSyntax,
        error.Overflow => return error.InvalidStep,
    };
    if (step == 0) return error.InvalidStep;
    return step;
}

fn fullMask(minimum: u8, maximum: u8) u64 {
    const width: u8 = maximum - minimum + 1;
    return (@as(u64, 1) << @intCast(width)) - 1;
}

fn steppedMask(minimum: u8, maximum: u8, step: u16) u64 {
    var mask: u64 = 0;
    var value: u16 = minimum;
    while (value <= maximum) {
        mask |= @as(u64, 1) << @intCast(value - minimum);
        if (maximum - value < step) break;
        value += step;
    }
    return mask;
}

fn has(mask: anytype, value: anytype, minimum: u8) bool {
    return mask & (@as(@TypeOf(mask), 1) << @intCast(value - minimum)) != 0;
}

fn fuzzParse(_: void, smith: *std.testing.Smith) !void {
    var buffer: [256]u8 = undefined;
    const source = buffer[0..smith.slice(&buffer)];
    if (Expression.parse(source)) |_| {} else |_| {}
}

test "expression parser tolerates arbitrary input" {
    try std.testing.fuzz({}, fuzzParse, .{ .corpus = &.{
        "* * * * *",
    } });
}

test "parse five-field numeric syntax" {
    const expression = try Expression.parse("*/15 8-12/2 * 1,3 1-5");
    try std.testing.expect(try expression.matches(try DateTime.init(2026, .mar, 2, 10, 30)));
    try std.testing.expect(!try expression.matches(try DateTime.init(2026, .mar, 2, 11, 30)));
    try std.testing.expect(!try expression.matches(try DateTime.init(2026, .mar, 2, 10, 31)));

    try std.testing.expectError(error.InvalidFieldCount, Expression.parse("* * * *"));
    try std.testing.expectError(error.InvalidSyntax, Expression.parse("1/2 * * * *"));
    try std.testing.expectError(error.InvalidSyntax, Expression.parse("1_0 * * * *"));
    try std.testing.expectError(error.ValueOutOfRange, Expression.parse("60 * * * *"));
    try std.testing.expectError(error.InvalidRange, Expression.parse("5-1 * * * *"));
    try std.testing.expectError(error.InvalidStep, Expression.parse("*/0 * * * *"));
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

test "invalid dates and impossible schedules are reported" {
    const daily = try Expression.parse("0 0 * * *");
    const invalid: DateTime = .{ .year = 2026, .month = .feb, .day = 30, .hour = 0, .minute = 0 };
    try std.testing.expectError(error.InvalidDateTime, daily.matches(invalid));
    try std.testing.expectError(error.InvalidDateTime, daily.next(invalid));

    const impossible = try Expression.parse("0 0 31 2 *");
    try std.testing.expectEqual(null, try impossible.next(try DateTime.init(2026, .jan, 1, 0, 0)));
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
