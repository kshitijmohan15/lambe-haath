//! Per-endpoint handler functions. Each takes the resources it needs
//! (allocator, *Db, etc.) and writes a JSON response body via a Writer.

const std = @import("std");
const mupdf = @import("mupdf");
const Db = @import("../db/db.zig").Db;
const projects_mod = @import("../db/projects.zig");
const jobs_mod = @import("../db/jobs.zig");
const slices_mod = @import("../db/slices.zig");
const json_mod = @import("json.zig");
const ids = @import("../ids.zig");
const project_dir = @import("../storage/project_dir.zig");
const multipart = @import("multipart.zig");
const db_mod = @import("../db/db.zig");
const errors_mod = @import("../db/errors.zig");

pub const CreateError = error{
    InvalidRequest,
    InvalidName,
    InvalidDescription,
    InvalidPdf,
    NameConflict,
    OutOfMemory,
    DbError,
    PdfError,
    IoError,
};

/// Handle GET /api/v1/projects — list all projects, ordered by last_opened_at DESC.
/// Writes the JSON body via the writer. Caller has already set HTTP status + headers.
pub fn handleProjectsList(gpa: std.mem.Allocator, db: *Db, w: *std.Io.Writer) !void {
    const list = try projects_mod.listAll(db, gpa);
    defer projects_mod.deinitList(list, gpa);

    try json_mod.writeProjectArrayOpen(w);
    for (list, 0..) |project, i| {
        if (i > 0) try w.writeAll(",");
        try json_mod.writeProject(w, project);
    }
    try json_mod.writeProjectArrayClose(w);
}

/// Handle POST /api/v1/projects — parse multipart, validate, write PDF to disk,
/// count pages via mupdf, insert into DB. Returns the created Project (caller
/// serializes and deinits via Project.deinit).
///
/// All transient resources (multipart fields, temp paths, mupdf doc) are cleaned
/// up before returning. On any error past directory creation, the on-disk tree
/// is removed via errdefer.
pub fn handleProjectsCreate(
    io: std.Io,
    gpa: std.mem.Allocator,
    db: *Db,
    data_dir: []const u8,
    mupdf_ctx: *mupdf.Context,
    boundary: []const u8,
    body: []const u8,
) CreateError!projects_mod.Project {
    const fields = multipart.parse(gpa, boundary, body) catch return error.InvalidRequest;
    defer gpa.free(fields);

    var name_in: ?[]const u8 = null;
    var description_in: ?[]const u8 = null;
    var chargesheet_bytes: ?[]const u8 = null;
    var chargesheet_filename_in: ?[]const u8 = null;

    for (fields) |f| {
        if (std.mem.eql(u8, f.name, "name")) {
            name_in = f.body;
        } else if (std.mem.eql(u8, f.name, "description")) {
            description_in = f.body;
        } else if (std.mem.eql(u8, f.name, "chargesheet")) {
            chargesheet_bytes = f.body;
            chargesheet_filename_in = f.filename;
        }
    }

    const name_raw = name_in orelse return error.InvalidName;
    const name_trimmed = std.mem.trim(u8, name_raw, " \t\r\n");
    if (name_trimmed.len == 0 or name_trimmed.len > 200) return error.InvalidName;
    if (description_in) |d| {
        if (d.len > 2000) return error.InvalidDescription;
    }
    if (chargesheet_bytes == null or chargesheet_bytes.?.len == 0) return error.InvalidPdf;

    // Treat description="" as null for storage.
    const description_use: ?[]const u8 = blk: {
        if (description_in) |d| {
            if (d.len == 0) break :blk null;
            break :blk d;
        }
        break :blk null;
    };

    if (projects_mod.existsByName(db, name_trimmed) catch return error.DbError) return error.NameConflict;

    const id = ids.generateProjectId(io, gpa) catch return error.OutOfMemory;
    errdefer gpa.free(id);

    project_dir.createProjectTree(io, data_dir, id, gpa) catch return error.IoError;
    errdefer project_dir.removeProjectTree(io, data_dir, id, gpa) catch {};

    project_dir.writeChargesheet(io, data_dir, id, chargesheet_bytes.?, gpa) catch return error.IoError;

    // Open the just-written PDF via mupdf-zig, count pages.
    const path = project_dir.chargesheetPath(gpa, data_dir, id) catch return error.OutOfMemory;
    defer gpa.free(path);
    const path_z = gpa.dupeZ(u8, path) catch return error.OutOfMemory;
    defer gpa.free(path_z);

    var doc = mupdf.Document.open(mupdf_ctx, path_z) catch return error.InvalidPdf;
    defer doc.deinit();
    const page_count = doc.pageCount() catch return error.PdfError;

    const now = db_mod.nowIso8601(gpa) catch return error.OutOfMemory;
    defer gpa.free(now);

    const filename = if (chargesheet_filename_in) |f| f else "chargesheet.pdf";

    // Allocate Project owned strings (matching Project's "owns its strings" contract).
    const name_owned = gpa.dupe(u8, name_trimmed) catch return error.OutOfMemory;
    errdefer gpa.free(name_owned);
    const description_owned: ?[]const u8 = if (description_use) |d|
        (gpa.dupe(u8, d) catch return error.OutOfMemory)
    else
        null;
    errdefer if (description_owned) |d| gpa.free(d);
    const created_owned = gpa.dupe(u8, now) catch return error.OutOfMemory;
    errdefer gpa.free(created_owned);
    const opened_owned = gpa.dupe(u8, now) catch return error.OutOfMemory;
    errdefer gpa.free(opened_owned);
    const filename_owned = gpa.dupe(u8, filename) catch return error.OutOfMemory;
    errdefer gpa.free(filename_owned);

    const row: projects_mod.Project = .{
        .id = id,
        .name = name_owned,
        .description = description_owned,
        .created_at = created_owned,
        .last_opened_at = opened_owned,
        .chargesheet_filename = filename_owned,
        .chargesheet_page_count = page_count,
        .chargesheet_size_bytes = chargesheet_bytes.?.len,
    };

    projects_mod.insert(db, gpa, row) catch |err| switch (err) {
        error.UniqueViolation => return error.NameConflict,
        else => return error.DbError,
    };

    return row;
}

