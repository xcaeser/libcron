//! UTC, fixed-offset, and TZif time zones with POSIX TZ footer rules.

const std = @import("std");
const calendar = @import("calendar.zig");

const DateTime = calendar.DateTime;
const Month = calendar.Month;
const seconds_per_day = calendar.seconds_per_day;

pub const TimeZoneError = error{
    InvalidOffset,
    InvalidTzif,
    InvalidTzifFooter,
    MissingFutureRule,
    DateOutOfRange,
};

const min_utc_offset = -89_999;
const max_utc_offset = 93_599;

/// A validated UTC, fixed-offset, or caller-owned TZif timezone.
pub const TimeZone = struct {
    value: union(enum) {
        fixed: i32,
        tzif: struct {
            tz: *const std.Tz,
            footer: ?PosixTimeZone,
        },
    },

    pub const utc: TimeZone = .{ .value = .{ .fixed = 0 } };

    /// Creates a fixed timezone offset east of UTC, in seconds, within the
    /// interoperable TZif range -89,999 through 93,599.
    pub fn fixedOffset(seconds: i32) TimeZoneError!TimeZone {
        if (seconds < min_utc_offset or seconds > max_utc_offset) return error.InvalidOffset;
        return .{ .value = .{ .fixed = seconds } };
    }

    /// Creates a timezone borrowing `tz`, which must outlive every use.
    pub fn fromTz(tz: *const std.Tz) TimeZoneError!TimeZone {
        if (tz.timetypes.len == 0) return error.InvalidTzif;
        for (tz.timetypes) |time_type| {
            if (time_type.offset == std.math.minInt(i32)) return error.InvalidTzif;
        }
        const type_start = @intFromPtr(tz.timetypes.ptr);
        const type_size = @sizeOf(std.tz.Timetype);
        const type_end = type_start + type_size * tz.timetypes.len;
        for (tz.transitions) |transition| {
            const address = @intFromPtr(transition.timetype);
            if (address < type_start or address >= type_end or (address - type_start) % type_size != 0)
                return error.InvalidTzif;
        }
        if (tz.transitions.len > 1) {
            for (tz.transitions[1..], tz.transitions[0 .. tz.transitions.len - 1]) |current, previous| {
                if (current.ts <= previous.ts) return error.InvalidTzif;
            }
        }
        for (tz.leapseconds, 0..) |leap, index| {
            if (leap.occurrence < 0) return error.InvalidTzif;
            if (index == 0) {
                if (leap.correction != -1 and leap.correction != 1) return error.InvalidTzif;
                continue;
            }
            const previous = tz.leapseconds[index - 1];
            if (@as(i64, previous.occurrence) + 2_419_199 > leap.occurrence) return error.InvalidTzif;
            const correction_delta = @as(i32, leap.correction) - previous.correction;
            if (correction_delta != -1 and correction_delta != 1) return error.InvalidTzif;
        }

        var footer: ?PosixTimeZone = null;
        if (tz.footer) |source| {
            if (source.len > 0) footer = try PosixTimeZone.parse(source);
        }
        if (tz.transitions.len > 0 and footer == null) return error.MissingFutureRule;
        if (tz.transitions.len > 0) {
            const last = tz.transitions[tz.transitions.len - 1];
            const unix_seconds = try unixTimeFromLeap(tz, last.ts);
            if (try footer.?.offsetAt(unix_seconds) != last.timetype.offset)
                return error.InvalidTzifFooter;
        }

        return .{ .value = .{ .tzif = .{ .tz = tz, .footer = footer } } };
    }

    /// Returns the local wall-clock minute at `unix_seconds`.
    pub fn toLocal(self: TimeZone, unix_seconds: i64) TimeZoneError!DateTime {
        return calendar.civilFromUnix(unix_seconds, try self.offsetAt(unix_seconds));
    }

    fn offsetAt(self: TimeZone, unix_seconds: i64) TimeZoneError!i32 {
        return switch (self.value) {
            .fixed => |offset| offset,
            .tzif => |zone| tzif: {
                const transitions = zone.tz.transitions;
                if (transitions.len == 0) {
                    break :tzif if (zone.footer) |footer|
                        try footer.offsetAt(unix_seconds)
                    else
                        zone.tz.timetypes[0].offset;
                }
                const transition_time = try unixLeapTime(zone.tz, unix_seconds);
                if (transition_time < transitions[0].ts) break :tzif zone.tz.timetypes[0].offset;
                if (transition_time >= transitions[transitions.len - 1].ts)
                    break :tzif try zone.footer.?.offsetAt(unix_seconds);

                var low: usize = 0;
                var high: usize = transitions.len;
                while (low < high) {
                    const middle = low + (high - low) / 2;
                    if (transitions[middle].ts <= transition_time)
                        low = middle + 1
                    else
                        high = middle;
                }
                break :tzif transitions[low - 1].timetype.offset;
            },
        };
    }
};

