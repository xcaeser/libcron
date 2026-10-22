//! The daemon log: timestamped event lines, and tailing it for `croner logs`.

const std = @import("std");
const Io = std.Io;

/// Writes one line to the daemon log, which is the daemon's stderr.
pub fn logEvent(io: Io, comptime format: []const u8, args: anytype) void {
    const now = Io.Clock.real.now(io);
    const unix_seconds: u64 = @intCast(@divFloor(now.nanoseconds, std.time.ns_per_s));
    std.debug.print("{f} " ++ format ++ "\n", .{UtcTime{ .unix_seconds = unix_seconds }} ++ args);
}

/// ISO-8601 UTC time, for example `2026-10-22T13:37:05Z`.
const UtcTime = struct {
    unix_seconds: u64,

    pub fn format(self: UtcTime, writer: *Io.Writer) Io.Writer.Error!void {
        const epoch: std.time.epoch.EpochSeconds = .{ .secs = self.unix_seconds };
        const year_day = epoch.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day_seconds = epoch.getDaySeconds();
        try writer.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        });
    }
};

pub fn printLog(io: Io, writer: *Io.Writer, path: []const u8, lines: usize) !u64 {
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer file.close(io);
    const size = (try file.stat(io)).size;
    const start = try tailOffset(file, io, size, lines);
    return writeLogRange(file, io, writer, start, size);
}

fn tailOffset(file: Io.File, io: Io, size: u64, lines: usize) !u64 {
    if (lines == 0 or size == 0) return size;
    var buffer: [8192]u8 = undefined;
    var remaining = lines;
    var end = size;
    while (end > 0) {
        const chunk_len: usize = @intCast(@min(end, @as(u64, buffer.len)));
        const start = end - chunk_len;
        const count = try file.readPositionalAll(io, buffer[0..chunk_len], start);
        if (count == 0) return 0;
        var index = count;
        while (index > 0) {
            index -= 1;
            const position = start + index;
            if (position == size - 1 and buffer[index] == '\n') continue;
            if (buffer[index] != '\n') continue;
            remaining -= 1;
            if (remaining == 0) return position + 1;
        }
        end = start;
    }
    return 0;
}

fn writeLogRange(file: Io.File, io: Io, writer: *Io.Writer, start: u64, end: u64) !u64 {
    var buffer: [8192]u8 = undefined;
    var offset = start;
    while (offset < end) {
        const count = try file.readPositionalAll(io, buffer[0..@intCast(@min(end - offset, buffer.len))], offset);
        if (count == 0) break;
        try writer.writeAll(buffer[0..count]);
        offset += count;
    }
    try writer.flush();
    return offset;
}

pub fn appendLog(io: Io, writer: *Io.Writer, path: []const u8, previous_offset: u64) !u64 {
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return previous_offset,
        else => return err,
    };
    defer file.close(io);
    const size = (try file.stat(io)).size;
    const offset = if (size < previous_offset) 0 else previous_offset;
    return writeLogRange(file, io, writer, offset, size);
}

test "log tail selects requested lines" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "log", .data = "a\nb\nc\n" });
    const file = try tmp.dir.openFile(std.testing.io, "log", .{});
    defer file.close(std.testing.io);
    try std.testing.expectEqual(@as(u64, 2), try tailOffset(file, std.testing.io, 6, 2));
}

test "log timestamps are ISO-8601 UTC" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings(
        "2026-10-22T13:37:05Z",
        try std.fmt.bufPrint(&buffer, "{f}", .{UtcTime{ .unix_seconds = 1792676225 }}),
    );
    try std.testing.expectEqualStrings(
        "1970-01-01T00:00:00Z",
        try std.fmt.bufPrint(&buffer, "{f}", .{UtcTime{ .unix_seconds = 0 }}),
    );
}
