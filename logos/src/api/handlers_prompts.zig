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
// GET /api/v1/projects/:id/prompts/export
// ---------------------------------------------------------------------------
//
// Query params:
//   format=md|docx       (required)
//   names=foo,bar,baz    (optional; CSV; if absent → all known prompts that
//                         have outputs)
//
// Behavior:
//   - Looks up prompt_output rows for the project, filtered by names if given.
//   - 0 matched rows → PromptNotFound.
//   - 1 matched row → spawns `python3 -m agents.exporter --output <tmp>` in
//                     mode=single, returns the single file (no zip).
//   - 2+ rows       → spawns in mode=bundle, returns a .zip.
//
// The handler writes the spec to the child's stdin as one line of JSON,
// closes stdin, waits for exit. Exit 0 → result file is at `temp_path`.
// Caller (server.zig) must stream that file and unlink it.

pub const ExportFormat = enum { md, docx };

pub const ExportError = error{
    InvalidRequest,
    ProjectNotFound,
    PromptNotFound,
    ExporterFailed,
    IoError,
    OutOfMemory,
    DbError,
};

/// Result of GET /prompts/export. Caller owns `temp_path` AND must unlink the
/// file at that path after streaming.
pub const ExportResult = struct {
    temp_path: []u8,
    is_zip: bool,
    /// Suggested download filename (e.g. "prompts.zip" or "evidence_audit.docx").
    suggested_filename: []u8,

    pub fn deinit(self: ExportResult, gpa: Allocator) void {
        gpa.free(self.temp_path);
        gpa.free(self.suggested_filename);
    }
};

/// Parse the comma-separated `names` query param into a list of allocated
/// strings. Returns an empty list if `csv` is null or empty.
fn parseNamesCsv(gpa: Allocator, csv: ?[]const u8) ![][]u8 {
    if (csv == null or csv.?.len == 0) return try gpa.alloc([]u8, 0);
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |s| gpa.free(s);
        list.deinit(gpa);
    }
    var it = std.mem.tokenizeScalar(u8, csv.?, ',');
    while (it.next()) |tok| {
        if (tok.len == 0) continue;
        const dup = try gpa.dupe(u8, tok);
        try list.append(gpa, dup);
    }
    return try list.toOwnedSlice(gpa);
}

/// Match `name` against the `KNOWN_PROMPTS` whitelist. Used to reject
/// caller-controlled values before they reach the subprocess.
fn isKnownPrompt(name: []const u8) bool {
    for (KNOWN_PROMPTS) |kp| {
        if (std.mem.eql(u8, kp, name)) return true;
    }
    return false;
}