pub const GetError = error{
    NotFound,
    OutOfMemory,
    DbError,
};

/// Handle GET /api/v1/projects/:id — fetch project, touch last_opened_at,
/// return the refreshed Project. Caller owns the returned Project (must deinit).
pub fn handleProjectsGet(
    gpa: std.mem.Allocator,
    db: *Db,
    id: []const u8,
) GetError!projects_mod.Project {
    const maybe = projects_mod.getById(db, gpa, id) catch return error.DbError;
    if (maybe == null) return error.NotFound;
    var project = maybe.?;
    // Free the first read; we'll re-read after touching.
    project.deinit(gpa);

    projects_mod.touchLastOpened(db, id) catch return error.DbError;

    const refreshed = projects_mod.getById(db, gpa, id) catch return error.DbError;
    return refreshed orelse error.NotFound;
}

pub const DeleteError = error{
    NotFound,
    DbError,
    IoError,
};

/// Handle DELETE /api/v1/projects/:id — remove DB row (cascades to slices/jobs
/// via FK ON DELETE CASCADE) and remove the project directory tree.
pub fn handleProjectsDelete(
    io: std.Io,
    gpa: std.mem.Allocator,
    db: *Db,
    data_dir: []const u8,
    id: []const u8,
) DeleteError!void {
    projects_mod.delete(db, id) catch |err| switch (err) {
        error.NotFound => return error.NotFound,
        else => return error.DbError,
    };
    project_dir.removeProjectTree(io, data_dir, id, gpa) catch return error.IoError;
}

pub const ChargesheetError = error{
    NotFound,
    IoError,
    OutOfMemory,
    DbError,
};

