//! The cron expression grammar.
//!
//! An expression is five fields, `minute hour day-of-month month day-of-week`,
//! separated by spaces, tabs, or line breaks, or one macro: `@yearly`,
//! `@annually`, `@monthly`, `@weekly`, `@daily`, `@midnight`, `@hourly`.
//! A field is a comma-separated list of `*`, `N`, `N-M`, `*/S`, `N-M/S`, or
//! `N/S` (from N to the field's maximum). Months and weekdays also take
//! three-letter names in any case, and Sunday is both 0 and 7.

const std = @import("std");
const Expression = @import("expression.zig").Expression;

pub const ParseError = error{
    InvalidFieldCount,
    InvalidSyntax,
    ValueOutOfRange,
    InvalidRange,
    InvalidStep,
    /// The day of week is `*` and no listed month has a listed day of month,
    /// as in `0 0 31 2 *`, so the expression can never fire.
    ImpossibleSchedule,
};

/// Where and why parsing failed, to show whoever wrote the expression.
pub const Diagnostics = struct {
    /// The failing field: 0 minute, 1 hour, 2 day of month, 3 month, 4 day of
    /// week. `null` when the expression as a whole is malformed.
    field: ?u3 = null,
    message: []const u8 = "",
};

const Field = struct {
    name: []const u8,
    min: u8,
    max: u8,
    /// Names of `min`, `min + 1`, and so on.
    names: []const []const u8 = &.{},
};

const fields = [5]Field{
    .{ .name = "minute", .min = 0, .max = 59 },
    .{ .name = "hour", .min = 0, .max = 23 },
    .{ .name = "day of month", .min = 1, .max = 31 },
    .{
        .name = "month",
        .min = 1,
        .max = 12,
        .names = &.{ "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" },
    },
    .{
        .name = "day of week",
        .min = 0,
        .max = 7,
        .names = &.{ "sun", "mon", "tue", "wed", "thu", "fri", "sat" },
    },
};

const macros = std.StaticStringMap([]const u8).initComptime(.{
    .{ "@yearly", "0 0 1 1 *" },
    .{ "@annually", "0 0 1 1 *" },
    .{ "@monthly", "0 0 1 * *" },
    .{ "@weekly", "0 0 * * 0" },
    .{ "@daily", "0 0 * * *" },
    .{ "@midnight", "0 0 * * *" },
    .{ "@hourly", "0 * * * *" },
});

const separators = " \t\r\n";

pub fn parse(source: []const u8, diagnostics: *Diagnostics) ParseError!Expression {
    diagnostics.* = .{};
    const trimmed = std.mem.trim(u8, source, separators);
    const text = if (std.mem.startsWith(u8, trimmed, "@"))
        macros.get(trimmed) orelse return fail(
            diagnostics,
            null,
            error.InvalidSyntax,
            "unknown macro: use @yearly, @annually, @monthly, @weekly, @daily, @midnight, or @hourly",
        )
    else
        trimmed;

    var sources: [5][]const u8 = undefined;
    var tokens = std.mem.tokenizeAny(u8, text, separators);
    const field_count_message = "expected five fields: minute hour day-of-month month day-of-week";
    for (&sources) |*field_source| field_source.* = tokens.next() orelse
        return fail(diagnostics, null, error.InvalidFieldCount, field_count_message);
    if (tokens.next() != null) return fail(diagnostics, null, error.InvalidFieldCount, field_count_message);

    var masks: [5]u64 = undefined;
    inline for (fields, sources, &masks, 0..) |field, field_source, *mask, index| {
        mask.* = parseField(field_source, field) catch |err|
            return fail(diagnostics, index, err, fieldMessage(field, err));
    }
    const expression: Expression = .{
        .minutes = masks[0],
        .hours = @intCast(masks[1]),
        .days_of_month = @intCast(masks[2]),
        .months = @intCast(masks[3]),
        .days_of_week = @intCast((masks[4] | masks[4] >> 7) & 0x7f),
        .minute_star = sources[0][0] == '*',
        .hour_star = sources[1][0] == '*',
        .day_of_month_star = sources[2][0] == '*',
        .day_of_week_star = sources[4][0] == '*',
    };
    if (expression.day_of_week_star and !hasPossibleDay(masks[2], masks[3]))
        return fail(diagnostics, 2, error.ImpossibleSchedule, "no listed month has the listed day of month");
    return expression;
}

fn fail(diagnostics: *Diagnostics, field: ?u3, err: ParseError, message: []const u8) ParseError {
    diagnostics.* = .{ .field = field, .message = message };
    return err;
}

