const std = @import("std");
const Allocator = std.mem.Allocator;
const Db = @import("db.zig").Db;
const errors = @import("errors.zig");
const test_helpers = @import("test_helpers.zig");

pub const Level = enum {
    debug,
    info,
    warning,
    @"error",

    pub fn toText(self: Level) []const u8 {
        return switch (self) {
            .debug => "debug",
            .info => "info",
            .warning => "warning",
            .@"error" => "error",
        };
    }

    pub fn fromText(s: []const u8) ?Level {
        if (std.mem.eql(u8, s, "debug")) return .debug;
        if (std.mem.eql(u8, s, "info")) return .info;
        if (std.mem.eql(u8, s, "warning")) return .warning;
        if (std.mem.eql(u8, s, "error")) return .@"error";
        return null;
    }
};

pub const JobLog = struct {
    id: i64,
    job_id: []const u8,
    ts: []const u8,
    level: Level,
    logger: []const u8,
    message: []const u8,

    pub fn deinit(self: *JobLog, gpa: Allocator) void {
        gpa.free(self.job_id);
        gpa.free(self.ts);
        gpa.free(self.logger);
        gpa.free(self.message);
    }
};

pub fn deinitList(list: []JobLog, gpa: Allocator) void {
    for (list) |*l| l.deinit(gpa);
    gpa.free(list);
}

pub fn insert(
    db: *Db,
    job_id: []const u8,
    ts: []const u8,
    level: Level,
    logger: []const u8,
    message: []const u8,
) !void {
    db.conn.exec(
        \\INSERT INTO job_logs (job_id, ts, level, logger, message)
        \\VALUES (?, ?, ?, ?, ?)
    , .{
        job_id,
        ts,
        level.toText(),
        logger,
        message,
    }) catch |err| return errors.mapConstraintErr(err);
}

pub fn listByJob(db: *Db, gpa: Allocator, job_id: []const u8) ![]JobLog {
    var list: std.ArrayList(JobLog) = .empty;
    errdefer {
        for (list.items) |*l| l.deinit(gpa);
        list.deinit(gpa);
    }
    var rows = try db.conn.rows(
        \\SELECT id, job_id, ts, level, logger, message
        \\FROM job_logs WHERE job_id = ? ORDER BY id ASC
    , .{job_id});
    defer rows.deinit();
    while (rows.next()) |row| {
        const jid = try gpa.dupe(u8, row.text(1));
        errdefer gpa.free(jid);
        const ts = try gpa.dupe(u8, row.text(2));
        errdefer gpa.free(ts);
        const level = Level.fromText(row.text(3)) orelse return error.InvalidLogLevel;
        const logger = try gpa.dupe(u8, row.text(4));
        errdefer gpa.free(logger);
        const message = try gpa.dupe(u8, row.text(5));
        errdefer gpa.free(message);

        try list.append(gpa, .{
            .id = row.int(0),
            .job_id = jid,
            .ts = ts,
            .level = level,
            .logger = logger,
            .message = message,
        });
    }
    if (rows.err) |e| return e;
    return try list.toOwnedSlice(gpa);
}

test "insert + listByJob preserves insertion order" {
    var db = try Db.open(":memory:");
    defer db.close();
    const gpa = std.testing.allocator;
    try test_helpers.insertProject(&db, "p1");
    try test_helpers.insertJob(&db, "j1", "p1", "ocr");

    try insert(&db, "j1", "2026-05-28T00:00:01Z", .info, "ocr_agent", "Processing slice");
    try insert(&db, "j1", "2026-05-28T00:00:02Z", .info, "ocr_agent", "Uploaded to Gemini");
    try insert(&db, "j1", "2026-05-28T00:00:03Z", .warning, "ocr_agent", "Slow response");

    const logs = try listByJob(&db, gpa, "j1");
    defer deinitList(logs, gpa);

    try std.testing.expectEqual(@as(usize, 3), logs.len);
    try std.testing.expectEqualStrings("Processing slice", logs[0].message);
    try std.testing.expectEqual(Level.warning, logs[2].level);
}

test "deleting a job cascades to job_logs" {
    var db = try Db.open(":memory:");
    defer db.close();
    const gpa = std.testing.allocator;
    try test_helpers.insertProject(&db, "p1");
    try test_helpers.insertJob(&db, "j1", "p1", "ocr");

    try insert(&db, "j1", "2026-05-28T00:00:01Z", .info, "ocr_agent", "hello");

    // Pre-delete existence check so the cascade assertion is meaningful
    {
        const pre = try listByJob(&db, gpa, "j1");
        defer deinitList(pre, gpa);
        try std.testing.expectEqual(@as(usize, 1), pre.len);
    }

    try db.conn.exec("DELETE FROM jobs WHERE id=?", .{"j1"});

    const logs = try listByJob(&db, gpa, "j1");
    defer deinitList(logs, gpa);
    try std.testing.expectEqual(@as(usize, 0), logs.len);
}

test "rejects invalid level via CHECK constraint" {
    var db = try Db.open(":memory:");
    defer db.close();
    try test_helpers.insertProject(&db, "p1");
    try test_helpers.insertJob(&db, "j1", "p1", "ocr");

    const result = db.conn.exec(
        \\INSERT INTO job_logs (job_id, ts, level, logger, message)
        \\VALUES (?, ?, ?, ?, ?)
    , .{ "j1", "2026-05-28T00:00:01Z", "critical", "x", "y" });

    try std.testing.expectError(error.ConstraintCheck, result);
}