/// Result of reading a project's chargesheet from disk. Caller owns both
/// `filename` and `bytes` and must call `deinit`.
pub const ChargesheetReadResult = struct {
    filename: []u8,
    bytes: []u8,

    pub fn deinit(self: ChargesheetReadResult, gpa: std.mem.Allocator) void {
        gpa.free(self.filename);
        gpa.free(self.bytes);
    }
};

/// Cap on returned chargesheet size. PDFs in the chargesheet workflow are
/// reliably under 100 MB; larger files almost certainly indicate corruption
/// or filesystem-level tampering, so we refuse rather than risk a runaway
/// allocation.
const max_chargesheet_bytes: usize = 100 * 1024 * 1024;

/// Handle GET /api/v1/projects/:id/chargesheet — look up the project's
/// stored filename and read the on-disk PDF. Returns an owned filename +
/// bytes (caller must call `result.deinit(gpa)`).
pub fn handleProjectsChargesheet(
    io: std.Io,
    gpa: std.mem.Allocator,
    db: *Db,
    data_dir: []const u8,
    id: []const u8,
) ChargesheetError!ChargesheetReadResult {
    const maybe = projects_mod.getById(db, gpa, id) catch return error.DbError;
    if (maybe == null) return error.NotFound;
    var project = maybe.?;
    defer project.deinit(gpa);

    // Take an owned copy of the filename before `project` is deinit'd.
    const filename = gpa.dupe(u8, project.chargesheet_filename) catch return error.OutOfMemory;
    errdefer gpa.free(filename);

    const path = project_dir.chargesheetPath(gpa, data_dir, id) catch return error.OutOfMemory;
    defer gpa.free(path);

    // Read the entire chargesheet into memory. If the file is missing
    // (e.g. the directory was deleted out-of-band), surface NotFound so the
    // client gets a 404 — consistent with what the DB lookup would return.
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_chargesheet_bytes)) catch |err| switch (err) {
        error.FileNotFound => return error.NotFound,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.IoError,
    };

    return .{ .filename = filename, .bytes = bytes };
}

// ---------------------------------------------------------------------------
// POST /api/v1/projects/:id/jobs/slice — synchronous slicing.
// ---------------------------------------------------------------------------

const SliceRequestItem = struct {
    start_page: i64,
    end_page: i64,
    filename: []const u8,
};

const SliceRequestBody = struct {
    slices: []SliceRequestItem,
};

pub const SliceJobError = error{
    InvalidRequest,
    InvalidRange,
    InvalidFilename,
    DuplicateFilenames,
    ProjectNotFound,
    OutOfMemory,
    DbError,
    PdfError,
    IoError,
};

/// Result of POST /jobs/slice. Caller owns `job_id`.
pub const SliceJobResult = struct {
    job_id: []u8,

    pub fn deinit(self: SliceJobResult, gpa: std.mem.Allocator) void {
        gpa.free(self.job_id);
    }
};

/// Outcome of slicing one item — either success (with size_bytes) or failure
/// (with a static error message that the caller splices into the results
/// JSON array).
const SliceOutcome = union(enum) {
    completed: u64,
    failed: []const u8,
};