fn fieldMessage(comptime field: Field, err: ParseError) []const u8 {
    const range = std.fmt.comptimePrint("{d}-{d}", .{ field.min, field.max });
    const forms = if (field.names.len > 0) "numbers, names" else "numbers";
    return switch (err) {
        error.ValueOutOfRange => field.name ++ " values must be within " ++ range,
        error.InvalidRange => field.name ++ " range must not end before it starts",
        error.InvalidStep => field.name ++ " step must be a whole number from 1 to 65535",
        else => field.name ++ " takes " ++ forms ++ ", ranges a-b, lists a,b, and steps */n",
    };
}

fn parseField(source: []const u8, comptime field: Field) ParseError!u64 {
    var mask: u64 = 0;
    var parts = std.mem.splitScalar(u8, source, ',');
    while (parts.next()) |part| {
        const slash = std.mem.indexOfScalar(u8, part, '/');
        const base = part[0 .. slash orelse part.len];
        const step = if (slash) |index| try parseStep(part[index + 1 ..]) else 1;

        var first: u8 = field.min;
        var last: u8 = field.max;
        if (!std.mem.eql(u8, base, "*")) {
            if (std.mem.indexOfScalar(u8, base, '-')) |dash| {
                first = try parseValue(base[0..dash], field);
                last = try parseValue(base[dash + 1 ..], field);
                // A weekday range may end on Sunday written as 0, as in `FRI-SUN`.
                if (field.max == 7 and last == 0 and first > 0) last = 7;
                if (first > last) return error.InvalidRange;
            } else {
                first = try parseValue(base, field);
                if (slash == null) last = first;
            }
        }
        mask |= steppedMask(first, last, step) << @intCast(first - field.min);
    }
    return mask;
}

