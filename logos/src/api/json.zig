//! Tiny JSON serialization helpers for the HTTP API.
//!
//! These hand-write the small response payloads the daemon emits (`/health`,
//! API errors) so we do not pull in a full JSON encoder just for two shapes.
//! The strings written here are ASCII-only and contain no characters that
//! need escaping; callers are expected to pass valid UTF-8 with no quotes,
//! backslashes, or control characters in the `version`, `code`, or `message`
//! arguments.

const std = @import("std");
const projects_db = @import("../db/projects.zig");
const Project = projects_db.Project;

/// Write `{"status":"ok","version":"<version>"}` to `w`.
pub fn writeHealth(w: *std.Io.Writer, version: []const u8) !void {
    try w.print("{{\"status\":\"ok\",\"version\":\"{s}\"}}", .{version});
}

/// Write `{"code":"<code>","message":"<message>"}` to `w`.
pub fn writeError(w: *std.Io.Writer, code: []const u8, message: []const u8) !void {
    try w.print("{{\"code\":\"{s}\",\"message\":\"{s}\"}}", .{ code, message });
}

test "writeHealth produces the expected shape" {
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeHealth(&w, "0.2.0");
    try std.testing.expectEqualStrings(
        \\{"status":"ok","version":"0.2.0"}
    , w.buffered());
}

test "writeError produces the expected shape" {
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeError(&w, "NOT_FOUND", "Project not found");
    try std.testing.expectEqualStrings(
        \\{"code":"NOT_FOUND","message":"Project not found"}
    , w.buffered());
}

/// Open a JSON array. Caller writes zero or more `,`-separated objects.
pub fn writeProjectArrayOpen(w: *std.Io.Writer) !void {
    try w.writeAll("[");
}

pub fn writeProjectArrayClose(w: *std.Io.Writer) !void {
    try w.writeAll("]");
}

test "empty project array" {
    var buf: [4]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeProjectArrayOpen(&w);
    try writeProjectArrayClose(&w);
    try std.testing.expectEqualStrings("[]", w.buffered());
}

/// Escape a string for JSON. Output to `w`. Handles `"`, `\`, control chars.
pub fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
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

/// Write a Project as JSON matching the UI's ProjectSchema:
///   id, name, description (nullable), created_at, last_opened_at,
///   chargesheet: { filename, page_count, size_bytes },
///   slice_count, extraction_count, prompt_count, current_stage
pub fn writeProject(w: *std.Io.Writer, project: Project) !void {
    try w.writeAll("{\"id\":");
    try writeJsonString(w, project.id);
    try w.writeAll(",\"name\":");
    try writeJsonString(w, project.name);
    try w.writeAll(",\"description\":");
    if (project.description) |d| {
        try writeJsonString(w, d);
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"created_at\":");
    try writeJsonString(w, project.created_at);
    try w.writeAll(",\"last_opened_at\":");
    try writeJsonString(w, project.last_opened_at);
    try w.writeAll(",\"chargesheet\":{\"filename\":");
    try writeJsonString(w, project.chargesheet_filename);
    try w.print(",\"page_count\":{d},\"size_bytes\":{d}", .{
        project.chargesheet_page_count,
        project.chargesheet_size_bytes,
    });
    try w.print("}},\"slice_count\":{d},\"extraction_count\":{d},\"prompt_count\":{d}", .{
        project.slice_count,
        project.extraction_count,
        project.prompt_count,
    });
    try w.writeAll(",\"current_stage\":");
    try writeJsonString(w, projects_db.currentStage(project));
    try w.writeAll("}");
}

test "writeProject matches UI schema" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const p: Project = .{
        .id = "proj_abc",
        .name = "Case 42",
        .description = "Mock",
        .created_at = "2026-05-25T10:00:00Z",
        .last_opened_at = "2026-05-25T10:00:00Z",
        .chargesheet_filename = "case42.pdf",
        .chargesheet_page_count = 12,
        .chargesheet_size_bytes = 4096,
        .slice_count = 0,
        .extraction_count = 0,
        .prompt_count = 0,
    };
    try writeProject(&w, p);
    try std.testing.expectEqualStrings(
        \\{"id":"proj_abc","name":"Case 42","description":"Mock","created_at":"2026-05-25T10:00:00Z","last_opened_at":"2026-05-25T10:00:00Z","chargesheet":{"filename":"case42.pdf","page_count":12,"size_bytes":4096},"slice_count":0,"extraction_count":0,"prompt_count":0,"current_stage":"slice"}
    , w.buffered());
}

