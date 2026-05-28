//! Handler functions for OCR job enqueue and extraction retrieval endpoints.
//!
//! Four endpoints:
//!   POST /api/v1/projects/:id/jobs/ocr          → enqueue one OCR job
//!   POST /api/v1/projects/:id/jobs/ocr/all      → enqueue OCR for all unextracted slices
//!   GET  /api/v1/projects/:id/extractions        → list extraction rows
//!   GET  /api/v1/projects/:id/extractions/:file  → download .md file contents

const std = @import("std");
const Allocator = std.mem.Allocator;
const Db = @import("../db/db.zig").Db;
const db_mod = @import("../db/db.zig");
const jobs_mod = @import("../db/jobs.zig");
const slices_mod = @import("../db/slices.zig");
const extractions_mod = @import("../db/extractions.zig");
const projects_mod = @import("../db/projects.zig");
const ids = @import("../ids.zig");
const test_helpers = @import("../db/test_helpers.zig");

// ---------------------------------------------------------------------------
// POST /api/v1/projects/:id/jobs/ocr
// ---------------------------------------------------------------------------

const OcrRequestBody = struct {
    slice_filename: []const u8,
};

pub const EnqueueOcrError = error{
    InvalidRequest,
    ProjectNotFound,
    SliceNotFound,
    OutOfMemory,
    DbError,
};

/// Result of POST /jobs/ocr. Caller owns `job_id`.
pub const EnqueueOcrResult = struct {
    job_id: []u8,

    pub fn deinit(self: EnqueueOcrResult, gpa: Allocator) void {
        gpa.free(self.job_id);
    }
};

/// Handle POST /api/v1/projects/:id/jobs/ocr.
/// Body: `{"slice_filename":"annexure-i.pdf"}`.
/// Returns 201 `{job_id}`, or error mapping:
///   InvalidRequest → 400, ProjectNotFound → 404, SliceNotFound → 404.
pub fn handleEnqueueOcr(
    io: std.Io,
    gpa: Allocator,
    db: *Db,
    project_id: []const u8,
    body: []const u8,
) EnqueueOcrError!EnqueueOcrResult {
    // 1. Confirm project exists.
    const maybe_project = projects_mod.getById(db, gpa, project_id) catch return error.DbError;
    if (maybe_project == null) return error.ProjectNotFound;
    var project = maybe_project.?;
    project.deinit(gpa);

    // 2. Parse body.
    const parsed = std.json.parseFromSlice(OcrRequestBody, gpa, body, .{}) catch return error.InvalidRequest;
    defer parsed.deinit();
    const slice_filename = parsed.value.slice_filename;
    if (slice_filename.len == 0) return error.InvalidRequest;

    // 3. Verify slice exists.
    const maybe_slice = slices_mod.getByKey(db, gpa, project_id, slice_filename) catch return error.DbError;
    if (maybe_slice == null) return error.SliceNotFound;
    var slice = maybe_slice.?;
    slice.deinit(gpa);

    // 4. Generate job id.
    const job_id = ids.generateJobId(io, gpa) catch return error.OutOfMemory;
    errdefer gpa.free(job_id);

    // 5. Build payload JSON: {"slice_filename":"<name>"}.
    var payload_buf: [512]u8 = undefined;
    var pw = std.Io.Writer.fixed(&payload_buf);
    pw.writeAll("{\"slice_filename\":") catch return error.OutOfMemory;
    writeJsonStringFixed(&pw, slice_filename) catch return error.OutOfMemory;
    pw.writeAll("}") catch return error.OutOfMemory;
    const payload_raw = pw.buffered();

    const now = db_mod.nowIso8601(gpa) catch return error.OutOfMemory;
    defer gpa.free(now);

    const project_id_dup = gpa.dupe(u8, project_id) catch return error.OutOfMemory;
    defer gpa.free(project_id_dup);
    const payload_dup = gpa.dupe(u8, payload_raw) catch return error.OutOfMemory;
    defer gpa.free(payload_dup);
    const now_dup = gpa.dupe(u8, now) catch return error.OutOfMemory;
    defer gpa.free(now_dup);

    // 6. Insert job row.
    const job_row: jobs_mod.Job = .{
        .id = job_id,
        .project_id = project_id_dup,
        .type = .ocr,
        .status = .queued,
        .progress = 0.0,
        .payload = payload_dup,
        .results = null,
        .error_msg = null,
        .created_at = now,
        .updated_at = now_dup,
    };

    jobs_mod.insert(db, gpa, job_row) catch return error.DbError;

    return .{ .job_id = job_id };
}

// ---------------------------------------------------------------------------
// POST /api/v1/projects/:id/jobs/ocr/all
// ---------------------------------------------------------------------------

