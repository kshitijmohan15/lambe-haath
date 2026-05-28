const std = @import("std");
const Db = @import("db.zig").Db;
const migrations = @import("migrations.zig");

/// Open a fresh in-memory database with foreign keys enabled and the
/// latest schema applied. Caller is responsible for `db.close()`.
pub fn openTestDb() !Db {
    return Db.open(":memory:");
}

/// Insert a minimal project row for use in tests that need a valid project_id FK.
pub fn insertProject(db: *Db, id: []const u8) !void {
    try db.conn.exec(
        \\INSERT INTO projects (id, name, created_at, last_opened_at,
        \\  chargesheet_filename, chargesheet_page_count, chargesheet_size_bytes)
        \\VALUES (?, ?, '2026-05-28T00:00:00Z', '2026-05-28T00:00:00Z', 'c.pdf', 1, 1)
    , .{ id, id });
}

test "openTestDb yields a database with foreign_keys ON" {
    var db = try openTestDb();
    defer db.close();

    const row = try db.conn.row("PRAGMA foreign_keys", .{});
    try std.testing.expect(row != null);
    defer row.?.deinit();
    try std.testing.expectEqual(@as(i64, 1), row.?.int(0));
}

test "openTestDb applies latest schema" {
    var db = try openTestDb();
    defer db.close();

    const row = try db.conn.row("SELECT MAX(version) FROM schema_version", .{});
    try std.testing.expect(row != null);
    defer row.?.deinit();
    try std.testing.expectEqual(migrations.latest_version, row.?.int(0));
}
