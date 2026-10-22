//! `croner next`: when each job fires next, computed from its schedule and
//! time zone the way the scheduler runs it across DST changes.

const std = @import("std");
const Io = std.Io;

const libcron = @import("libcron");

const config = @import("config.zig");
const JobSpec = config.JobSpec;

/// Writes the next `count` fire instants after `now` (unix seconds) for each
/// spec, one line each: id, local time with its UTC offset, and how far off
/// it is. A paused job is marked on its first line.
pub fn writeNext(
    writer: *Io.Writer,
    specs: []const JobSpec,
    count: usize,
    now: i64,
    paused: []const []const u8,
) Io.Writer.Error!void {
    for (specs) |*spec| {
        const marker = for (paused) |id| {
            if (std.mem.eql(u8, id, spec.id)) break "\t(paused)";
        } else "";
        var after = now;
        for (0..count) |index| {
            const first_marker = if (index == 0) marker else "";
            const fire = spec.expression.nextInstant(after, spec.time_zone) orelse {
                try writer.print("{s}\tnever fires again{s}\n", .{ spec.id, first_marker });
                break;
            };
            try writer.print("{s}\t{f}\tin {f}{s}\n", .{
                spec.id,
                LocalTime{ .zone = spec.time_zone, .unix_seconds = fire },
                Delta{ .seconds = fire - now },
                first_marker,
            });
            after = fire;
        }
    }
}

/// ISO-8601 local time with its UTC offset, as in `2026-10-25T02:30:00+02:00`.
const LocalTime = struct {
    zone: libcron.TimeZone,
    unix_seconds: i64,

    pub fn format(self: LocalTime, writer: *Io.Writer) Io.Writer.Error!void {
        const local = self.zone.toLocal(self.unix_seconds) catch return writer.print("@{d}", .{self.unix_seconds});
        const utc = libcron.TimeZone.utc.toLocal(self.unix_seconds) catch return writer.print("@{d}", .{self.unix_seconds});
        // libcron does not expose a zone's offset; the two readings of one
        // instant are less than a day apart, so the date order settles it.
        var offset: i32 = (@as(i32, local.hour) * 60 + local.minute) - (@as(i32, utc.hour) * 60 + utc.minute);
        switch (std.math.order(dateKey(local), dateKey(utc))) {
            .gt => offset += 24 * 60,
            .lt => offset -= 24 * 60,
            .eq => {},
        }
        const magnitude = @abs(offset);
        try writer.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:00{c}{d:0>2}:{d:0>2}", .{
            local.year,
            local.month.numeric(),
            local.day,
            local.hour,
            local.minute,
            @as(u8, if (offset < 0) '-' else '+'),
            magnitude / 60,
            magnitude % 60,
        });
    }

    fn dateKey(date_time: libcron.DateTime) u32 {
        return @as(u32, date_time.year) * 10_000 + @as(u32, date_time.month.numeric()) * 100 + date_time.day;
    }
};

/// The two largest units of a duration, as in `3d 4h`, `2h 5m` or `12m`.
const Delta = struct {
    seconds: i64,

    pub fn format(self: Delta, writer: *Io.Writer) Io.Writer.Error!void {
        const days = @divFloor(self.seconds, std.time.s_per_day);
        const hours = @divFloor(@mod(self.seconds, std.time.s_per_day), std.time.s_per_hour);
        const minutes = @divFloor(@mod(self.seconds, std.time.s_per_hour), std.time.s_per_min);
        if (days > 0) return writer.print("{d}d {d}h", .{ days, hours });
        if (hours > 0) return writer.print("{d}h {d}m", .{ hours, minutes });
        if (minutes > 0) return writer.print("{d}m", .{minutes});
        return writer.print("{d}s", .{self.seconds});
    }
};

fn expectNext(expected: []const u8, schedule: []const u8, now: i64, paused: []const []const u8) !void {
    var discard_buffer: [256]u8 = undefined;
    var discard: Io.Writer = .fixed(&discard_buffer);
    var spec = try JobSpec.init(std.testing.allocator, std.testing.io, null, .{
        .id = "backup",
        .schedule = schedule,
        .action = .{ .command = .{ .argv = &.{"true"} } },
        .time_zone = "Europe/Paris",
    }, "/tmp", &discard);
    defer spec.deinit();
    var text: Io.Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    try writeNext(&text.writer, (&spec)[0..1], 3, now, paused);
    try std.testing.expectEqualStrings(expected, text.written());
}

test "the fall-back day lists a fixed time once" {
    // 2026-10-25T00:00:00+02:00; clocks fall back from 03:00 to 02:00 that night.
    try expectNext(
        "backup\t2026-10-25T02:30:00+02:00\tin 2h 30m\t(paused)\n" ++
            "backup\t2026-10-26T02:30:00+01:00\tin 1d 3h\n" ++
            "backup\t2026-10-27T02:30:00+01:00\tin 2d 3h\n",
        "30 2 * * *",
        1792879200,
        &.{"backup"},
    );
}

test "the spring-forward day runs a skipped time after the gap" {
    // 2026-03-29T00:00:00+01:00; clocks jump from 02:00 to 03:00 that night.
    try expectNext(
        "backup\t2026-03-29T03:00:00+02:00\tin 2h 0m\n" ++
            "backup\t2026-03-30T02:30:00+02:00\tin 1d 1h\n" ++
            "backup\t2026-03-31T02:30:00+02:00\tin 2d 1h\n",
        "30 2 * * *",
        1774738800,
        &.{},
    );
}