fn parseValue(source: []const u8, comptime field: Field) ParseError!u8 {
    for (field.names, field.min..) |name, value| {
        if (std.ascii.eqlIgnoreCase(source, name)) return @intCast(value);
    }
    for (source) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidSyntax;
    const value = std.fmt.parseUnsigned(u16, source, 10) catch |err| switch (err) {
        error.InvalidCharacter => return error.InvalidSyntax,
        error.Overflow => return error.ValueOutOfRange,
    };
    if (value < field.min or value > field.max) return error.ValueOutOfRange;
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

/// Bits for `first`, `first + step`, ... up to `last`, with `first` as bit 0.
fn steppedMask(first: u8, last: u8, step: u16) u64 {
    var mask: u64 = 0;
    var value: u16 = first;
    while (value <= last) {
        mask |= @as(u64, 1) << @intCast(value - first);
        if (last - value < step) break;
        value += step;
    }
    return mask;
}

/// Whether some listed month has a listed day of month, counting February 29.
fn hasPossibleDay(days_of_month: u64, months: u64) bool {
    const month_lengths = [12]u6{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    for (month_lengths, 0..) |length, month| {
        const listed = (months >> @intCast(month)) & 1 == 1;
        if (listed and days_of_month & ((@as(u64, 1) << length) - 1) != 0) return true;
    }
    return false;
}

fn fuzzParse(_: void, smith: *std.testing.Smith) !void {
    var buffer: [256]u8 = undefined;
    const source = buffer[0..smith.slice(&buffer)];
    var diagnostics: Diagnostics = .{};
    if (parse(source, &diagnostics)) |_| {} else |_| {}
}

test "expression parser tolerates arbitrary input" {
    try std.testing.fuzz({}, fuzzParse, .{ .corpus = &.{
        "* * * * *",
        "*/15 8-12/2 1,15 JAN-MAR mon-fri",
        "5/15 * * * FRI-SUN",
        "0 0 31 2 *",
        "@daily",
        "@reboot",
        "* * * * *\r\n",
    } });
}

fn expectMinutes(source: []const u8, expected: []const u8) !void {
    var mask: u64 = 0;
    for (expected) |minute| mask |= @as(u64, 1) << @intCast(minute);
    try std.testing.expectEqual(mask, (try Expression.parse(source)).minutes);
}

fn expectWeekdays(source: []const u8, expected: []const u8) !void {
    var mask: u8 = 0;
    for (expected) |day| mask |= @as(u8, 1) << @intCast(day);
    try std.testing.expectEqual(mask, (try Expression.parse(source)).days_of_week);
}

test "fields take lists, ranges, and steps" {
    try expectMinutes("*/15 * * * *", &.{ 0, 15, 30, 45 });
    try expectMinutes("5/15 * * * *", &.{ 5, 20, 35, 50 });
    try expectMinutes("10-20/5,59 * * * *", &.{ 10, 15, 20, 59 });
    try expectMinutes("1,*/30 * * * *", &.{ 0, 1, 30 });
    try std.testing.expectEqual(try Expression.parse("* * * * *"), try Expression.parse("\t* * * * *\r\n"));

    try std.testing.expectError(error.InvalidFieldCount, Expression.parse("* * * *"));
    try std.testing.expectError(error.InvalidFieldCount, Expression.parse("* * * * * *"));
    try std.testing.expectError(error.InvalidSyntax, Expression.parse("1_0 * * * *"));
    try std.testing.expectError(error.InvalidSyntax, Expression.parse("1-2-3 * * * *"));
    try std.testing.expectError(error.InvalidSyntax, Expression.parse("1, * * * *"));
    try std.testing.expectError(error.InvalidSyntax, Expression.parse("*-5 * * * *"));
    try std.testing.expectError(error.InvalidSyntax, Expression.parse("JAN * * * *"));
    try std.testing.expectError(error.ValueOutOfRange, Expression.parse("60 * * * *"));
    try std.testing.expectError(error.ValueOutOfRange, Expression.parse("* * * * 8"));
    try std.testing.expectError(error.InvalidRange, Expression.parse("5-1 * * * *"));
    try std.testing.expectError(error.InvalidStep, Expression.parse("*/0 * * * *"));
    try std.testing.expectError(error.InvalidStep, Expression.parse("*/65536 * * * *"));
}

test "months and weekdays take names, and Sunday is 0 or 7" {
    const named = try Expression.parse("0 9 * jan-MAR,Dec Mon-fri");
    try std.testing.expectEqual(try Expression.parse("0 9 * 1-3,12 1-5"), named);

    try expectWeekdays("* * * * 7", &.{0});
    try expectWeekdays("* * * * 5-7", &.{ 0, 5, 6 });
    try expectWeekdays("* * * * FRI-SUN", &.{ 0, 5, 6 });
    try expectWeekdays("* * * * */2", &.{ 0, 2, 4, 6 });
    try expectWeekdays("* * * * 1/2", &.{ 0, 1, 3, 5 });
    try std.testing.expectError(error.InvalidRange, Expression.parse("* * * * SAT-MON"));
}

test "macros equal their five-field forms" {
    const cases = [_][2][]const u8{
        .{ "@yearly", "0 0 1 1 *" },
        .{ "@annually", "0 0 1 1 *" },
        .{ "@monthly", "0 0 1 * *" },
        .{ "@weekly", "0 0 * * 0" },
        .{ "@daily", "0 0 * * *" },
        .{ "@midnight", "0 0 * * *" },
        .{ "@hourly\n", "0 * * * *" },
    };
    for (cases) |case| {
        try std.testing.expectEqual(try Expression.parse(case[1]), try Expression.parse(case[0]));
    }
    try std.testing.expectError(error.InvalidSyntax, Expression.parse("@reboot"));
    try std.testing.expectError(error.InvalidSyntax, Expression.parse("@Daily"));
    try std.testing.expectError(error.InvalidSyntax, Expression.parse("@daily *"));
}

test "schedules that can never fire are rejected" {
    for ([_][]const u8{ "0 0 31 2 *", "0 0 30 2 *", "0 0 31 4 *", "0 0 30,31 2 */2" }) |source| {
        try std.testing.expectError(error.ImpossibleSchedule, Expression.parse(source));
    }
    for ([_][]const u8{ "0 0 29 2 *", "0 0 31 4,5 *", "0 0 31 2 1", "0 0 31 * *" }) |source| {
        _ = try Expression.parse(source);
    }
}

test "diagnostics name the failing field and why" {
    var diagnostics: Diagnostics = .{};
    try std.testing.expectError(error.ValueOutOfRange, Expression.parseWithDiagnostics("0 24 * * *", &diagnostics));
    try std.testing.expectEqual(1, diagnostics.field);
    try std.testing.expectEqualStrings("hour values must be within 0-23", diagnostics.message);

    try std.testing.expectError(error.InvalidSyntax, Expression.parseWithDiagnostics("* * * JUNE *", &diagnostics));
    try std.testing.expectEqual(3, diagnostics.field);
    try std.testing.expectEqualStrings(
        "month takes numbers, names, ranges a-b, lists a,b, and steps */n",
        diagnostics.message,
    );

    try std.testing.expectError(error.ImpossibleSchedule, Expression.parseWithDiagnostics("0 0 31 2 *", &diagnostics));
    try std.testing.expectEqual(2, diagnostics.field);

    try std.testing.expectError(error.InvalidFieldCount, Expression.parseWithDiagnostics("* *", &diagnostics));
    try std.testing.expectEqual(null, diagnostics.field);

    _ = try Expression.parseWithDiagnostics("@hourly", &diagnostics);
    try std.testing.expectEqual(Diagnostics{}, diagnostics);
}
