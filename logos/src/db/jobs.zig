const std = @import("std");
const Allocator = std.mem.Allocator;
const Db = @import("db.zig").Db;
const db_mod = @import("db.zig");
const errors = @import("errors.zig");
const test_helpers = @import("test_helpers.zig");
const projects = @import("projects.zig");

pub const JobType = enum {
    slice,
    ocr,
    prompt,

    pub fn toText(self: JobType) []const u8 {
        return switch (self) {
            .slice => "slice",
            .ocr => "ocr",
            .prompt => "prompt",
        };
    }
    pub fn fromText(s: []const u8) !JobType {
        if (std.mem.eql(u8, s, "slice")) return .slice;
        if (std.mem.eql(u8, s, "ocr")) return .ocr;
        if (std.mem.eql(u8, s, "prompt")) return .prompt;
        return error.InvalidJobType;
    }
};

pub const JobStatus = enum {
    queued,
    running,
    completed,
    failed,
    canceled,

    pub fn toText(self: JobStatus) []const u8 {
        return switch (self) {
            .queued => "queued",
            .running => "running",
            .completed => "completed",
            .failed => "failed",
            .canceled => "canceled",
        };
    }
    pub fn fromText(s: []const u8) !JobStatus {
        if (std.mem.eql(u8, s, "queued")) return .queued;
        if (std.mem.eql(u8, s, "running")) return .running;
        if (std.mem.eql(u8, s, "completed")) return .completed;
        if (std.mem.eql(u8, s, "failed")) return .failed;
        if (std.mem.eql(u8, s, "canceled")) return .canceled;
        return error.InvalidJobStatus;
    }
};

pub const Job = struct {
    id: []const u8,
    project_id: []const u8,
    type: JobType,
    status: JobStatus,
    progress: f64,
    payload: []const u8,
    results: ?[]const u8,
    // SQL column is named `error`, but `error` is a Zig keyword, so the
    // struct field is named `error_msg`.
    error_msg: ?[]const u8,
    created_at: []const u8,
    updated_at: []const u8,

    pub fn deinit(self: *Job, gpa: Allocator) void {
        gpa.free(self.id);
        gpa.free(self.project_id);
        gpa.free(self.payload);
        if (self.results) |r| gpa.free(r);
        if (self.error_msg) |e| gpa.free(e);
        gpa.free(self.created_at);
        gpa.free(self.updated_at);
    }
};

pub fn deinitList(list: []Job, gpa: Allocator) void {
    for (list) |*j| j.deinit(gpa);
    gpa.free(list);
}

pub fn insert(db: *Db, gpa: Allocator, job: Job) !void {
    _ = gpa;
    db.conn.exec(
        \\INSERT INTO jobs
        \\  (id, project_id, type, status, progress, payload, results, error,
        \\   created_at, updated_at)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    , .{
        job.id,
        job.project_id,
        job.type.toText(),
        job.status.toText(),
        job.progress,
        job.payload,
        job.results,
        job.error_msg,
        job.created_at,
        job.updated_at,
    }) catch |err| return errors.mapConstraintErr(err);
}

fn rowToJob(row: anytype, gpa: Allocator) !Job {
    const results: ?[]const u8 = if (row.nullableText(6)) |s| try gpa.dupe(u8, s) else null;
    errdefer if (results) |r| gpa.free(r);
    const error_msg: ?[]const u8 = if (row.nullableText(7)) |s| try gpa.dupe(u8, s) else null;
    errdefer if (error_msg) |e| gpa.free(e);

    const id = try gpa.dupe(u8, row.text(0));
    errdefer gpa.free(id);
    const project_id = try gpa.dupe(u8, row.text(1));
    errdefer gpa.free(project_id);
    const payload = try gpa.dupe(u8, row.text(5));
    errdefer gpa.free(payload);
    const created_at = try gpa.dupe(u8, row.text(8));
    errdefer gpa.free(created_at);
    const updated_at = try gpa.dupe(u8, row.text(9));
    errdefer gpa.free(updated_at);

    return .{
        .id = id,
        .project_id = project_id,
        .type = try JobType.fromText(row.text(2)),
        .status = try JobStatus.fromText(row.text(3)),
        .progress = row.float(4),
        .payload = payload,
        .results = results,
        .error_msg = error_msg,
        .created_at = created_at,
        .updated_at = updated_at,
    };
}

pub fn getById(db: *Db, gpa: Allocator, id: []const u8) !?Job {
    const row = (try db.conn.row(
        \\SELECT id, project_id, type, status, progress, payload, results, error,
        \\       created_at, updated_at
        \\FROM jobs WHERE id = ?
    , .{id})) orelse return null;
    defer row.deinit();
    return try rowToJob(row, gpa);
}

