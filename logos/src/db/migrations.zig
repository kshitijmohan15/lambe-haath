const std = @import("std");
const zqlite = @import("zqlite");

const v1_sql = @embedFile("v1.sql");

pub const latest_version: i64 = 1;

pub fn run(conn: zqlite.Conn) !void {
    const current = try currentVersion(conn);
    if (current >= latest_version) return;
    if (current < 1) try applyV1(conn);
    // Future: if (current < 2) try applyV2(conn);
}

fn applyV1(conn: zqlite.Conn) !void {
    try conn.transaction();
    errdefer conn.rollback();
    try conn.execNoArgs(v1_sql);
    try conn.commit();
}

fn currentVersion(conn: zqlite.Conn) !i64 {
    if (try conn.row(
        "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='schema_version'",
        .{},
    )) |r| {
        defer r.deinit();
        if (r.int(0) == 0) return 0;
    } else return 0;

    if (try conn.row("SELECT MAX(version) FROM schema_version", .{})) |r| {
        defer r.deinit();
        return r.int(0);
    }
    return 0;
}