pub const EnqueueOcrAllError = error{
    ProjectNotFound,
    OutOfMemory,
    DbError,
};

/// Result of POST /jobs/ocr/all. Caller owns the `job_ids` slice and each string.
pub const EnqueueOcrAllResult = struct {
    job_ids: [][]u8,

    pub fn deinit(self: EnqueueOcrAllResult, gpa: Allocator) void {
        for (self.job_ids) |jid| gpa.free(jid);
        gpa.free(self.job_ids);
    }
};

/// Handle POST /api/v1/projects/:id/jobs/ocr/all.
/// Enqueues an OCR job for every slice that does not already have an extraction row.
/// Returns an array of job_ids (may be empty if all slices are already extracted).
pub fn handleEnqueueOcrAll(
    io: std.Io,
    gpa: Allocator,
    db: *Db,
    project_id: []const u8,
) EnqueueOcrAllError!EnqueueOcrAllResult {
    // 1. Confirm project exists.
    const maybe_project = projects_mod.getById(db, gpa, project_id) catch return error.DbError;
    if (maybe_project == null) return error.ProjectNotFound;
    var project = maybe_project.?;
    project.deinit(gpa);

    // 2. Collect slices that have no extraction row yet.
    //    We use a raw SQL query with LEFT JOIN to avoid N+1.
    var unextracted: std.ArrayList([]u8) = .empty;
    defer {
        for (unextracted.items) |s| gpa.free(s);
        unextracted.deinit(gpa);
    }

    var rows = db.conn.rows(
        \\SELECT s.filename FROM slices s
        \\LEFT JOIN extractions e
        \\  ON e.project_id = s.project_id AND e.slice_filename = s.filename
        \\WHERE s.project_id = ? AND e.slice_filename IS NULL
        \\ORDER BY s.filename ASC
    , .{project_id}) catch return error.DbError;
    defer rows.deinit();

    while (rows.next()) |row| {
        const fname = gpa.dupe(u8, row.text(0)) catch return error.OutOfMemory;
        unextracted.append(gpa, fname) catch {
            gpa.free(fname);
            return error.OutOfMemory;
        };
    }
    if (rows.err) |_| return error.DbError;

    // 3. For each unextracted slice, insert an OCR job.
    var job_ids: std.ArrayList([]u8) = .empty;
    errdefer {
        for (job_ids.items) |jid| gpa.free(jid);
        job_ids.deinit(gpa);
    }

    const now = db_mod.nowIso8601(gpa) catch return error.OutOfMemory;
    defer gpa.free(now);

    const project_id_dup = gpa.dupe(u8, project_id) catch return error.OutOfMemory;
    defer gpa.free(project_id_dup);

    for (unextracted.items) |slice_filename| {
        const job_id = ids.generateJobId(io, gpa) catch return error.OutOfMemory;
        errdefer gpa.free(job_id);

        var payload_buf: [512]u8 = undefined;
        var pw = std.Io.Writer.fixed(&payload_buf);
        pw.writeAll("{\"slice_filename\":") catch return error.OutOfMemory;
        writeJsonStringFixed(&pw, slice_filename) catch return error.OutOfMemory;
        pw.writeAll("}") catch return error.OutOfMemory;
        const payload_raw = pw.buffered();

        const payload_dup = gpa.dupe(u8, payload_raw) catch return error.OutOfMemory;
        defer gpa.free(payload_dup);
        const now_dup = gpa.dupe(u8, now) catch return error.OutOfMemory;
        defer gpa.free(now_dup);
        const now_dup2 = gpa.dupe(u8, now) catch return error.OutOfMemory;
        defer gpa.free(now_dup2);

        const job_row: jobs_mod.Job = .{
            .id = job_id,
            .project_id = project_id_dup,
            .type = .ocr,
            .status = .queued,
            .progress = 0.0,
            .payload = payload_dup,
            .results = null,
            .error_msg = null,
            .created_at = now_dup,
            .updated_at = now_dup2,
        };

        jobs_mod.insert(db, gpa, job_row) catch return error.DbError;

        job_ids.append(gpa, job_id) catch return error.OutOfMemory;
    }

    return .{ .job_ids = try job_ids.toOwnedSlice(gpa) };
}

// ---------------------------------------------------------------------------
// GET /api/v1/projects/:id/extractions
// ---------------------------------------------------------------------------

pub const ListExtractionsError = error{ ProjectNotFound, DbError, OutOfMemory };