fn collectRows(db: *Db, gpa: Allocator, sql: []const u8, args: anytype) ![]Job {
    var list: std.ArrayList(Job) = .empty;
    errdefer {
        for (list.items) |*j| j.deinit(gpa);
        list.deinit(gpa);
    }
    var rows = try db.conn.rows(sql, args);
    defer rows.deinit();
    // zqlite 0.0.1 cursor protocol: `next()` returns `?Row` (not `!?Row`).
    // Errors during iteration are surfaced via `rows.err`, checked after the loop.
    while (rows.next()) |row| {
        var job = try rowToJob(row, gpa);
        errdefer job.deinit(gpa);
        try list.append(gpa, job);
    }
    if (rows.err) |e| return e;
    return list.toOwnedSlice(gpa);
}

pub fn listByProject(db: *Db, gpa: Allocator, project_id: []const u8) ![]Job {
    return collectRows(db, gpa,
        \\SELECT id, project_id, type, status, progress, payload, results, error,
        \\       created_at, updated_at
        \\FROM jobs WHERE project_id = ? ORDER BY created_at ASC
    , .{project_id});
}

pub fn listByStatus(db: *Db, gpa: Allocator, status: JobStatus) ![]Job {
    return collectRows(db, gpa,
        \\SELECT id, project_id, type, status, progress, payload, results, error,
        \\       created_at, updated_at
        \\FROM jobs WHERE status = ? ORDER BY created_at ASC
    , .{status.toText()});
}

pub fn updateProgress(db: *Db, id: []const u8, progress: f64) !void {
    var buf: [128]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const ts = try db_mod.nowIso8601(fba.allocator());
    try db.conn.exec(
        "UPDATE jobs SET progress = ?, updated_at = ? WHERE id = ?",
        .{ progress, ts, id },
    );
    if (db.conn.changes() == 0) return error.NotFound;
}

pub fn markCompleted(db: *Db, id: []const u8, results: []const u8) !void {
    var buf: [128]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const ts = try db_mod.nowIso8601(fba.allocator());
    try db.conn.exec(
        \\UPDATE jobs
        \\SET status = 'completed', progress = 1.0, results = ?, updated_at = ?
        \\WHERE id = ?
    , .{ results, ts, id });
    if (db.conn.changes() == 0) return error.NotFound;
}

pub fn markFailed(db: *Db, id: []const u8, error_msg: []const u8) !void {
    var buf: [128]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const ts = try db_mod.nowIso8601(fba.allocator());
    try db.conn.exec(
        \\UPDATE jobs SET status = 'failed', error = ?, updated_at = ?
        \\WHERE id = ?
    , .{ error_msg, ts, id });
    if (db.conn.changes() == 0) return error.NotFound;
}

pub fn claimNextQueued(db: *Db, gpa: Allocator) !?Job {
    var buf: [128]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const ts = try db_mod.nowIso8601(fba.allocator());

    const row = (try db.conn.row(
        \\UPDATE jobs
        \\SET status = 'running', updated_at = ?
        \\WHERE id = (
        \\  SELECT id FROM jobs WHERE status = 'queued'
        \\  ORDER BY created_at ASC LIMIT 1
        \\)
        \\RETURNING id, project_id, type, status, progress, payload, results, error,
        \\          created_at, updated_at
    , .{ts})) orelse return null;
    defer row.deinit();
    return try rowToJob(row, gpa);
}

fn seedProject(db: *Db, gpa: Allocator, id: []const u8) !void {
    try projects.insert(db, gpa, .{
        .id = id,
        .name = id,
        .description = null,
        .created_at = "2026-05-24T10:00:00Z",
        .last_opened_at = "2026-05-24T10:00:00Z",
        .chargesheet_filename = "src.pdf",
        .chargesheet_page_count = 100,
        .chargesheet_size_bytes = 1024,
    });
}

test "insert + getById round-trips a job" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();
    try seedProject(&db, gpa, "p1");

    try insert(&db, gpa, .{
        .id = "j1",
        .project_id = "p1",
        .type = .slice,
        .status = .queued,
        .progress = 0.0,
        .payload = "{\"start\":1,\"end\":3}",
        .results = null,
        .error_msg = null,
        .created_at = "2026-05-24T10:00:00Z",
        .updated_at = "2026-05-24T10:00:00Z",
    });

    var got = (try getById(&db, gpa, "j1")) orelse return error.TestUnexpectedNull;
    defer got.deinit(gpa);

    try std.testing.expectEqualStrings("j1", got.id);
    try std.testing.expectEqual(JobType.slice, got.type);
    try std.testing.expectEqual(JobStatus.queued, got.status);
    try std.testing.expectEqualStrings("{\"start\":1,\"end\":3}", got.payload);
    try std.testing.expect(got.results == null);
    try std.testing.expect(got.error_msg == null);
}

