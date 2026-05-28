//! Handler functions for job cancellation and log retrieval endpoints.
//!
//! Two endpoints:
//!   POST /api/v1/jobs/:id/cancel  → cancel a running job (202 Accepted)
//!   GET  /api/v1/jobs/:id/logs    → list per-job log entries as JSON array

const std = @import("std");
const Allocator = std.mem.Allocator;
const Db = @import("../db/db.zig").Db;
const job_logs_mod = @import("../db/job_logs.zig");
const dispatcher_mod = @import("../agents/dispatcher.zig");
const test_helpers = @import("../db/test_helpers.zig");

// ---------------------------------------------------------------------------
// POST /api/v1/jobs/:id/cancel
// ---------------------------------------------------------------------------

/// Cancel a running job. Returns the HTTP status code to respond with.
///
/// - 202 Accepted  — cancel request was registered with the dispatcher.
/// - 503 Service Unavailable — dispatcher not yet wired (null); harmless
///   until Task 12 wires the dispatcher pointer into the server context.
pub fn handleCancelJob(
    dispatcher: ?*dispatcher_mod.Dispatcher,
    job_id: []const u8,
) !u16 {
    const d = dispatcher orelse return 503;
    try d.cancelJob(job_id);
    return 202;
}

// ---------------------------------------------------------------------------
// GET /api/v1/jobs/:id/logs
// ---------------------------------------------------------------------------

/// Result of GET /api/v1/jobs/:id/logs.
/// `json_body` is an owned heap-allocated JSON array string.
/// Caller must call `deinit`.
pub const GetLogsResult = struct {
    json_body: []u8,

    pub fn deinit(self: GetLogsResult, gpa: Allocator) void {
        gpa.free(self.json_body);
    }
};

pub const GetLogsError = error{ DbError, OutOfMemory };

/// Handle GET /api/v1/jobs/:id/logs.
/// Reads all log rows for `job_id` (empty array if job doesn't exist or has no logs)
/// and serializes them as a JSON array:
///   [{"ts":"...","level":"...","logger":"...","message":"..."}, ...]
///
/// All string values are properly JSON-escaped (quotes, backslashes, newlines, etc.).
pub fn handleGetLogs(
    gpa: Allocator,
    db: *Db,
    job_id: []const u8,
) GetLogsError!GetLogsResult {
    const logs = job_logs_mod.listByJob(db, gpa, job_id) catch return error.DbError;
    defer job_logs_mod.deinitList(logs, gpa);

    // Build JSON into a dynamic buffer so we are not constrained by stack size.
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

    try buf.appendSlice(gpa, "[");
    for (logs, 0..) |log, i| {
        if (i > 0) try buf.appendSlice(gpa, ",");
        try buf.appendSlice(gpa, "{\"ts\":");
        try appendJsonString(gpa, &buf, log.ts);
        try buf.appendSlice(gpa, ",\"level\":");
        try appendJsonString(gpa, &buf, log.level.toText());
        try buf.appendSlice(gpa, ",\"logger\":");
        try appendJsonString(gpa, &buf, log.logger);
        try buf.appendSlice(gpa, ",\"message\":");
        try appendJsonString(gpa, &buf, log.message);
        try buf.appendSlice(gpa, "}");
    }
    try buf.appendSlice(gpa, "]");

    return .{ .json_body = try buf.toOwnedSlice(gpa) };
}

// ---------------------------------------------------------------------------
// Internal: JSON string escaping
// ---------------------------------------------------------------------------

/// Append a JSON string literal (with surrounding quotes) to `buf`, escaping
/// all characters that must be escaped per RFC 8259:
///   " → \"    \ → \\    newline → \n    carriage return → \r    tab → \t
///   other control chars (U+0000–U+001F) → \uXXXX
fn appendJsonString(gpa: Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "getLogs returns empty array for unknown job" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();

    // No job inserted — listByJob returns an empty slice for an unknown job_id.
    const result = try handleGetLogs(gpa, &db, "job_nonexistent");
    defer result.deinit(gpa);

    try std.testing.expectEqualStrings("[]", result.json_body);
}

test "getLogs serializes message with JSON string escaping" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();

    try test_helpers.insertProject(&db, "p1");
    try test_helpers.insertJob(&db, "j1", "p1", "ocr");

    // Insert a log entry whose message contains a double-quote character.
    try job_logs_mod.insert(&db, "j1", "2026-05-28T10:00:00Z", .info, "test_logger", "say \"hello\"");

    const result = try handleGetLogs(gpa, &db, "j1");
    defer result.deinit(gpa);

    // The message "say \"hello\"" must be escaped as "say \\\"hello\\\"" in JSON.
    // Expected JSON: [{"ts":"2026-05-28T10:00:00Z","level":"info","logger":"test_logger","message":"say \"hello\""}]
    const expected =
        \\[{"ts":"2026-05-28T10:00:00Z","level":"info","logger":"test_logger","message":"say \"hello\""}]
    ;
    try std.testing.expectEqualStrings(expected, result.json_body);
}