/// Handle GET /api/v1/projects/:id/extractions.
/// Returns an owned slice of Extraction rows (caller must call `extractions_mod.deinitList`).
pub fn handleListExtractions(
    gpa: Allocator,
    db: *Db,
    project_id: []const u8,
) ListExtractionsError![]extractions_mod.Extraction {
    const maybe_project = projects_mod.getById(db, gpa, project_id) catch return error.DbError;
    if (maybe_project == null) return error.ProjectNotFound;
    var project = maybe_project.?;
    project.deinit(gpa);

    return extractions_mod.listByProject(db, gpa, project_id) catch return error.DbError;
}

// ---------------------------------------------------------------------------
// GET /api/v1/projects/:id/extractions/:slice_filename
// ---------------------------------------------------------------------------

pub const GetExtractionError = error{
    ProjectNotFound,
    ExtractionNotFound,
    IoError,
    OutOfMemory,
    DbError,
};

/// Result of GET /extractions/:filename. Caller owns `markdown_bytes`.
pub const ExtractionMarkdownResult = struct {
    markdown_bytes: []u8,

    pub fn deinit(self: ExtractionMarkdownResult, gpa: Allocator) void {
        gpa.free(self.markdown_bytes);
    }
};

const max_markdown_bytes: usize = 10 * 1024 * 1024; // 10 MiB

/// Handle GET /api/v1/projects/:id/extractions/:slice_filename.
/// Reads the .md file from the path stored in the extraction row.
pub fn handleGetExtractionMarkdown(
    io: std.Io,
    gpa: Allocator,
    db: *Db,
    project_id: []const u8,
    slice_filename: []const u8,
) GetExtractionError!ExtractionMarkdownResult {
    // 1. Confirm project exists.
    const maybe_project = projects_mod.getById(db, gpa, project_id) catch return error.DbError;
    if (maybe_project == null) return error.ProjectNotFound;
    var project = maybe_project.?;
    project.deinit(gpa);

    // 2. Look up extraction row.
    const maybe_extraction = extractions_mod.getByKey(db, gpa, project_id, slice_filename) catch return error.DbError;
    if (maybe_extraction == null) return error.ExtractionNotFound;
    var extraction = maybe_extraction.?;
    defer extraction.deinit(gpa);

    // 3. Read .md file from disk.
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, extraction.markdown_path, gpa, .limited(max_markdown_bytes)) catch |err| switch (err) {
        error.FileNotFound => return error.ExtractionNotFound,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.IoError,
    };

    return .{ .markdown_bytes = bytes };
}

// ---------------------------------------------------------------------------
// Internal: minimal JSON string writer for fixed buffers (no allocator needed)
// ---------------------------------------------------------------------------

fn writeJsonStringFixed(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeAll("\"");
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0...0x08, 0x0B, 0x0C, 0x0E...0x1F => try w.print("\\u{x:0>4}", .{c}),
            else => try w.writeByte(c),
        }
    }
    try w.writeAll("\"");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "postEnqueueOcr 400 on missing slice_filename" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();

    try test_helpers.insertProject(&db, "p1");

    // Body with missing slice_filename key → parse error → InvalidRequest
    const err = handleEnqueueOcr(std.testing.io, gpa, &db, "p1", "{\"wrong_key\":\"foo.pdf\"}");
    try std.testing.expectError(error.InvalidRequest, err);
}

test "postEnqueueOcr 404 on unknown slice" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();

    try test_helpers.insertProject(&db, "p1");
    // No slice inserted — should return SliceNotFound.
    const err = handleEnqueueOcr(std.testing.io, gpa, &db, "p1", "{\"slice_filename\":\"ghost.pdf\"}");
    try std.testing.expectError(error.SliceNotFound, err);
}

test "postEnqueueOcr 201 with job_id on success" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();

    try test_helpers.insertProject(&db, "p1");
    // Insert a slice directly so the FK is satisfied.
    try db.conn.exec(
        \\INSERT INTO slices (project_id, filename, start_page, end_page, size_bytes, created_at)
        \\VALUES ('p1', 'annexure-i.pdf', 1, 5, 1024, '2026-05-28T00:00:00Z')
    , .{});

    const result = try handleEnqueueOcr(std.testing.io, gpa, &db, "p1", "{\"slice_filename\":\"annexure-i.pdf\"}");
    defer result.deinit(gpa);

    // job_id must be non-empty and start with "job_"
    try std.testing.expect(result.job_id.len > 0);
    try std.testing.expectEqualStrings("job_", result.job_id[0..4]);

    // Verify row was actually inserted in DB.
    const row = (try db.conn.row("SELECT type, status FROM jobs WHERE id = ?", .{result.job_id})).?;
    defer row.deinit();
    try std.testing.expectEqualStrings("ocr", row.text(0));
    try std.testing.expectEqualStrings("queued", row.text(1));
}