fn unixLeapTime(tz: *const std.Tz, unix_seconds: i64) TimeZoneError!i64 {
    var correction: i64 = 0;
    for (tz.leapseconds) |leap| {
        // `correction` is the value in force before this leap record.
        const event_unix = std.math.sub(i64, leap.occurrence, correction) catch
            return error.DateOutOfRange;
        if (unix_seconds < event_unix) break;
        correction = leap.correction;
    }
    return std.math.add(i64, unix_seconds, correction) catch error.DateOutOfRange;
}

fn unixTimeFromLeap(tz: *const std.Tz, leap_seconds: i64) TimeZoneError!i64 {
    var correction: i64 = 0;
    for (tz.leapseconds) |leap| {
        if (leap_seconds < leap.occurrence) break;
        const next_correction: i64 = leap.correction;
        if (next_correction > correction and
            leap_seconds < @as(i64, leap.occurrence) + next_correction - correction)
            return error.InvalidTzif;
        correction = next_correction;
    }
    return std.math.sub(i64, leap_seconds, correction) catch error.DateOutOfRange;
}

const PosixTimeZone = struct {
    standard_offset: i32,
    daylight_offset: ?i32 = null,
    start: TransitionRule = undefined,
    end: TransitionRule = undefined,

    fn parse(source: []const u8) TimeZoneError!PosixTimeZone {
        for (source) |byte| if (!std.ascii.isPrint(byte)) return error.InvalidTzifFooter;
        var parser: FooterParser = .{ .source = source };
        try parser.skipName();

        var result: PosixTimeZone = .{ .standard_offset = try parser.parseOffset() };
        if (parser.done()) return result;

        try parser.skipName();
        result.daylight_offset = if (parser.peek() != ',')
            try parser.parseOffset()
        else
            result.standard_offset + 3_600;
        try parser.expect(',');
        result.start = try parser.parseRule();
        try parser.expect(',');
        result.end = try parser.parseRule();
        if (!parser.done()) return error.InvalidTzifFooter;
        return result;
    }

    fn offsetAt(self: PosixTimeZone, unix_seconds: i64) TimeZoneError!i32 {
        const daylight_offset = self.daylight_offset orelse return self.standard_offset;
        const year = (try calendar.civilFromUnix(unix_seconds, self.standard_offset)).year;
        const RuleTransition = struct {
            at: i64,
            before: i32,
            after: i32,
        };
        var latest: ?RuleTransition = null;
        var earliest: ?RuleTransition = null;

        const year_value: u32 = year;
        // Both rules for Y-1 may spill into Y, so retain Y-2 as prior state.
        var rule_year: u32 = if (year_value > 2) year_value - 2 else 1;
        const last_year: u32 = if (year_value < std.math.maxInt(u16)) year_value + 1 else year_value;
        while (rule_year <= last_year) : (rule_year += 1) {
            const candidate_year: u16 = @intCast(rule_year);
            const transitions = [_]RuleTransition{
                .{
                    .at = self.start.unix(candidate_year, self.standard_offset, self.standard_offset),
                    .before = self.standard_offset,
                    .after = daylight_offset,
                },
                .{
                    .at = self.end.unix(candidate_year, self.standard_offset, daylight_offset),
                    .before = daylight_offset,
                    .after = self.standard_offset,
                },
            };
            for (transitions) |transition| {
                if (transition.at <= unix_seconds) {
                    if (latest == null or transition.at >= latest.?.at) latest = transition;
                } else if (earliest == null or transition.at < earliest.?.at) {
                    earliest = transition;
                }
            }
        }
        return if (latest) |transition| transition.after else earliest.?.before;
    }
};