pub fn handleExportPrompts(
    io: std.Io,
    gpa: Allocator,
    db: *Db,
    data_dir: []const u8,
    /// Parent of the `agents/` package — used as cwd for the subprocess so
    /// `python3 -m agents.exporter` resolves the package. Mirrors the value
    /// the supervisor passes to worker spawns.
    agents_parent_dir: []const u8,
    project_id: []const u8,
    format: ExportFormat,
    names_csv: ?[]const u8,
) ExportError!ExportResult {
    // 1. Validate project exists.
    const maybe_project = projects_mod.getById(db, gpa, project_id) catch return error.DbError;
    if (maybe_project == null) return error.ProjectNotFound;
    var project = maybe_project.?;
    project.deinit(gpa);

    // 2. Parse the names filter.
    const requested = parseNamesCsv(gpa, names_csv) catch return error.OutOfMemory;
    defer {
        for (requested) |s| gpa.free(s);
        gpa.free(requested);
    }
    // Reject anything that isn't on the known list to prevent path injection
    // via the spawned process spec.
    for (requested) |n| {
        if (!isKnownPrompt(n)) return error.InvalidRequest;
    }

    // 3. Look up prompt_output rows.
    const all_outputs = prompt_outputs_mod.listByProject(db, gpa, project_id) catch return error.DbError;
    defer prompt_outputs_mod.deinitList(all_outputs, gpa);

    // Filter: if requested is non-empty, intersect with it; otherwise take all.
    // The PromptOutput entries reference memory owned by `all_outputs`, so we
    // only need to free our list's spine here, not the contents.
    var selected: std.ArrayList(prompt_outputs_mod.PromptOutput) = .empty;
    defer selected.deinit(gpa);
    for (all_outputs) |out| {
        if (requested.len == 0) {
            try selected.append(gpa, out);
        } else {
            for (requested) |n| {
                if (std.mem.eql(u8, n, out.prompt_name)) {
                    try selected.append(gpa, out);
                    break;
                }
            }
        }
    }
    if (selected.items.len == 0) return error.PromptNotFound;

    const mode_single = selected.items.len == 1;
    const ext: []const u8 = if (mode_single)
        (if (format == .docx) ".docx" else ".md")
    else
        ".zip";

    // 4. Build a tempfile path under <data_dir>/.exports/<uuid><ext>.
    const exports_dir = try std.fs.path.join(gpa, &.{ data_dir, ".exports" });
    defer gpa.free(exports_dir);
    std.Io.Dir.cwd().createDirPath(io, exports_dir) catch return error.IoError;

    const uid = ids.generateJobId(io, gpa) catch return error.OutOfMemory;
    defer gpa.free(uid);
    const temp_basename = std.fmt.allocPrint(gpa, "{s}{s}", .{ uid, ext }) catch return error.OutOfMemory;
    defer gpa.free(temp_basename);
    const temp_path = std.fs.path.join(gpa, &.{ exports_dir, temp_basename }) catch return error.OutOfMemory;
    errdefer gpa.free(temp_path);

    // 5. Build the spec JSON for stdin.
    var spec_buf: std.ArrayList(u8) = .empty;
    defer spec_buf.deinit(gpa);
    try spec_buf.appendSlice(gpa, "{\"format\":\"");
    try spec_buf.appendSlice(gpa, if (format == .docx) "docx" else "md");
    try spec_buf.appendSlice(gpa, "\",\"mode\":\"");
    try spec_buf.appendSlice(gpa, if (mode_single) "single" else "bundle");
    try spec_buf.appendSlice(gpa, "\",\"items\":[");
    for (selected.items, 0..) |out, i| {
        if (i > 0) try spec_buf.append(gpa, ',');
        try spec_buf.appendSlice(gpa, "{\"name\":");
        try appendJsonString(&spec_buf, gpa, out.prompt_name);
        try spec_buf.appendSlice(gpa, ",\"md_path\":");
        try appendJsonString(&spec_buf, gpa, out.markdown_path);
        try spec_buf.append(gpa, '}');
    }
    try spec_buf.appendSlice(gpa, "]}\n");

    // 6. Spawn `python3 -m agents.exporter --output <temp_path>` from agents_dir.
    const argv = [_][]const u8{ "python3", "-m", "agents.exporter", "--output", temp_path };
    var env_map = blk: {
        const c_environ: [*:null]?[*:0]const u8 = @ptrCast(std.c.environ);
        const env_slice: [:null]const ?[*:0]const u8 = std.mem.span(c_environ);
        const environ: std.process.Environ = .{ .block = .{ .slice = env_slice } };
        break :blk std.process.Environ.createMap(environ, gpa) catch return error.OutOfMemory;
    };
    defer env_map.deinit();

    var child = std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .pipe,
        .stdout = .inherit,
        .stderr = .inherit,
        .environ_map = &env_map,
        .cwd = .{ .path = agents_parent_dir },
    }) catch return error.ExporterFailed;
    errdefer child.kill(io);

    // Write spec to stdin, close to signal EOF.
    {
        const stdin_file = child.stdin orelse return error.ExporterFailed;
        var write_buf: [4096]u8 = undefined;
        var writer = stdin_file.writer(io, &write_buf);
        writer.interface.writeAll(spec_buf.items) catch return error.ExporterFailed;
        writer.interface.flush() catch return error.ExporterFailed;
        stdin_file.close(io);
        child.stdin = null;
    }

    const term = child.wait(io) catch return error.ExporterFailed;
    switch (term) {
        .exited => |code| if (code != 0) return error.ExporterFailed,
        else => return error.ExporterFailed,
    }

    // 7. Build the suggested filename.
    const suggested = blk: {
        if (mode_single) {
            // <prompt_name>.<ext>
            break :blk std.fmt.allocPrint(gpa, "{s}{s}", .{ selected.items[0].prompt_name, ext }) catch return error.OutOfMemory;
        }
        break :blk std.fmt.allocPrint(gpa, "prompts-{s}{s}", .{ project_id, ext }) catch return error.OutOfMemory;
    };

    return .{
        .temp_path = temp_path,
        .is_zip = !mode_single,
        .suggested_filename = suggested,
    };
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

/// Append `s` as a JSON-quoted, escaped string to `buf`. Used to build the
/// exporter spec without juggling temporary Writers.
fn appendJsonString(buf: *std.ArrayList(u8), gpa: Allocator, s: []const u8) !void {
    try buf.append(gpa, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(gpa, "\\\""),
            '\\' => try buf.appendSlice(gpa, "\\\\"),
            '\n' => try buf.appendSlice(gpa, "\\n"),
            '\r' => try buf.appendSlice(gpa, "\\r"),
            '\t' => try buf.appendSlice(gpa, "\\t"),
            0...0x08, 0x0B, 0x0C, 0x0E...0x1F => {
                var tmp: [6]u8 = undefined;
                const written = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch unreachable;
                try buf.appendSlice(gpa, written);
            },
            else => try buf.append(gpa, c),
        }
    }
    try buf.append(gpa, '"');
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
