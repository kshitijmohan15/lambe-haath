//! Handler functions for prompt job enqueue and prompt output retrieval endpoints.
//!
//! Four endpoints:
//!   POST /api/v1/projects/:id/jobs/prompt          → enqueue one prompt job
//!   POST /api/v1/projects/:id/jobs/prompt/all      → enqueue all 5 known prompts
//!   GET  /api/v1/projects/:id/prompts              → list prompt_output rows
//!   GET  /api/v1/projects/:id/prompts/:prompt_name → download .md file contents

const std = @import("std");
const Allocator = std.mem.Allocator;
const Db = @import("../db/db.zig").Db;
const db_mod = @import("../db/db.zig");
const jobs_mod = @import("../db/jobs.zig");
const prompt_outputs_mod = @import("../db/prompt_outputs.zig");
const projects_mod = @import("../db/projects.zig");
const ids = @import("../ids.zig");
const test_helpers = @import("../db/test_helpers.zig");

const KNOWN_PROMPTS = [_][]const u8{
    "charge_memo_analysis",
    "imputation_scrutiny",
    "time_chart",
    "evidence_audit",
    "objection_brief",
};

// ---------------------------------------------------------------------------
// POST /api/v1/projects/:id/jobs/prompt
// ---------------------------------------------------------------------------

const PromptRequestBody = struct {
    prompt_name: []const u8,
};

pub const EnqueuePromptError = error{
    InvalidRequest,
    ProjectNotFound,
    OutOfMemory,
    DbError,
};

/// Result of POST /jobs/prompt. Caller owns `job_id`.
pub const EnqueuePromptResult = struct {
    job_id: []u8,

    pub fn deinit(self: EnqueuePromptResult, gpa: Allocator) void {
        gpa.free(self.job_id);
    }
};