const TransitionRule = struct {
    day: union(enum) {
        julian_no_leap: u16,
        day_of_year: u16,
        month_week_day: struct {
            month: u8,
            week: u8,
            weekday: u8,
        },
    },
    seconds: i32 = 2 * 60 * 60,
    basis: enum { wall, standard, utc } = .wall,

    fn unix(self: TransitionRule, year: u16, standard_offset: i32, before_offset: i32) i64 {
        const day_index: i64 = switch (self.day) {
            .julian_no_leap => |day| blk: {
                var index: i64 = day - 1;
                if (std.time.epoch.isLeapYear(year) and day >= 60) index += 1;
                break :blk index;
            },
            .day_of_year => |day| day,
            .month_week_day => |rule| blk: {
                const month: Month = @fromBackingInt(@as(u4, @intCast(rule.month)));
                const first_weekday = calendar.weekday(.{
                    .year = year,
                    .month = month,
                    .day = 1,
                    .hour = 0,
                    .minute = 0,
                });
                var day: u8 = 1 + (rule.weekday + 7 - first_weekday) % 7 + 7 * (rule.week - 1);
                const days_in_month = std.time.epoch.getDaysInMonth(year, month);
                if (day > days_in_month) day -= 7;

                var index: i64 = day - 1;
                var number: u8 = 1;
                while (number < rule.month) : (number += 1) {
                    const prior: Month = @fromBackingInt(@as(u4, @intCast(number)));
                    index += std.time.epoch.getDaysInMonth(year, prior);
                }
                break :blk index;
            },
        };
        const local = calendar.daysFromCivil(year, .jan, 1) * seconds_per_day +
            day_index * seconds_per_day + self.seconds;
        return local - switch (self.basis) {
            .wall => before_offset,
            .standard => standard_offset,
            .utc => 0,
        };
    }
};

const FooterParser = struct {
    source: []const u8,
    index: usize = 0,

    fn done(self: FooterParser) bool {
        return self.index == self.source.len;
    }

    fn peek(self: FooterParser) u8 {
        return if (self.done()) 0 else self.source[self.index];
    }

    fn expect(self: *FooterParser, expected: u8) TimeZoneError!void {
        if (self.peek() != expected) return error.InvalidTzifFooter;
        self.index += 1;
    }

    fn skipName(self: *FooterParser) TimeZoneError!void {
        const start = self.index;
        if (self.peek() == '<') {
            self.index += 1;
            const name_start = self.index;
            while (!self.done() and self.peek() != '>') : (self.index += 1) {}
            if (self.done() or self.index - name_start < 3) return error.InvalidTzifFooter;
            self.index += 1;
            return;
        }
        while (!self.done() and std.ascii.isAlphabetic(self.peek())) : (self.index += 1) {}
        if (self.index - start < 3) return error.InvalidTzifFooter;
    }

    fn parseOffset(self: *FooterParser) TimeZoneError!i32 {
        var sign: i32 = 1;
        if (self.peek() == '+' or self.peek() == '-') {
            if (self.peek() == '-') sign = -1;
            self.index += 1;
        }
        return -sign * try self.parseTime(24);
    }

    fn parseRule(self: *FooterParser) TimeZoneError!TransitionRule {
        var rule: TransitionRule = undefined;
        if (self.peek() == 'J') {
            self.index += 1;
            const day = try self.parseNumber(365);
            if (day == 0) return error.InvalidTzifFooter;
            rule = .{ .day = .{ .julian_no_leap = day } };
        } else if (self.peek() == 'M') {
            self.index += 1;
            const month = try self.parseNumber(12);
            try self.expect('.');
            const week = try self.parseNumber(5);
            try self.expect('.');
            const day = try self.parseNumber(6);
            if (month == 0 or week == 0) return error.InvalidTzifFooter;
            rule = .{ .day = .{ .month_week_day = .{
                .month = @intCast(month),
                .week = @intCast(week),
                .weekday = @intCast(day),
            } } };
        } else {
            rule = .{ .day = .{ .day_of_year = try self.parseNumber(365) } };
        }

        if (self.peek() == '/') {
            self.index += 1;
            var sign: i32 = 1;
            if (self.peek() == '+' or self.peek() == '-') {
                if (self.peek() == '-') sign = -1;
                self.index += 1;
            }
            rule.seconds = sign * try self.parseTime(167);
            switch (self.peek()) {
                's' => {
                    rule.basis = .standard;
                    self.index += 1;
                },
                'u', 'g', 'z' => {
                    rule.basis = .utc;
                    self.index += 1;
                },
                'w' => self.index += 1,
                else => {},
            }
        }
        return rule;
    }

    fn parseTime(self: *FooterParser, maximum_hour: u16) TimeZoneError!i32 {
        const hour = try self.parseNumber(maximum_hour);
        var minute: u16 = 0;
        var second: u16 = 0;
        if (self.peek() == ':') {
            self.index += 1;
            minute = try self.parseNumber(59);
            if (self.peek() == ':') {
                self.index += 1;
                second = try self.parseNumber(59);
            }
        }
        return @as(i32, hour) * 3_600 + @as(i32, minute) * 60 + second;
    }

    fn parseNumber(self: *FooterParser, maximum: u16) TimeZoneError!u16 {
        const start = self.index;
        while (!self.done() and std.ascii.isDigit(self.peek())) : (self.index += 1) {}
        if (self.index == start) return error.InvalidTzifFooter;
        const result = std.fmt.parseUnsigned(u16, self.source[start..self.index], 10) catch
            return error.InvalidTzifFooter;
        if (result > maximum) return error.InvalidTzifFooter;
        return result;
    }
};