test "listByProject and listByStatus filter correctly" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();
    try seedProject(&db, gpa, "p1");
    try seedProject(&db, gpa, "p2");

    try insert(&db, gpa, .{
        .id = "j1", .project_id = "p1", .type = .slice, .status = .queued,
        .progress = 0.0, .payload = "{}", .results = null, .error_msg = null,
        .created_at = "2026-05-24T10:00:00Z", .updated_at = "2026-05-24T10:00:00Z",
    });
    try insert(&db, gpa, .{
        .id = "j2", .project_id = "p1", .type = .slice, .status = .completed,
        .progress = 1.0, .payload = "{}", .results = "ok", .error_msg = null,
        .created_at = "2026-05-24T10:00:01Z", .updated_at = "2026-05-24T10:00:01Z",
    });
    try insert(&db, gpa, .{
        .id = "j3", .project_id = "p2", .type = .slice, .status = .queued,
        .progress = 0.0, .payload = "{}", .results = null, .error_msg = null,
        .created_at = "2026-05-24T10:00:02Z", .updated_at = "2026-05-24T10:00:02Z",
    });

    const by_proj = try listByProject(&db, gpa, "p1");
    defer deinitList(by_proj, gpa);
    try std.testing.expectEqual(@as(usize, 2), by_proj.len);

    const by_status = try listByStatus(&db, gpa, .queued);
    defer deinitList(by_status, gpa);
    try std.testing.expectEqual(@as(usize, 2), by_status.len);
}

test "updateProgress writes progress and refreshes updated_at" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();
    try seedProject(&db, gpa, "p1");
    try insert(&db, gpa, .{
        .id = "j1", .project_id = "p1", .type = .slice, .status = .running,
        .progress = 0.0, .payload = "{}", .results = null, .error_msg = null,
        .created_at = "2026-05-24T10:00:00Z", .updated_at = "2026-05-24T10:00:00Z",
    });

    try updateProgress(&db, "j1", 0.5);

    var got = (try getById(&db, gpa, "j1")) orelse return error.TestUnexpectedNull;
    defer got.deinit(gpa);
    try std.testing.expectEqual(@as(f64, 0.5), got.progress);
    try std.testing.expect(!std.mem.eql(u8, got.updated_at, "2026-05-24T10:00:00Z"));
}

test "markCompleted sets status, progress=1, results, updated_at" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();
    try seedProject(&db, gpa, "p1");
    try insert(&db, gpa, .{
        .id = "j1", .project_id = "p1", .type = .slice, .status = .running,
        .progress = 0.5, .payload = "{}", .results = null, .error_msg = null,
        .created_at = "2026-05-24T10:00:00Z", .updated_at = "2026-05-24T10:00:00Z",
    });

    try markCompleted(&db, "j1", "{\"output\":\"ok\"}");

    var got = (try getById(&db, gpa, "j1")) orelse return error.TestUnexpectedNull;
    defer got.deinit(gpa);
    try std.testing.expectEqual(JobStatus.completed, got.status);
    try std.testing.expectEqual(@as(f64, 1.0), got.progress);
    try std.testing.expectEqualStrings("{\"output\":\"ok\"}", got.results.?);
}

test "markFailed sets status, error message, updated_at" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();
    try seedProject(&db, gpa, "p1");
    try insert(&db, gpa, .{
        .id = "j1", .project_id = "p1", .type = .slice, .status = .running,
        .progress = 0.5, .payload = "{}", .results = null, .error_msg = null,
        .created_at = "2026-05-24T10:00:00Z", .updated_at = "2026-05-24T10:00:00Z",
    });

    try markFailed(&db, "j1", "bad input");

    var got = (try getById(&db, gpa, "j1")) orelse return error.TestUnexpectedNull;
    defer got.deinit(gpa);
    try std.testing.expectEqual(JobStatus.failed, got.status);
    try std.testing.expectEqualStrings("bad input", got.error_msg.?);
}

test "updateProgress on missing id returns NotFound" {
    var db = try test_helpers.openTestDb();
    defer db.close();
    try std.testing.expectError(error.NotFound, updateProgress(&db, "ghost", 0.5));
}

test "deleting a project cascades to its jobs" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();
    try seedProject(&db, gpa, "p1");
    try insert(&db, gpa, .{
        .id = "j1", .project_id = "p1", .type = .slice, .status = .queued,
        .progress = 0.0, .payload = "{}", .results = null, .error_msg = null,
        .created_at = "t", .updated_at = "t",
    });

    try projects.delete(&db, "p1");
    const list = try listByProject(&db, gpa, "p1");
    defer deinitList(list, gpa);
    try std.testing.expectEqual(@as(usize, 0), list.len);
}

test "markCompleted on missing id returns NotFound" {
    var db = try test_helpers.openTestDb();
    defer db.close();
    try std.testing.expectError(error.NotFound, markCompleted(&db, "ghost", "{}"));
}

