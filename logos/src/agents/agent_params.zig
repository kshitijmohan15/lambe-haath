//! Build agent-specific JSON params from a job row.
//! Each agent has its own params contract (see agents/ocr_agent/server.py
//! and agents/prompt_agent/server.py). This module hides that ugliness
//! from the dispatcher: given (data_dir, job), produce the right JSON.
//!
//! OCR agent expects:
//!   {"slice_path":"<abs>","output_dir":"<abs>","job_id":"...","_meta":{"progressToken":"..."}}
//!
//! Prompt agent expects:
//!   {"prompt_name":"...","slices":{...},"ruds":[...],"output_dir":"...","job_id":"...","_meta":{...}}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Db = @import("../db/db.zig").Db;
const extractions_mod = @import("../db/extractions.zig");

/// Append a JSON string literal (with surrounding quotes) to `buf`.
/// Handles the same escapes as api/json.zig:writeJsonString.
fn appendJsonStr(gpa: Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.append(gpa, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(gpa, "\\\""),
            '\\' => try buf.appendSlice(gpa, "\\\\"),
            '\n' => try buf.appendSlice(gpa, "\\n"),
            '\r' => try buf.appendSlice(gpa, "\\r"),
            '\t' => try buf.appendSlice(gpa, "\\t"),
            0...0x08, 0x0B, 0x0C, 0x0E...0x1F => {
                var tmp: [7]u8 = undefined;
                var fw = std.Io.Writer.fixed(&tmp);
                fw.print("\\u{x:0>4}", .{c}) catch unreachable;
                try buf.appendSlice(gpa, fw.buffered());
            },
            else => try buf.append(gpa, c),
        }
    }
    try buf.append(gpa, '"');
}

/// Build params JSON for an OCR job.
///
/// Input: job.payload looks like `{"slice_filename":"annexure-i.pdf"}`.
/// Output: `{"slice_path":"<data_dir>/<proj>/slices/<file>","output_dir":"<data_dir>/<proj>/extractions","job_id":"...","_meta":{"progressToken":"..."}}`.
///
/// Caller owns the returned slice.
pub fn buildOcrParams(
    gpa: Allocator,
    data_dir: []const u8,
    job_id: []const u8,
    project_id: []const u8,
    payload_json: []const u8,
) ![]u8 {
    // Parse the payload to get the slice_filename.
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, payload_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.MissingSliceFilename;
    const slice_filename = (parsed.value.object.get("slice_filename") orelse
        return error.MissingSliceFilename).string;

    // Build absolute slice_path = <data_dir>/<project_id>/slices/<slice_filename>
    const slice_path = try std.fs.path.join(gpa, &.{ data_dir, project_id, "slices", slice_filename });
    defer gpa.free(slice_path);
    const output_dir = try std.fs.path.join(gpa, &.{ data_dir, project_id, "extractions" });
    defer gpa.free(output_dir);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

    try buf.appendSlice(gpa, "{\"slice_path\":");
    try appendJsonStr(gpa, &buf, slice_path);
    try buf.appendSlice(gpa, ",\"output_dir\":");
    try appendJsonStr(gpa, &buf, output_dir);
    try buf.appendSlice(gpa, ",\"job_id\":");
    try appendJsonStr(gpa, &buf, job_id);
    try buf.appendSlice(gpa, ",\"_meta\":{\"progressToken\":");
    try appendJsonStr(gpa, &buf, job_id);
    try buf.appendSlice(gpa, "}}");

    return try buf.toOwnedSlice(gpa);
}

/// Build params JSON for a prompt job.
///
/// Input: job.payload looks like `{"prompt_name":"charge_memo_analysis"}`.
/// Queries the extractions table for all rows under project_id, classifies each
/// by filename pattern, and builds slices/ruds maps.
///
/// Output: `{"prompt_name":"...","slices":{...},"ruds":[...],"output_dir":"...","job_id":"...","_meta":{...}}`.
///
/// Caller owns the returned slice.
pub fn buildPromptParams(
    gpa: Allocator,
    db: *Db,
    data_dir: []const u8,
    job_id: []const u8,
    project_id: []const u8,
    payload_json: []const u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, payload_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.MissingPromptName;
    const prompt_name = (parsed.value.object.get("prompt_name") orelse
        return error.MissingPromptName).string;

    const output_dir = try std.fs.path.join(gpa, &.{ data_dir, project_id, "prompt_outputs" });
    defer gpa.free(output_dir);

    // Fetch all extractions for this project.
    const extractions = try extractions_mod.listByProject(db, gpa, project_id);
    defer extractions_mod.deinitList(extractions, gpa);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

    try buf.appendSlice(gpa, "{\"prompt_name\":");
    try appendJsonStr(gpa, &buf, prompt_name);

    // slices: {"annexure-i": {"markdown_path": "..."}, ...}
    try buf.appendSlice(gpa, ",\"slices\":{");
    var first_slice = true;
    for (extractions) |ex| {
        if (annexureStem(ex.slice_filename)) |stem| {
            if (!first_slice) try buf.appendSlice(gpa, ",");
            try appendJsonStr(gpa, &buf, stem);
            try buf.appendSlice(gpa, ":{\"markdown_path\":");
            try appendJsonStr(gpa, &buf, ex.markdown_path);
            try buf.appendSlice(gpa, "}");
            first_slice = false;
        }
    }
    try buf.appendSlice(gpa, "}");

    // ruds: [{"id": "RUD-01", "markdown_path": "..."}, ...]
    try buf.appendSlice(gpa, ",\"ruds\":[");
    var first_rud = true;
    for (extractions) |ex| {
        if (rudIdSuffix(ex.slice_filename)) |suffix| {
            // Construct "RUD-<SUFFIX>" uppercased — suffix is e.g. "01".
            // Digits are already uppercase, but handle alpha chars defensively.
            const rid = try std.fmt.allocPrint(gpa, "RUD-{s}", .{suffix});
            defer gpa.free(rid);
            for (rid[4..]) |*ch| ch.* = std.ascii.toUpper(ch.*);

            if (!first_rud) try buf.appendSlice(gpa, ",");
            try buf.appendSlice(gpa, "{\"id\":");
            try appendJsonStr(gpa, &buf, rid);
            try buf.appendSlice(gpa, ",\"markdown_path\":");
            try appendJsonStr(gpa, &buf, ex.markdown_path);
            try buf.appendSlice(gpa, "}");
            first_rud = false;
        }
    }
    try buf.appendSlice(gpa, "]");

    try buf.appendSlice(gpa, ",\"output_dir\":");
    try appendJsonStr(gpa, &buf, output_dir);
    try buf.appendSlice(gpa, ",\"job_id\":");
    try appendJsonStr(gpa, &buf, job_id);
    try buf.appendSlice(gpa, ",\"_meta\":{\"progressToken\":");
    try appendJsonStr(gpa, &buf, job_id);
    try buf.appendSlice(gpa, "}}");

    return try buf.toOwnedSlice(gpa);
}