/// Slice the chargesheet for one requested range. Writes the output PDF to
/// disk and inserts a `slices` row on success. On failure, the on-disk file
/// is left as-is (may be partial) — Phase 8c can revisit cleanup; for now we
/// match the mock-daemon's behavior of "best-effort, mark this slice failed".
fn doSliceOne(
    io: std.Io,
    gpa: std.mem.Allocator,
    db: *Db,
    ctx: *mupdf.Context,
    data_dir: []const u8,
    project_id: []const u8,
    src_path_z: [:0]const u8,
    item: SliceRequestItem,
) SliceOutcome {
    _ = io; // reserved for future fs paths
    var doc = mupdf.Document.open(ctx, src_path_z) catch {
        return .{ .failed = "failed to reopen chargesheet" };
    };
    defer doc.deinit();

    const out_path = project_dir.slicePath(gpa, data_dir, project_id, item.filename) catch {
        return .{ .failed = "out of memory" };
    };
    defer gpa.free(out_path);
    const out_path_z = gpa.dupeZ(u8, out_path) catch {
        return .{ .failed = "out of memory" };
    };
    defer gpa.free(out_path_z);

    const size_bytes = doc.slice(out_path_z, @intCast(item.start_page), @intCast(item.end_page)) catch |err| {
        const msg: []const u8 = switch (err) {
            error.InvalidPageRange => "page range out of bounds",
            error.EncryptedPdf => "encrypted pdf",
            error.PdfBackendError => "mupdf error during slice",
            error.OutOfMemory => "out of memory",
            else => "slice failed",
        };
        return .{ .failed = msg };
    };

    const now = db_mod.nowIso8601(gpa) catch return .{ .failed = "timestamp alloc failed" };
    defer gpa.free(now);

    slices_mod.insert(db, gpa, .{
        .project_id = project_id,
        .filename = item.filename,
        .start_page = @intCast(item.start_page),
        .end_page = @intCast(item.end_page),
        .size_bytes = size_bytes,
        .created_at = now,
    }) catch |err| {
        if (err != error.UniqueViolation) {
            return .{ .failed = "db insert failed" };
        }
        // Duplicate (already exists from a previous slice request) — still
        // succeeded: the on-disk file has been overwritten with the new slice.
    };

    return .{ .completed = size_bytes };
}

fn appendSuccessSliceResult(
    gpa: std.mem.Allocator,
    results: *std.ArrayList(u8),
    item: SliceRequestItem,
    size_bytes: u64,
) !void {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.writeAll("{\"filename\":");
    try json_mod.writeJsonString(&w, item.filename);
    try w.print(",\"status\":\"completed\",\"page_range\":[{d},{d}],\"size_bytes\":{d},\"error\":null}}", .{ item.start_page, item.end_page, size_bytes });
    try results.appendSlice(gpa, w.buffered());
}

fn appendFailedSliceResult(
    gpa: std.mem.Allocator,
    results: *std.ArrayList(u8),
    item: SliceRequestItem,
    error_msg: []const u8,
) !void {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.writeAll("{\"filename\":");
    try json_mod.writeJsonString(&w, item.filename);
    try w.print(",\"status\":\"failed\",\"page_range\":[{d},{d}],\"size_bytes\":0,\"error\":", .{ item.start_page, item.end_page });
    try json_mod.writeJsonString(&w, error_msg);
    try w.writeAll("}");
    try results.appendSlice(gpa, w.buffered());
}