fn unixSeconds(year: u16, month: Month, day: u8, hour: u8, minute: u8) i64 {
    return calendar.epochMinute(.{ .year = year, .month = month, .day = day, .hour = hour, .minute = minute }) * 60;
}

fn fuzzFooter(_: void, smith: *std.testing.Smith) !void {
    var buffer: [256]u8 = undefined;
    const source = buffer[0..smith.slice(&buffer)];
    if (PosixTimeZone.parse(source)) |_| {} else |_| {}
}

test "TZ footer parser tolerates arbitrary input" {
    try std.testing.fuzz({}, fuzzFooter, .{ .corpus = &.{
        "CET-1CEST,M3.5.0,M10.5.0/3",
    } });
}

test "UTC, fixed offsets, and recorded TZif transitions convert calendar minutes" {
    try std.testing.expectEqual(
        try DateTime.init(1970, .jan, 1, 0, 0),
        try TimeZone.utc.toLocal(0),
    );
    try std.testing.expectEqual(
        try DateTime.init(1969, .dec, 31, 23, 59),
        try TimeZone.utc.toLocal(-60),
    );
    const fixed = try TimeZone.fixedOffset(90 * 60);
    try std.testing.expectEqual(
        try DateTime.init(1970, .jan, 1, 1, 30),
        try fixed.toLocal(0),
    );
    _ = try TimeZone.fixedOffset(min_utc_offset);
    _ = try TimeZone.fixedOffset(max_utc_offset);
    try std.testing.expectError(error.InvalidOffset, TimeZone.fixedOffset(min_utc_offset - 1));
    try std.testing.expectError(error.InvalidOffset, TimeZone.fixedOffset(max_utc_offset + 1));

    var timetypes = [_]std.tz.Timetype{
        .{ .offset = 0, .flags = 0, .name_data = .{ 'U', 'T', 'C', 0, 0, 0 } },
        .{ .offset = 3_600, .flags = 1, .name_data = .{ 'D', 'S', 'T', 0, 0, 0 } },
        .{ .offset = 7_200, .flags = 0, .name_data = .{ 'F', 'U', 'T', 0, 0, 0 } },
    };
    var transitions = [_]std.tz.Transition{
        .{ .ts = 3_600, .timetype = &timetypes[1] },
        .{ .ts = 7_200, .timetype = &timetypes[2] },
    };
    const tz: std.Tz = .{
        .allocator = std.testing.allocator,
        .transitions = &transitions,
        .timetypes = &timetypes,
        .leapseconds = &.{},
        .footer = "FUT-2",
    };
    const recorded = try TimeZone.fromTz(&tz);
    try std.testing.expectEqual(3_600, try recorded.offsetAt(3_600));
    try std.testing.expectEqual(3_600, try recorded.offsetAt(7_199));
    try std.testing.expectEqual(7_200, try recorded.offsetAt(7_200));

    const inconsistent_footer: std.Tz = .{
        .allocator = std.testing.allocator,
        .transitions = &transitions,
        .timetypes = &timetypes,
        .leapseconds = &.{},
        .footer = "UTC0",
    };
    try std.testing.expectError(error.InvalidTzifFooter, TimeZone.fromTz(&inconsistent_footer));

    var pre_transition_types = [_]std.tz.Timetype{
        .{ .offset = 3_600, .flags = 1, .name_data = .{ 'D', 'S', 'T', 0, 0, 0 } },
        .{ .offset = 0, .flags = 0, .name_data = .{ 'U', 'T', 'C', 0, 0, 0 } },
    };
    var first_transition = [_]std.tz.Transition{
        .{ .ts = 3_600, .timetype = &pre_transition_types[1] },
    };
    const pre_transition_tz: std.Tz = .{
        .allocator = std.testing.allocator,
        .transitions = &first_transition,
        .timetypes = &pre_transition_types,
        .leapseconds = &.{},
        .footer = "UTC0",
    };
    const pre_transition = try TimeZone.fromTz(&pre_transition_tz);
    try std.testing.expectEqual(3_600, try pre_transition.offsetAt(3_599));
    try std.testing.expectEqual(0, try pre_transition.offsetAt(3_600));

    var leap_transitions = [_]std.tz.Transition{
        .{ .ts = 78_796_801, .timetype = &timetypes[1] },
        .{ .ts = 78_796_900, .timetype = &timetypes[0] },
    };
    const leap_seconds = [_]std.tz.Leapsecond{
        .{ .occurrence = 78_796_800, .correction = 1 },
    };
    const leap_tz: std.Tz = .{
        .allocator = std.testing.allocator,
        .transitions = &leap_transitions,
        .timetypes = &timetypes,
        .leapseconds = &leap_seconds,
        .footer = "UTC0",
    };
    const leap_aware = try TimeZone.fromTz(&leap_tz);
    try std.testing.expectEqual(78_796_799, try unixLeapTime(&leap_tz, 78_796_799));
    try std.testing.expectEqual(78_796_801, try unixLeapTime(&leap_tz, 78_796_800));
    try std.testing.expectEqual(0, try leap_aware.offsetAt(78_796_799));
    try std.testing.expectEqual(3_600, try leap_aware.offsetAt(78_796_800));

    const truncated: std.Tz = .{
        .allocator = std.testing.allocator,
        .transitions = &transitions,
        .timetypes = &timetypes,
        .leapseconds = &.{},
        .footer = null,
    };
    try std.testing.expectError(error.MissingFutureRule, TimeZone.fromTz(&truncated));

    var unsorted_transitions = [_]std.tz.Transition{
        .{ .ts = 7_200, .timetype = &timetypes[0] },
        .{ .ts = 3_600, .timetype = &timetypes[1] },
    };
    const unsorted: std.Tz = .{
        .allocator = std.testing.allocator,
        .transitions = &unsorted_transitions,
        .timetypes = &timetypes,
        .leapseconds = &.{},
        .footer = "UTC0",
    };
    try std.testing.expectError(error.InvalidTzif, TimeZone.fromTz(&unsorted));

    const invalid_leaps = [_]std.tz.Leapsecond{
        .{ .occurrence = 78_796_800, .correction = 1 },
        .{ .occurrence = 78_796_799, .correction = 2 },
    };
    const invalid_leap_tz: std.Tz = .{
        .allocator = std.testing.allocator,
        .transitions = &.{},
        .timetypes = &timetypes,
        .leapseconds = &invalid_leaps,
        .footer = "UTC0",
    };
    try std.testing.expectError(error.InvalidTzif, TimeZone.fromTz(&invalid_leap_tz));
}