/// Handle POST /api/v1/projects/:id/jobs/prompt.
/// Body: `{"prompt_name":"evidence_audit"}`.
/// Returns 201 `{job_id}`, or error mapping:
///   InvalidRequest → 400 (bad JSON or unknown prompt_name), ProjectNotFound → 404.
pub fn handleEnqueuePrompt(
    io: std.Io,
    gpa: Allocator,
    db: *Db,
    project_id: []const u8,
    body: []const u8,
) EnqueuePromptError!EnqueuePromptResult {
    // 1. Confirm project exists.
    const maybe_project = projects_mod.getById(db, gpa, project_id) catch return error.DbError;
    if (maybe_project == null) return error.ProjectNotFound;
    var project = maybe_project.?;
    project.deinit(gpa);

    // 2. Parse body.
    const parsed = std.json.parseFromSlice(PromptRequestBody, gpa, body, .{}) catch return error.InvalidRequest;
    defer parsed.deinit();
    const prompt_name = parsed.value.prompt_name;
    if (prompt_name.len == 0) return error.InvalidRequest;

    // 3. Validate prompt_name against known list.
    var known = false;
    for (KNOWN_PROMPTS) |kp| {
        if (std.mem.eql(u8, kp, prompt_name)) {
            known = true;
            break;
        }
    }
    if (!known) return error.InvalidRequest;

    // 4. Generate job id.
    const job_id = ids.generateJobId(io, gpa) catch return error.OutOfMemory;
    errdefer gpa.free(job_id);

    // 5. Build payload JSON: {"prompt_name":"<name>"}.
    var payload_buf: [512]u8 = undefined;
    var pw = std.Io.Writer.fixed(&payload_buf);
    pw.writeAll("{\"prompt_name\":") catch return error.OutOfMemory;
    writeJsonStringFixed(&pw, prompt_name) catch return error.OutOfMemory;
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
        .type = .prompt,
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
// POST /api/v1/projects/:id/jobs/prompt/all
// ---------------------------------------------------------------------------

pub const EnqueuePromptAllError = error{
    ProjectNotFound,
    OutOfMemory,
    DbError,
};

/// Result of POST /jobs/prompt/all. Caller owns the `job_ids` slice and each string.
pub const EnqueuePromptAllResult = struct {
    job_ids: [][]u8,

    pub fn deinit(self: EnqueuePromptAllResult, gpa: Allocator) void {
        for (self.job_ids) |jid| gpa.free(jid);
        gpa.free(self.job_ids);
    }
};

/// Handle POST /api/v1/projects/:id/jobs/prompt/all.
/// Enqueues a prompt job for each of the 5 known prompts.
/// Returns an array of 5 job_ids.
pub fn handleEnqueuePromptAll(
    io: std.Io,
    gpa: Allocator,
    db: *Db,
    project_id: []const u8,
) EnqueuePromptAllError!EnqueuePromptAllResult {
    // 1. Confirm project exists.
    const maybe_project = projects_mod.getById(db, gpa, project_id) catch return error.DbError;
    if (maybe_project == null) return error.ProjectNotFound;
    var project = maybe_project.?;
    project.deinit(gpa);

    var job_ids: std.ArrayList([]u8) = .empty;
    errdefer {
        for (job_ids.items) |jid| gpa.free(jid);
        job_ids.deinit(gpa);
    }

    const now = db_mod.nowIso8601(gpa) catch return error.OutOfMemory;
    defer gpa.free(now);

    const project_id_dup = gpa.dupe(u8, project_id) catch return error.OutOfMemory;
    defer gpa.free(project_id_dup);

    for (KNOWN_PROMPTS) |prompt_name| {
        const job_id = ids.generateJobId(io, gpa) catch return error.OutOfMemory;
        errdefer gpa.free(job_id);

        var payload_buf: [512]u8 = undefined;
        var pw = std.Io.Writer.fixed(&payload_buf);
        pw.writeAll("{\"prompt_name\":") catch return error.OutOfMemory;
        writeJsonStringFixed(&pw, prompt_name) catch return error.OutOfMemory;
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
            .type = .prompt,
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
// GET /api/v1/projects/:id/prompts
// ---------------------------------------------------------------------------

pub const ListPromptsError = error{ ProjectNotFound, DbError, OutOfMemory };

/// Handle GET /api/v1/projects/:id/prompts.
/// Returns an owned slice of PromptOutput rows (caller must call `prompt_outputs_mod.deinitList`).
pub fn handleListPrompts(
    gpa: Allocator,
    db: *Db,
    project_id: []const u8,
) ListPromptsError![]prompt_outputs_mod.PromptOutput {
    const maybe_project = projects_mod.getById(db, gpa, project_id) catch return error.DbError;
    if (maybe_project == null) return error.ProjectNotFound;
    var project = maybe_project.?;
    project.deinit(gpa);

    return prompt_outputs_mod.listByProject(db, gpa, project_id) catch return error.DbError;
}

// ---------------------------------------------------------------------------
// GET /api/v1/projects/:id/prompts/:prompt_name
// ---------------------------------------------------------------------------

pub const GetPromptMarkdownError = error{
    ProjectNotFound,
    PromptNotFound,
    IoError,
    OutOfMemory,
    DbError,
};

/// Result of GET /prompts/:prompt_name. Caller owns `markdown_bytes`.
pub const PromptMarkdownResult = struct {
    markdown_bytes: []u8,

    pub fn deinit(self: PromptMarkdownResult, gpa: Allocator) void {
        gpa.free(self.markdown_bytes);
    }
};

const max_markdown_bytes: usize = 10 * 1024 * 1024; // 10 MiB

/// Handle GET /api/v1/projects/:id/prompts/:prompt_name.
/// Reads the .md file from the path stored in the prompt_output row.
pub fn handleGetPromptMarkdown(
    io: std.Io,
    gpa: Allocator,
    db: *Db,
    project_id: []const u8,
    prompt_name: []const u8,
) GetPromptMarkdownError!PromptMarkdownResult {
    // 1. Confirm project exists.
    const maybe_project = projects_mod.getById(db, gpa, project_id) catch return error.DbError;
    if (maybe_project == null) return error.ProjectNotFound;
    var project = maybe_project.?;
    project.deinit(gpa);

    // 2. Look up prompt_output row.
    const maybe_output = prompt_outputs_mod.getByKey(db, gpa, project_id, prompt_name) catch return error.DbError;
    if (maybe_output == null) return error.PromptNotFound;
    var output = maybe_output.?;
    defer output.deinit(gpa);

    // 3. Read .md file from disk.
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, output.markdown_path, gpa, .limited(max_markdown_bytes)) catch |err| switch (err) {
        error.FileNotFound => return error.PromptNotFound,
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

test "postEnqueuePrompt rejects unknown prompt_name" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();

    try test_helpers.insertProject(&db, "p1");

    // Unknown prompt_name → InvalidRequest
    const err = handleEnqueuePrompt(std.testing.io, gpa, &db, "p1", "{\"prompt_name\":\"nonexistent_prompt\"}");
    try std.testing.expectError(error.InvalidRequest, err);
}

test "postEnqueuePromptAll enqueues exactly 5 jobs" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();

    try test_helpers.insertProject(&db, "p1");

    const result = try handleEnqueuePromptAll(std.testing.io, gpa, &db, "p1");
    defer result.deinit(gpa);

    // Must produce exactly 5 job_ids, one per known prompt.
    try std.testing.expectEqual(@as(usize, 5), result.job_ids.len);

    // Verify all rows landed in DB with type='prompt' and status='queued'.
    for (result.job_ids) |jid| {
        try std.testing.expect(jid.len > 0);
        const row = (try db.conn.row("SELECT type, status FROM jobs WHERE id = ?", .{jid})).?;
        defer row.deinit();
        try std.testing.expectEqualStrings("prompt", row.text(0));
        try std.testing.expectEqualStrings("queued", row.text(1));
    }
}