/// Handle POST /api/v1/projects/:id/jobs/slice. Body is a JSON object of the
/// form `{"slices":[{"start_page":N,"end_page":M,"filename":"x.pdf"}, ...]}`.
///
/// Validates the request (every item must have start>=1, end>=start,
/// end<=project_page_count, a safe filename, and filenames must be unique
/// within the request), then synchronously slices the chargesheet for each
/// requested range, inserts a single Job row capturing the per-slice results,
/// and returns the new job_id.
///
/// Per-slice failures do not abort the whole job — they're recorded in the
/// `results` JSON column. If all slices fail, the job's status is set to
/// `failed` and `error` is set to "All slices failed"; otherwise the job is
/// marked `completed`.
pub fn handleProjectsJobsSlice(
    io: std.Io,
    gpa: std.mem.Allocator,
    db: *Db,
    data_dir: []const u8,
    project_id: []const u8,
    body: []const u8,
) SliceJobError!SliceJobResult {
    // 1. Look up the project to validate it exists + know page_count.
    const maybe_project = projects_mod.getById(db, gpa, project_id) catch return error.DbError;
    if (maybe_project == null) return error.ProjectNotFound;
    var project = maybe_project.?;
    defer project.deinit(gpa);
    const project_page_count = project.chargesheet_page_count;

    const src_path = project_dir.chargesheetPath(gpa, data_dir, project_id) catch return error.OutOfMemory;
    defer gpa.free(src_path);
    const src_path_z = gpa.dupeZ(u8, src_path) catch return error.OutOfMemory;
    defer gpa.free(src_path_z);

    // 2. Parse JSON body.
    const parsed = std.json.parseFromSlice(SliceRequestBody, gpa, body, .{}) catch return error.InvalidRequest;
    defer parsed.deinit();
    const requested = parsed.value.slices;
    if (requested.len == 0) return error.InvalidRequest;

    // 3. Validate every requested slice.
    for (requested) |item| {
        if (item.start_page < 1 or item.end_page < item.start_page or item.end_page > @as(i64, project_page_count)) {
            return error.InvalidRange;
        }
        if (!project_dir.isSafeFilename(item.filename)) return error.InvalidFilename;
    }
    for (requested, 0..) |a, i| {
        for (requested[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.filename, b.filename)) return error.DuplicateFilenames;
        }
    }

    // 4. Set up a per-request MuPDF context.
    var mupdf_ctx = mupdf.Context.init() catch return error.PdfError;
    defer mupdf_ctx.deinit();

    // 5. Execute each slice; accumulate results JSON.
    var results_buf: std.ArrayList(u8) = .empty;
    defer results_buf.deinit(gpa);
    results_buf.append(gpa, '[') catch return error.OutOfMemory;

    var any_succeeded = false;

    for (requested, 0..) |item, i| {
        if (i > 0) results_buf.append(gpa, ',') catch return error.OutOfMemory;

        const outcome = doSliceOne(
            io,
            gpa,
            db,
            &mupdf_ctx,
            data_dir,
            project_id,
            src_path_z,
            item,
        );

        switch (outcome) {
            .completed => |size_bytes| {
                appendSuccessSliceResult(gpa, &results_buf, item, size_bytes) catch return error.OutOfMemory;
                any_succeeded = true;
            },
            .failed => |msg| {
                appendFailedSliceResult(gpa, &results_buf, item, msg) catch return error.OutOfMemory;
            },
        }
    }
    results_buf.append(gpa, ']') catch return error.OutOfMemory;

    // 6. Insert the Job row. All strings duped so the Job struct owns nothing
    //    that outlives this function; the DB layer just binds parameters.
    const job_id = ids.generateJobId(io, gpa) catch return error.OutOfMemory;
    errdefer gpa.free(job_id);

    const now_owned = db_mod.nowIso8601(gpa) catch return error.OutOfMemory;
    defer gpa.free(now_owned);

    const project_id_dup = gpa.dupe(u8, project_id) catch return error.OutOfMemory;
    defer gpa.free(project_id_dup);

    const payload_dup = gpa.dupe(u8, body) catch return error.OutOfMemory;
    defer gpa.free(payload_dup);

    const results_dup = gpa.dupe(u8, results_buf.items) catch return error.OutOfMemory;
    defer gpa.free(results_dup);

    const error_msg_owned: ?[]u8 = if (any_succeeded) null else (gpa.dupe(u8, "All slices failed") catch return error.OutOfMemory);
    defer if (error_msg_owned) |e| gpa.free(e);

    const job_row: jobs_mod.Job = .{
        .id = job_id,
        .project_id = project_id_dup,
        .type = .slice,
        .status = if (any_succeeded) .completed else .failed,
        .progress = 1.0,
        .payload = payload_dup,
        .results = results_dup,
        .error_msg = error_msg_owned,
        .created_at = now_owned,
        .updated_at = now_owned,
    };

    jobs_mod.insert(db, gpa, job_row) catch return error.DbError;

    return .{ .job_id = job_id };
}

pub const ListSlicesError = error{ NotFound, DbError, OutOfMemory };