/// If `filename` is `annexure-X.pdf`, return the stem `annexure-X` (no .pdf).
/// The returned slice aliases the input — do not free separately.
fn annexureStem(filename: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, filename, "annexure-")) return null;
    if (!std.mem.endsWith(u8, filename, ".pdf")) return null;
    return filename[0 .. filename.len - 4];
}

/// If `filename` is `rud-NN.pdf`, return the numeric suffix `NN` (e.g. "01").
/// The returned slice aliases the input — do not free separately.
fn rudIdSuffix(filename: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, filename, "rud-")) return null;
    if (!std.mem.endsWith(u8, filename, ".pdf")) return null;
    return filename[4 .. filename.len - 4];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "buildOcrParams produces the agent's expected shape" {
    const gpa = std.testing.allocator;
    const params = try buildOcrParams(
        gpa,
        "/tmp/data",
        "job_abc",
        "proj_xyz",
        "{\"slice_filename\":\"annexure-i.pdf\"}",
    );
    defer gpa.free(params);

    try std.testing.expect(std.mem.indexOf(u8, params, "\"slice_path\":\"/tmp/data/proj_xyz/slices/annexure-i.pdf\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, params, "\"output_dir\":\"/tmp/data/proj_xyz/extractions\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, params, "\"job_id\":\"job_abc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, params, "\"progressToken\":\"job_abc\"") != null);
}

test "buildOcrParams errors on missing slice_filename" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(
        error.MissingSliceFilename,
        buildOcrParams(gpa, "/tmp/data", "job_abc", "proj_xyz", "{\"prompt_name\":\"x\"}"),
    );
}

test "buildPromptParams classifies annexures vs ruds" {
    var db = try Db.open(":memory:");
    defer db.close();
    const gpa = std.testing.allocator;

    const test_helpers = @import("../db/test_helpers.zig");
    const slices = @import("../db/slices.zig");
    try test_helpers.insertProject(&db, "p1");
    try slices.insert(&db, gpa, .{
        .project_id = "p1",
        .filename = "annexure-i.pdf",
        .start_page = 1,
        .end_page = 1,
        .size_bytes = 1,
        .kind = .annexure,
        .kind_key = "i",
        .created_at = "2026-05-28T00:00:00Z",
    });
    try slices.insert(&db, gpa, .{
        .project_id = "p1",
        .filename = "rud-01.pdf",
        .start_page = 1,
        .end_page = 1,
        .size_bytes = 1,
        .kind = .rud,
        .kind_key = "01",
        .created_at = "2026-05-28T00:00:00Z",
    });
    try extractions_mod.upsert(&db, gpa, .{
        .project_id = "p1",
        .slice_filename = "annexure-i.pdf",
        .markdown_path = "/data/p1/extractions/annexure-i.md",
        .meta_path = "/data/p1/extractions/annexure-i.meta.json",
        .model = "gemini-2.5-flash",
        .pages = 1,
        .page_markers_found = 1,
        .latency_s = 1.0,
        .created_at = "2026-05-28T00:01:00Z",
    });
    try extractions_mod.upsert(&db, gpa, .{
        .project_id = "p1",
        .slice_filename = "rud-01.pdf",
        .markdown_path = "/data/p1/extractions/rud-01.md",
        .meta_path = "/data/p1/extractions/rud-01.meta.json",
        .model = "gemini-2.5-flash",
        .pages = 1,
        .page_markers_found = 1,
        .latency_s = 1.0,
        .created_at = "2026-05-28T00:01:00Z",
    });

    const params = try buildPromptParams(
        gpa,
        &db,
        "/data",
        "job_xyz",
        "p1",
        "{\"prompt_name\":\"charge_memo_analysis\"}",
    );
    defer gpa.free(params);

    try std.testing.expect(std.mem.indexOf(u8, params, "\"prompt_name\":\"charge_memo_analysis\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, params, "\"annexure-i\":{\"markdown_path\":\"/data/p1/extractions/annexure-i.md\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, params, "\"RUD-01\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, params, "\"output_dir\":\"/data/p1/prompt_outputs\"") != null);
}
