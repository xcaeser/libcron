//! Proleptic Gregorian calendar arithmetic at minute resolution.

const std = @import("std");

pub const Month = std.time.epoch.Month;

pub const DateTimeError = error{InvalidDateTime};

/// A timezone-neutral Gregorian calendar minute.
pub const DateTime = struct {
    year: u16,
    month: Month,
    day: u8,
    hour: u8,
    minute: u8,

    pub fn init(year: u16, month: Month, day: u8, hour: u8, minute: u8) DateTimeError!DateTime {
        const date_time: DateTime = .{
            .year = year,
            .month = month,
            .day = day,
            .hour = hour,
            .minute = minute,
        };
        try date_time.validate();
        return date_time;
    }

    /// Formats as `2026-10-25 02:30`.
    pub fn format(self: DateTime, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
            self.year, self.month.numeric(), self.day, self.hour, self.minute,
        });
    }

    pub fn validate(self: DateTime) DateTimeError!void {
        if (self.year == 0 or
            self.day == 0 or self.day > std.time.epoch.getDaysInMonth(self.year, self.month) or
            self.hour > 23 or self.minute > 59)
        {
            return error.InvalidDateTime;
        }
    }
};

pub const seconds_per_day = 86_400;

/// Minutes from 1970-01-01 00:00 to `date_time` on the same calendar,
/// ignoring any UTC offset.
pub fn epochMinute(date_time: DateTime) i64 {
    return daysFromCivil(date_time.year, date_time.month, date_time.day) * 1_440 +
        @as(i64, date_time.hour) * 60 + date_time.minute;
}

pub fn civilFromUnix(unix_seconds: i64, offset: i32) error{DateOutOfRange}!DateTime {
    const local = std.math.add(i64, unix_seconds, offset) catch return error.DateOutOfRange;
    const days = @divFloor(local, seconds_per_day);
    const second_of_day: u32 = @intCast(local - days * seconds_per_day);

    const adjusted = std.math.add(i64, days, 719_468) catch return error.DateOutOfRange;
    const era = @divFloor(adjusted, 146_097);
    const day_of_era = adjusted - era * 146_097;
    const year_of_era = @divFloor(
        day_of_era - @divFloor(day_of_era, 1_460) + @divFloor(day_of_era, 36_524) - @divFloor(day_of_era, 146_096),
        365,
    );
    var year = year_of_era + era * 400;
    const day_of_year = day_of_era - (365 * year_of_era + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100));
    const month_prime = @divFloor(5 * day_of_year + 2, 153);
    const day = day_of_year - @divFloor(153 * month_prime + 2, 5) + 1;
    const month = month_prime + if (month_prime < 10) @as(i64, 3) else -9;
    year += if (month <= 2) 1 else 0;
    if (year < 1 or year > std.math.maxInt(u16)) return error.DateOutOfRange;

    return .{
        .year = @intCast(year),
        .month = @fromBackingInt(@as(u4, @intCast(month))),
        .day = @intCast(day),
        .hour = @intCast(second_of_day / 3_600),
        .minute = @intCast(second_of_day % 3_600 / 60),
    };
}

pub fn daysFromCivil(year_value: u16, month_value: Month, day_value: u8) i64 {
    var year: i64 = year_value;
    const month: i64 = month_value.numeric();
    year -= if (month <= 2) 1 else 0;
    const era = @divFloor(year, 400);
    const year_of_era = year - era * 400;
    const month_prime = month + if (month > 2) @as(i64, -3) else 9;
    const day_of_year = @divFloor(153 * month_prime + 2, 5) + day_value - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) -
        @divFloor(year_of_era, 100) + day_of_year;
    return era * 146_097 + day_of_era - 719_468;
}

pub fn weekday(date_time: DateTime) u8 {
    const offsets = [_]u8{ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 };
    const month: u8 = date_time.month.numeric();
    var year: u32 = date_time.year;
    if (month < 3) year -= 1;
    return @intCast((year + year / 4 - year / 100 + year / 400 + offsets[month - 1] + date_time.day) % 7);
}

pub fn nextMinute(date_time: DateTime) ?DateTime {
    var next = date_time;
    if (next.minute < 59) {
        next.minute += 1;
        return next;
    }
    next.minute = 0;
    if (next.hour < 23) {
        next.hour += 1;
        return next;
    }
    return nextDay(next);
}

pub fn nextDay(date_time: DateTime) ?DateTime {
    var next = date_time;
    next.hour = 0;
    next.minute = 0;

    if (next.day < std.time.epoch.getDaysInMonth(next.year, next.month)) {
        next.day += 1;
        return next;
    }
    next.day = 1;

    if (next.month != .dec) {
        next.month = @as(Month, @fromBackingInt(@as(u4, @intCast(next.month.numeric() + 1))));
        return next;
    }
    if (next.year == std.math.maxInt(u16)) return null;
    next.year += 1;
    next.month = .jan;
    return next;
}

test "date-times format for log lines" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings(
        "0987-03-09 04:05",
        try std.fmt.bufPrint(&buffer, "{f}", .{try DateTime.init(987, .mar, 9, 4, 5)}),
    );
}