/// Handle GET /api/v1/projects/:id/slices — list all slices for a project,
/// ordered by created_at ASC. Caller owns the returned list (must call
/// `slices_mod.deinitList`).
pub fn handleProjectsSlicesList(
    gpa: std.mem.Allocator,
    db: *Db,
    project_id: []const u8,
) ListSlicesError![]slices_mod.Slice {
    var maybe = projects_mod.getById(db, gpa, project_id) catch return error.DbError;
    if (maybe == null) return error.NotFound;
    maybe.?.deinit(gpa);

    return slices_mod.listByProject(db, gpa, project_id) catch return error.DbError;
}

pub const GetSliceError = error{ NotFound, IoError, OutOfMemory, DbError, InvalidFilename };

/// Handle GET /api/v1/projects/:id/slices/:filename — read the slice PDF from
/// disk. Returns an owned filename + bytes (caller must `result.deinit(gpa)`).
pub fn handleProjectsSlicesGet(
    io: std.Io,
    gpa: std.mem.Allocator,
    db: *Db,
    data_dir: []const u8,
    project_id: []const u8,
    filename: []const u8,
) GetSliceError!ChargesheetReadResult {
    if (!project_dir.isSafeFilename(filename)) return error.InvalidFilename;

    var maybe = projects_mod.getById(db, gpa, project_id) catch return error.DbError;
    if (maybe == null) return error.NotFound;
    maybe.?.deinit(gpa);

    const path = project_dir.slicePath(gpa, data_dir, project_id, filename) catch return error.OutOfMemory;
    defer gpa.free(path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_chargesheet_bytes)) catch |err| switch (err) {
        error.FileNotFound => return error.NotFound,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.IoError,
    };
    errdefer gpa.free(bytes);

    const filename_owned = gpa.dupe(u8, filename) catch return error.OutOfMemory;
    return .{ .filename = filename_owned, .bytes = bytes };
}

pub const DeleteSliceError = error{ NotFound, DbError, IoError, InvalidFilename };

/// Handle DELETE /api/v1/projects/:id/slices/:filename — remove the DB row and
/// the on-disk file. If the DB row is missing we return NotFound (404). If the
/// file is already gone we swallow that and treat the delete as successful (so
/// repeated deletes after an out-of-band file removal still report 204 once
/// the row has been cleaned up).
pub fn handleProjectsSlicesDelete(
    io: std.Io,
    gpa: std.mem.Allocator,
    db: *Db,
    data_dir: []const u8,
    project_id: []const u8,
    filename: []const u8,
) DeleteSliceError!void {
    if (!project_dir.isSafeFilename(filename)) return error.InvalidFilename;

    // Remove DB row first. If absent, 404.
    slices_mod.delete(db, project_id, filename) catch |err| switch (err) {
        error.NotFound => return error.NotFound,
        else => return error.DbError,
    };

    // Remove file. If already gone, swallow; otherwise propagate.
    project_dir.removeSlice(io, gpa, data_dir, project_id, filename) catch |err| {
        if (err != error.FileNotFound) return error.IoError;
    };
}

pub const GetJobError = error{
    NotFound,
    DbError,
    OutOfMemory,
};

/// Handle GET /api/v1/projects/:id/jobs/:job_id.
/// Returns the Job (caller must `job.deinit(gpa)`).
/// Returns NotFound if the project doesn't exist OR the job doesn't exist OR
/// the job's project_id doesn't match (mock behavior).
pub fn handleProjectsJobsGet(
    gpa: std.mem.Allocator,
    db: *Db,
    project_id: []const u8,
    job_id: []const u8,
) GetJobError!jobs_mod.Job {
    // Confirm the project exists first.
    const maybe_project = projects_mod.getById(db, gpa, project_id) catch return error.DbError;
    if (maybe_project == null) return error.NotFound;
    var project = maybe_project.?;
    project.deinit(gpa);

    const maybe_job = jobs_mod.getById(db, gpa, job_id) catch return error.DbError;
    if (maybe_job == null) return error.NotFound;
    var job = maybe_job.?;
    if (!std.mem.eql(u8, job.project_id, project_id)) {
        job.deinit(gpa);
        return error.NotFound;
    }
    return job;
}