test "markFailed on missing id returns NotFound" {
    var db = try test_helpers.openTestDb();
    defer db.close();
    try std.testing.expectError(error.NotFound, markFailed(&db, "ghost", "fail"));
}

test "claimNextQueued returns oldest queued job and marks it running" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();
    try seedProject(&db, gpa, "p1");

    try insert(&db, gpa, .{
        .id = "j2", .project_id = "p1", .type = .slice, .status = .queued,
        .progress = 0.0, .payload = "{}", .results = null, .error_msg = null,
        .created_at = "2026-05-24T10:00:01Z", .updated_at = "2026-05-24T10:00:01Z",
    });
    try insert(&db, gpa, .{
        .id = "j1", .project_id = "p1", .type = .slice, .status = .queued,
        .progress = 0.0, .payload = "{}", .results = null, .error_msg = null,
        .created_at = "2026-05-24T10:00:00Z", .updated_at = "2026-05-24T10:00:00Z",
    });
    try insert(&db, gpa, .{
        .id = "j3", .project_id = "p1", .type = .slice, .status = .completed,
        .progress = 1.0, .payload = "{}", .results = "x", .error_msg = null,
        .created_at = "2026-05-24T09:00:00Z", .updated_at = "2026-05-24T09:00:00Z",
    });

    var claimed1 = (try claimNextQueued(&db, gpa)) orelse return error.TestUnexpectedNull;
    defer claimed1.deinit(gpa);
    try std.testing.expectEqualStrings("j1", claimed1.id);
    try std.testing.expectEqual(JobStatus.running, claimed1.status);

    var claimed2 = (try claimNextQueued(&db, gpa)) orelse return error.TestUnexpectedNull;
    defer claimed2.deinit(gpa);
    try std.testing.expectEqualStrings("j2", claimed2.id);

    const claimed3 = try claimNextQueued(&db, gpa);
    try std.testing.expect(claimed3 == null);
}

test "claimNextQueued does not return the same job twice" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();
    try seedProject(&db, gpa, "p1");
    try insert(&db, gpa, .{
        .id = "only", .project_id = "p1", .type = .slice, .status = .queued,
        .progress = 0.0, .payload = "{}", .results = null, .error_msg = null,
        .created_at = "t", .updated_at = "t",
    });

    var first = (try claimNextQueued(&db, gpa)) orelse return error.TestUnexpectedNull;
    defer first.deinit(gpa);
    try std.testing.expectEqualStrings("only", first.id);

    const second = try claimNextQueued(&db, gpa);
    try std.testing.expect(second == null);
}

test "insert with unknown project_id returns ForeignKeyViolation" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();

    try std.testing.expectError(error.ForeignKeyViolation, insert(&db, gpa, .{
        .id = "j1", .project_id = "ghost", .type = .slice, .status = .queued,
        .progress = 0.0, .payload = "{}", .results = null, .error_msg = null,
        .created_at = "t", .updated_at = "t",
    }));
}

test "insert with duplicate id returns UniqueViolation" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();
    try seedProject(&db, gpa, "p1");

    try insert(&db, gpa, .{
        .id = "j1", .project_id = "p1", .type = .slice, .status = .queued,
        .progress = 0.0, .payload = "{}", .results = null, .error_msg = null,
        .created_at = "t", .updated_at = "t",
    });
    try std.testing.expectError(error.UniqueViolation, insert(&db, gpa, .{
        .id = "j1", .project_id = "p1", .type = .slice, .status = .queued,
        .progress = 0.0, .payload = "{}", .results = null, .error_msg = null,
        .created_at = "t", .updated_at = "t",
    }));
}

test "insert with progress out of [0,1] returns CheckViolation" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();
    try seedProject(&db, gpa, "p1");

    try std.testing.expectError(error.CheckViolation, insert(&db, gpa, .{
        .id = "j_high", .project_id = "p1", .type = .slice, .status = .queued,
        .progress = 1.5, .payload = "{}", .results = null, .error_msg = null,
        .created_at = "t", .updated_at = "t",
    }));
    try std.testing.expectError(error.CheckViolation, insert(&db, gpa, .{
        .id = "j_low", .project_id = "p1", .type = .slice, .status = .queued,
        .progress = -0.1, .payload = "{}", .results = null, .error_msg = null,
        .created_at = "t", .updated_at = "t",
    }));
}

test "JobType fromText handles ocr and prompt" {
    try std.testing.expectEqual(JobType.ocr, try JobType.fromText("ocr"));
    try std.testing.expectEqual(JobType.prompt, try JobType.fromText("prompt"));
}

test "JobStatus fromText handles canceled" {
    try std.testing.expectEqual(JobStatus.canceled, try JobStatus.fromText("canceled"));
}
