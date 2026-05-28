const std = @import("std");
const zqlite = @import("zqlite");

const v1_sql = @embedFile("v1.sql");
const v2_sql = @embedFile("v2.sql");

pub const latest_version: i64 = 2;

pub fn run(conn: zqlite.Conn) !void {
    const current = try currentVersion(conn);
    if (current >= latest_version) return;
    if (current < 1) try applyV1(conn);
    if (current < 2) try applyV2(conn);
    // Future: if (current < 3) try applyV3(conn);
}

fn applyV1(conn: zqlite.Conn) !void {
    try conn.transaction();
    errdefer conn.rollback();
    try conn.execNoArgs(v1_sql);
    try conn.commit();
}

fn applyV2(conn: zqlite.Conn) !void {
    try conn.transaction();
    errdefer conn.rollback();
    try conn.execNoArgs(v2_sql);
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

test "fresh DB migrates to latest_version" {
    const Db = @import("db.zig").Db;
    var db = try Db.open(":memory:");
    defer db.close();

    const row = (try db.conn.row("SELECT MAX(version) FROM schema_version", .{})).?;
    defer row.deinit();
    try std.testing.expectEqual(latest_version, row.int(0));
}

test "v2 creates extractions, prompt_outputs, job_logs tables" {
    const Db = @import("db.zig").Db;
    var db = try Db.open(":memory:");
    defer db.close();

    const expected_tables = [_][]const u8{ "extractions", "prompt_outputs", "job_logs" };
    for (expected_tables) |table| {
        const row = (try db.conn.row(
            "SELECT count(*) FROM sqlite_master WHERE type='table' AND name=?",
            .{table},
        )).?;
        defer row.deinit();
        try std.testing.expectEqual(@as(i64, 1), row.int(0));
    }
}

test "v2 adds slices.kind and slices.kind_key columns" {
    const Db = @import("db.zig").Db;
    var db = try Db.open(":memory:");
    defer db.close();

    var rows = try db.conn.rows("PRAGMA table_info(slices)", .{});
    defer rows.deinit();
    var found_kind = false;
    var found_kind_key = false;
    while (rows.next()) |row| {
        const col_name = row.text(1);
        if (std.mem.eql(u8, col_name, "kind")) found_kind = true;
        if (std.mem.eql(u8, col_name, "kind_key")) found_kind_key = true;
    }
    try std.testing.expect(found_kind);
    try std.testing.expect(found_kind_key);
}

test "v2 expands jobs.type CHECK to include ocr and prompt" {
    const Db = @import("db.zig").Db;
    var db = try Db.open(":memory:");
    defer db.close();

    // Need a project to satisfy the FK
    try db.conn.exec(
        \\INSERT INTO projects (id, name, created_at, last_opened_at,
        \\  chargesheet_filename, chargesheet_page_count, chargesheet_size_bytes)
        \\VALUES ('p1', 'test', '2026-05-28T00:00:00Z', '2026-05-28T00:00:00Z', 'c.pdf', 1, 1)
    , .{});

    // Each of these should succeed
    inline for (.{ "slice", "ocr", "prompt" }) |t| {
        try db.conn.exec(
            \\INSERT INTO jobs (id, project_id, type, status, payload, created_at, updated_at)
            \\VALUES (?, 'p1', ?, 'queued', '{}', '2026-05-28T00:00:00Z', '2026-05-28T00:00:00Z')
        , .{ "j_" ++ t, t });
    }

    // And a bogus type should fail
    const result = db.conn.exec(
        \\INSERT INTO jobs (id, project_id, type, status, payload, created_at, updated_at)
        \\VALUES ('jbogus', 'p1', 'bogus', 'queued', '{}', '2026-05-28T00:00:00Z', '2026-05-28T00:00:00Z')
    , .{});
    try std.testing.expectError(error.ConstraintCheck, result);
}
