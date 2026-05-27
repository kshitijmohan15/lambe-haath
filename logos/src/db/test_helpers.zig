const std = @import("std");
const Db = @import("db.zig").Db;

/// Open a fresh in-memory database with foreign keys enabled and the
/// latest schema applied. Caller is responsible for `db.close()`.
pub fn openTestDb() !Db {
    return Db.open(":memory:");
}

test "openTestDb yields a database with foreign_keys ON" {
    var db = try openTestDb();
    defer db.close();

    const row = try db.conn.row("PRAGMA foreign_keys", .{});
    try std.testing.expect(row != null);
    defer row.?.deinit();
    try std.testing.expectEqual(@as(i64, 1), row.?.int(0));
}

test "openTestDb applies schema v1" {
    var db = try openTestDb();
    defer db.close();

    const row = try db.conn.row("SELECT MAX(version) FROM schema_version", .{});
    try std.testing.expect(row != null);
    defer row.?.deinit();
    try std.testing.expectEqual(@as(i64, 1), row.?.int(0));
}
