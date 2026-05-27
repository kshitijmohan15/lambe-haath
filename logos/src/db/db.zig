const std = @import("std");
const builtin = @import("builtin");
const zqlite = @import("zqlite");
const migrations = @import("migrations.zig");

pub const Db = struct {
    conn: zqlite.Conn,

    pub fn open(path: [*:0]const u8) !Db {
        const conn = try zqlite.open(
            path,
            zqlite.OpenFlags.Create | zqlite.OpenFlags.ReadWrite | zqlite.OpenFlags.EXResCode,
        );
        errdefer conn.close();

        try conn.execNoArgs(
            \\PRAGMA journal_mode = WAL;
            \\PRAGMA foreign_keys = ON;
            \\PRAGMA synchronous = NORMAL;
            \\PRAGMA busy_timeout = 5000;
        );
        try migrations.run(conn);
        return .{ .conn = conn };
    }

    pub fn close(self: *Db) void {
        self.conn.close();
    }
};

/// Current wall-clock time as seconds since the Unix epoch.
///
/// Cross-platform without an `std.Io` handle: `std.c.clock_gettime` is POSIX-
/// only and its extern declaration fails to compile for Windows targets (the
/// `void`-param + winapi calling-convention combination), so we branch at
/// comptime and never reference that symbol on Windows. On Windows we read the
/// system clock via `ntdll.RtlGetSystemTimePrecise`, which returns 100-ns
/// intervals since 1601-01-01, and translate to the Unix epoch.
fn nowUnixSeconds() i64 {
    if (builtin.os.tag == .windows) {
        const win = std.os.windows;
        // 100-ns ticks since 1601-01-01T00:00:00Z.
        const ticks: i64 = win.ntdll.RtlGetSystemTimePrecise();
        // Seconds between 1601-01-01 and 1970-01-01 (the Unix epoch).
        const epoch_diff_secs: i64 = 11_644_473_600;
        return @divTrunc(ticks, 10_000_000) - epoch_diff_secs;
    } else {
        var ts: std.c.timespec = undefined;
        // Best-effort; REALTIME is supported on all our POSIX targets.
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        return @intCast(ts.sec);
    }
}

/// Allocate and return an ISO-8601 UTC timestamp string of the current time.
/// Caller owns the returned slice.
pub fn nowIso8601(gpa: std.mem.Allocator) ![]u8 {
    const ts_secs: i64 = nowUnixSeconds();
    const epoch_secs: std.time.epoch.EpochSeconds = .{ .secs = @intCast(ts_secs) };
    const epoch_day = epoch_secs.getEpochDay();
    const day_secs = epoch_secs.getDaySeconds();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.allocPrint(
        gpa,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        .{
            @as(u16, year_day.year),
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_secs.getHoursIntoDay(),
            day_secs.getMinutesIntoHour(),
            day_secs.getSecondsIntoMinute(),
        },
    );
}

test {
    _ = @import("test_helpers.zig");
}

test "nowIso8601 returns a 20-char Z-suffixed string" {
    const gpa = std.testing.allocator;
    const ts = try nowIso8601(gpa);
    defer gpa.free(ts);
    try std.testing.expectEqual(@as(usize, 20), ts.len);
    try std.testing.expectEqual(@as(u8, 'Z'), ts[19]);
    try std.testing.expectEqual(@as(u8, 'T'), ts[10]);
}

test "nowIso8601 format is parseable and in plausible range" {
    const gpa = std.testing.allocator;
    const ts = try nowIso8601(gpa);
    defer gpa.free(ts);

    const year  = try std.fmt.parseInt(u16, ts[0..4],   10);
    const month = try std.fmt.parseInt(u8,  ts[5..7],   10);
    const day   = try std.fmt.parseInt(u8,  ts[8..10],  10);
    const hour  = try std.fmt.parseInt(u8,  ts[11..13], 10);
    const min   = try std.fmt.parseInt(u8,  ts[14..16], 10);
    const sec   = try std.fmt.parseInt(u8,  ts[17..19], 10);

    try std.testing.expect(year  >= 2025 and year  <= 2100);
    try std.testing.expect(month >= 1    and month <= 12);
    try std.testing.expect(day   >= 1    and day   <= 31);
    try std.testing.expect(hour  <= 23);
    try std.testing.expect(min   <= 59);
    try std.testing.expect(sec   <= 60);
    try std.testing.expectEqual(@as(u8, '-'), ts[4]);
    try std.testing.expectEqual(@as(u8, '-'), ts[7]);
    try std.testing.expectEqual(@as(u8, ':'), ts[13]);
    try std.testing.expectEqual(@as(u8, ':'), ts[16]);
}