test "writeProject with null description" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const p: Project = .{
        .id = "proj_x", .name = "X", .description = null,
        .created_at = "t", .last_opened_at = "t",
        .chargesheet_filename = "x.pdf", .chargesheet_page_count = 1, .chargesheet_size_bytes = 0,
        .slice_count = 0, .extraction_count = 0, .prompt_count = 0,
    };
    try writeProject(&w, p);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"description\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"current_stage\":\"slice\"") != null);
}

test "writeJsonString escapes quotes and backslashes" {
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeJsonString(&w, "he said \"hi\\there\"");
    try std.testing.expectEqualStrings(
        \\"he said \"hi\\there\""
    , w.buffered());
}

/// Write the response body of POST /jobs/slice.
pub fn writeJobCreated(w: *std.Io.Writer, job_id: []const u8) !void {
    try w.writeAll("{\"job_id\":");
    try writeJsonString(w, job_id);
    try w.writeAll(",\"status\":\"queued\"}");
}

/// Write a single slice listing item.
pub fn writeSliceListingItem(
    w: *std.Io.Writer,
    filename: []const u8,
    start_page: u32,
    end_page: u32,
    size_bytes: u64,
    created_at: []const u8,
) !void {
    try w.writeAll("{\"filename\":");
    try writeJsonString(w, filename);
    try w.print(",\"page_range\":[{d},{d}],\"size_bytes\":{d}", .{ start_page, end_page, size_bytes });
    try w.writeAll(",\"created_at\":");
    try writeJsonString(w, created_at);
    try w.writeAll("}");
}

/// Open GET /slices response: {"slices":[
pub fn writeSliceListingArrayOpen(w: *std.Io.Writer) !void {
    try w.writeAll("{\"slices\":[");
}

/// Close GET /slices response: ]}
pub fn writeSliceListingArrayClose(w: *std.Io.Writer) !void {
    try w.writeAll("]}");
}

/// Write GET /jobs/:id response. `results_json` is the raw JSON string stored
/// in the `jobs.results` column (already serialized at write-time); spliced
/// in unescaped. `error_msg` is the `jobs.error` column (nullable).
pub fn writeJob(
    w: *std.Io.Writer,
    job_id: []const u8,
    status: []const u8,
    progress: f64,
    results_json: ?[]const u8,
    error_msg: ?[]const u8,
) !void {
    try w.writeAll("{\"job_id\":");
    try writeJsonString(w, job_id);
    try w.writeAll(",\"status\":");
    try writeJsonString(w, status);
    try w.print(",\"progress\":{d}", .{progress});
    try w.writeAll(",\"results\":");
    if (results_json) |r| {
        try w.writeAll(r);
    } else {
        try w.writeAll("[]");
    }
    try w.writeAll(",\"error\":");
    if (error_msg) |e| {
        try writeJsonString(w, e);
    } else {
        try w.writeAll("null");
    }
    try w.writeAll("}");
}

test "writeJobCreated matches UI schema" {
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeJobCreated(&w, "job_abc");
    try std.testing.expectEqualStrings(
        \\{"job_id":"job_abc","status":"queued"}
    , w.buffered());
}

test "writeJob with null results renders as empty array" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeJob(&w, "job_xyz", "completed", 1.0, null, null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"results\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"error\":null") != null);
}

test "writeJob with embedded results JSON" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeJob(&w, "job_1", "failed", 1.0, "[{\"filename\":\"a.pdf\",\"status\":\"failed\",\"page_range\":[1,3],\"size_bytes\":0,\"error\":\"oops\"}]", "All slices failed");
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"results\":[{\"filename\":\"a.pdf\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\"error\":\"All slices failed\"") != null);
}

test "writeSliceListingItem matches UI schema" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeSliceListingItem(&w, "intro.pdf", 1, 3, 2048, "2026-05-25T10:00:00Z");
    try std.testing.expectEqualStrings(
        \\{"filename":"intro.pdf","page_range":[1,3],"size_bytes":2048,"created_at":"2026-05-25T10:00:00Z"}
    , w.buffered());
}
