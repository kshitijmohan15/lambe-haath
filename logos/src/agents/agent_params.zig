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
const slices_mod = @import("../db/slices.zig");

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
/// Output: `{"slice_path":"...","output_dir":"...","start_page":<int>,"job_id":"...","_meta":{...}}`.
/// `start_page` is the absolute page number of the slice's first page within the
/// original chargesheet (looked up from the slices table). Defaults to 1 if the
/// slice isn't found in the DB.
///
/// Caller owns the returned slice.
pub fn buildOcrParams(
    gpa: Allocator,
    db: *Db,
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

    // Look up the slice's origin start_page (1-based, absolute within the
    // original chargesheet). Defaults to 1 for slices not in the DB (which
    // shouldn't happen in normal flow but keeps OCR from crashing).
    var start_page: u32 = 1;
    if (try slices_mod.getByKey(db, gpa, project_id, slice_filename)) |slice| {
        var s = slice;
        defer s.deinit(gpa);
        start_page = s.start_page;
    }

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

    try buf.appendSlice(gpa, "{\"slice_path\":");
    try appendJsonStr(gpa, &buf, slice_path);
    try buf.appendSlice(gpa, ",\"output_dir\":");
    try appendJsonStr(gpa, &buf, output_dir);
    try buf.appendSlice(gpa, ",\"start_page\":");
    {
        const start_page_str = try std.fmt.allocPrint(gpa, "{d}", .{start_page});
        defer gpa.free(start_page_str);
        try buf.appendSlice(gpa, start_page_str);
    }
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
        var stem_buf: [32]u8 = undefined;
        if (annexureStem(ex.slice_filename, &stem_buf)) |stem| {
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
        var suf_buf: [8]u8 = undefined;
        if (rudIdSuffix(ex.slice_filename, &suf_buf)) |suffix| {
            const rid = try std.fmt.allocPrint(gpa, "RUD-{s}", .{suffix});
            defer gpa.free(rid);
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

/// Roman numerals 1..10 keyed by index (so ROMAN[0] = "i", ROMAN[3] = "iv", etc.)
const ROMAN = [_][]const u8{ "i", "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x" };

/// Strip the .pdf extension (case-insensitive), lowercase the rest, and drop any
/// non-alphanumeric characters (spaces, hyphens, underscores). Returns a slice
/// of `scratch` containing the normalized form, or null if the result doesn't
/// fit. Used to make annexure/RUD classification tolerant of naming variants.
fn normalize(filename: []const u8, scratch: *[64]u8) ?[]const u8 {
    var body = filename;
    if (body.len >= 4) {
        const ext = body[body.len - 4 ..];
        if (std.ascii.eqlIgnoreCase(ext, ".pdf")) body = body[0 .. body.len - 4];
    }
    var n: usize = 0;
    for (body) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            if (n >= scratch.len) return null;
            scratch[n] = std.ascii.toLower(c);
            n += 1;
        }
    }
    return scratch[0..n];
}

/// Convert a normalized suffix to its canonical roman form (i, ii, ..., x).
/// Accepts either roman ("i", "iv") or arabic ("1", "4") input. Range 1-10.
fn romanFromSuffix(s: []const u8) ?[]const u8 {
    for (ROMAN) |r| if (std.mem.eql(u8, s, r)) return r;
    const n = std.fmt.parseInt(u32, s, 10) catch return null;
    if (n < 1 or n > ROMAN.len) return null;
    return ROMAN[n - 1];
}

/// If `filename` is some variant of an annexure slice, write the canonical key
/// (e.g. "annexure-iv") into `out` and return that slice. Tolerates `Annexure1`,
/// `AnnexureII`, `annexure-i`, `ANNEXURE I`, etc. Returns null if it doesn't
/// look like an annexure.
fn annexureStem(filename: []const u8, out: *[32]u8) ?[]const u8 {
    var scratch: [64]u8 = undefined;
    const normalized = normalize(filename, &scratch) orelse return null;
    if (!std.mem.startsWith(u8, normalized, "annexure")) return null;
    const suffix = normalized["annexure".len..];
    if (suffix.len == 0) return null;
    const roman = romanFromSuffix(suffix) orelse return null;
    var fw = std.Io.Writer.fixed(out);
    fw.print("annexure-{s}", .{roman}) catch return null;
    return fw.buffered();
}

/// If `filename` is some variant of a RUD slice, write the zero-padded 2-digit
/// numeric suffix (e.g. "01", "23") into `out` and return that slice. Tolerates
/// `Rud-01`, `RUD01`, `rud 1`, `RUD-1`, etc. Returns null if it doesn't look
/// like a RUD.
fn rudIdSuffix(filename: []const u8, out: *[8]u8) ?[]const u8 {
    var scratch: [64]u8 = undefined;
    const normalized = normalize(filename, &scratch) orelse return null;
    if (!std.mem.startsWith(u8, normalized, "rud")) return null;
    const suffix = normalized["rud".len..];
    if (suffix.len == 0) return null;
    const n = std.fmt.parseInt(u32, suffix, 10) catch return null;
    if (n < 1 or n > 999) return null;
    var fw = std.Io.Writer.fixed(out);
    fw.print("{d:0>2}", .{n}) catch return null;
    return fw.buffered();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "buildOcrParams produces the agent's expected shape with start_page" {
    var db = try Db.open(":memory:");
    defer db.close();
    const gpa = std.testing.allocator;

    const test_helpers = @import("../db/test_helpers.zig");
    try test_helpers.insertProject(&db, "proj_xyz");
    try slices_mod.insert(&db, gpa, .{
        .project_id = "proj_xyz",
        .filename = "annexure-ii.pdf",
        .start_page = 70,
        .end_page = 170,
        .size_bytes = 1024,
        .kind = .annexure,
        .kind_key = "ii",
        .created_at = "2026-05-28T00:00:00Z",
    });

    const params = try buildOcrParams(
        gpa,
        &db,
        "/tmp/data",
        "job_abc",
        "proj_xyz",
        "{\"slice_filename\":\"annexure-ii.pdf\"}",
    );
    defer gpa.free(params);

    try std.testing.expect(std.mem.indexOf(u8, params, "\"slice_path\":\"/tmp/data/proj_xyz/slices/annexure-ii.pdf\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, params, "\"output_dir\":\"/tmp/data/proj_xyz/extractions\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, params, "\"start_page\":70") != null);
    try std.testing.expect(std.mem.indexOf(u8, params, "\"job_id\":\"job_abc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, params, "\"progressToken\":\"job_abc\"") != null);
}

test "buildOcrParams defaults start_page to 1 when slice not in DB" {
    var db = try Db.open(":memory:");
    defer db.close();
    const gpa = std.testing.allocator;

    const params = try buildOcrParams(
        gpa,
        &db,
        "/tmp/data",
        "job_abc",
        "proj_xyz",
        "{\"slice_filename\":\"orphan.pdf\"}",
    );
    defer gpa.free(params);
    try std.testing.expect(std.mem.indexOf(u8, params, "\"start_page\":1") != null);
}

test "buildOcrParams errors on missing slice_filename" {
    var db = try Db.open(":memory:");
    defer db.close();
    const gpa = std.testing.allocator;
    try std.testing.expectError(
        error.MissingSliceFilename,
        buildOcrParams(gpa, &db, "/tmp/data", "job_abc", "proj_xyz", "{\"prompt_name\":\"x\"}"),
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

test "annexureStem accepts naming variants" {
    var out: [32]u8 = undefined;
    // Canonical
    try std.testing.expectEqualStrings("annexure-i", annexureStem("annexure-i.pdf", &out).?);
    try std.testing.expectEqualStrings("annexure-iv", annexureStem("annexure-iv.pdf", &out).?);
    // Title case, no separator
    try std.testing.expectEqualStrings("annexure-i", annexureStem("Annexure1.pdf", &out).?);
    try std.testing.expectEqualStrings("annexure-ii", annexureStem("AnnexureII.pdf", &out).?);
    try std.testing.expectEqualStrings("annexure-iv", annexureStem("Annexure4.pdf", &out).?);
    // Uppercase with space
    try std.testing.expectEqualStrings("annexure-iii", annexureStem("ANNEXURE III.pdf", &out).?);
    try std.testing.expectEqualStrings("annexure-iii", annexureStem("ANNEXURE 3.pdf", &out).?);
    // Mixed case hyphen
    try std.testing.expectEqualStrings("annexure-i", annexureStem("Annexure-I.pdf", &out).?);
    // Case-insensitive extension
    try std.testing.expectEqualStrings("annexure-ii", annexureStem("Annexure2.PDF", &out).?);
    // Non-matches
    try std.testing.expect(annexureStem("foo.pdf", &out) == null);
    try std.testing.expect(annexureStem("annexure-99.pdf", &out) == null);
    try std.testing.expect(annexureStem("annexure-.pdf", &out) == null);
    try std.testing.expect(annexureStem("annexure-xyz.pdf", &out) == null);
}

test "rudIdSuffix accepts naming variants" {
    var out: [8]u8 = undefined;
    // Canonical
    try std.testing.expectEqualStrings("01", rudIdSuffix("rud-01.pdf", &out).?);
    try std.testing.expectEqualStrings("23", rudIdSuffix("rud-23.pdf", &out).?);
    // Title case, no separator
    try std.testing.expectEqualStrings("01", rudIdSuffix("Rud1.pdf", &out).?);
    try std.testing.expectEqualStrings("01", rudIdSuffix("RUD-1.pdf", &out).?);
    // Uppercase with space
    try std.testing.expectEqualStrings("07", rudIdSuffix("RUD 7.pdf", &out).?);
    // Already 2-digit
    try std.testing.expectEqualStrings("99", rudIdSuffix("RUD99.pdf", &out).?);
    // Non-matches
    try std.testing.expect(rudIdSuffix("annexure-i.pdf", &out) == null);
    try std.testing.expect(rudIdSuffix("rud.pdf", &out) == null);
    try std.testing.expect(rudIdSuffix("rud-abc.pdf", &out) == null);
}