test "TZif POSIX rules skip spring gaps and repeat fall wall minutes" {
    try std.testing.expectError(
        error.InvalidTzifFooter,
        PosixTimeZone.parse("STD999999999999999999999999999999999999999"),
    );
    try std.testing.expectError(error.InvalidTzifFooter, PosixTimeZone.parse("<AB\x00C>0"));
    try std.testing.expectError(error.InvalidTzifFooter, PosixTimeZone.parse("<ABC\xff>0"));

    var timetypes = [_]std.tz.Timetype{
        .{ .offset = 3_600, .flags = 0, .name_data = .{ 'C', 'E', 'T', 0, 0, 0 } },
    };
    const tz: std.Tz = .{
        .allocator = std.testing.allocator,
        .transitions = &.{},
        .timetypes = &timetypes,
        .leapseconds = &.{},
        .footer = "CET-1CEST,M3.5.0,M10.5.0/3",
    };
    const paris = try TimeZone.fromTz(&tz);

    try std.testing.expectEqual(
        try DateTime.init(2026, .mar, 29, 1, 59),
        try paris.toLocal(unixSeconds(2026, .mar, 29, 0, 59)),
    );
    try std.testing.expectEqual(
        try DateTime.init(2026, .mar, 29, 3, 0),
        try paris.toLocal(unixSeconds(2026, .mar, 29, 1, 0)),
    );
    const first = try paris.toLocal(unixSeconds(2026, .oct, 25, 0, 30));
    const repeated = try paris.toLocal(unixSeconds(2026, .oct, 25, 1, 30));
    try std.testing.expectEqual(try DateTime.init(2026, .oct, 25, 2, 30), first);
    try std.testing.expectEqual(first, repeated);

    const cross_year_tz: std.Tz = .{
        .allocator = std.testing.allocator,
        .transitions = &.{},
        .timetypes = &timetypes,
        .leapseconds = &.{},
        .footer = "STD0DST,J1/-2,J100/0",
    };
    const cross_year = try TimeZone.fromTz(&cross_year_tz);
    try std.testing.expectEqual(
        0,
        try cross_year.offsetAt(unixSeconds(2025, .dec, 31, 21, 59)),
    );
    try std.testing.expectEqual(
        3_600,
        try cross_year.offsetAt(unixSeconds(2025, .dec, 31, 22, 0)),
    );
}
