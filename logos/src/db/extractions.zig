const std = @import("std");
const Allocator = std.mem.Allocator;
const Db = @import("db.zig").Db;
const errors = @import("errors.zig");
const test_helpers = @import("test_helpers.zig");
const slices = @import("slices.zig");

pub const Extraction = struct {
    project_id: []const u8,
    slice_filename: []const u8,
    markdown_path: []const u8,
    meta_path: []const u8,
    model: []const u8,
    pages: u32,
    page_markers_found: u32,
    input_tokens: ?i64 = null,
    output_tokens: ?i64 = null,
    input_cost_usd: ?f64 = null,
    output_cost_usd: ?f64 = null,
    latency_s: f64,
    created_at: []const u8,

    pub fn deinit(self: *Extraction, gpa: Allocator) void {
        gpa.free(self.project_id);
        gpa.free(self.slice_filename);
        gpa.free(self.markdown_path);
        gpa.free(self.meta_path);
        gpa.free(self.model);
        gpa.free(self.created_at);
    }
};

pub fn deinitList(list: []Extraction, gpa: Allocator) void {
    for (list) |*e| e.deinit(gpa);
    gpa.free(list);
}

/// Insert or overwrite the extraction for a given (project_id, slice_filename).
/// PK conflict updates the row in place — matches the "re-run overwrites" idempotency invariant.
pub fn upsert(db: *Db, gpa: Allocator, e: Extraction) !void {
    _ = gpa;
    db.conn.exec(
        \\INSERT INTO extractions
        \\  (project_id, slice_filename, markdown_path, meta_path, model,
        \\   pages, page_markers_found, input_tokens, output_tokens,
        \\   input_cost_usd, output_cost_usd, latency_s, created_at)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        \\ON CONFLICT(project_id, slice_filename) DO UPDATE SET
        \\  markdown_path      = excluded.markdown_path,
        \\  meta_path          = excluded.meta_path,
        \\  model              = excluded.model,
        \\  pages              = excluded.pages,
        \\  page_markers_found = excluded.page_markers_found,
        \\  input_tokens       = excluded.input_tokens,
        \\  output_tokens      = excluded.output_tokens,
        \\  input_cost_usd     = excluded.input_cost_usd,
        \\  output_cost_usd    = excluded.output_cost_usd,
        \\  latency_s          = excluded.latency_s,
        \\  created_at         = excluded.created_at
    , .{
        e.project_id,
        e.slice_filename,
        e.markdown_path,
        e.meta_path,
        e.model,
        @as(i64, @intCast(e.pages)),
        @as(i64, @intCast(e.page_markers_found)),
        e.input_tokens,
        e.output_tokens,
        e.input_cost_usd,
        e.output_cost_usd,
        e.latency_s,
        e.created_at,
    }) catch |err| return errors.mapConstraintErr(err);
}

pub fn getByKey(
    db: *Db,
    gpa: Allocator,
    project_id: []const u8,
    slice_filename: []const u8,
) !?Extraction {
    const row = (try db.conn.row(
        \\SELECT project_id, slice_filename, markdown_path, meta_path, model,
        \\       pages, page_markers_found, input_tokens, output_tokens,
        \\       input_cost_usd, output_cost_usd, latency_s, created_at
        \\FROM extractions WHERE project_id = ? AND slice_filename = ?
    , .{ project_id, slice_filename })) orelse return null;
    defer row.deinit();

    return try rowToExtraction(row, gpa);
}

pub fn listByProject(db: *Db, gpa: Allocator, project_id: []const u8) ![]Extraction {
    var list: std.ArrayList(Extraction) = .empty;
    errdefer {
        for (list.items) |*e| e.deinit(gpa);
        list.deinit(gpa);
    }

    var rows = try db.conn.rows(
        \\SELECT project_id, slice_filename, markdown_path, meta_path, model,
        \\       pages, page_markers_found, input_tokens, output_tokens,
        \\       input_cost_usd, output_cost_usd, latency_s, created_at
        \\FROM extractions WHERE project_id = ? ORDER BY created_at ASC
    , .{project_id});
    defer rows.deinit();

    // zqlite 0.0.1 cursor protocol: `next()` returns `?Row` (not `!?Row`).
    // Errors during iteration are surfaced via `rows.err`, checked after the loop.
    while (rows.next()) |row| {
        const ex = try rowToExtraction(row, gpa);
        try list.append(gpa, ex);
    }
    if (rows.err) |e| return e;

    return list.toOwnedSlice(gpa);
}

fn rowToExtraction(row: anytype, gpa: Allocator) !Extraction {
    const pid = try gpa.dupe(u8, row.text(0));
    errdefer gpa.free(pid);
    const sf = try gpa.dupe(u8, row.text(1));
    errdefer gpa.free(sf);
    const md = try gpa.dupe(u8, row.text(2));
    errdefer gpa.free(md);
    const mp = try gpa.dupe(u8, row.text(3));
    errdefer gpa.free(mp);
    const mdl = try gpa.dupe(u8, row.text(4));
    errdefer gpa.free(mdl);
    const created = try gpa.dupe(u8, row.text(12));
    errdefer gpa.free(created);

    // zqlite 0.0.1: use nullableInt/nullableFloat for nullable INTEGER/REAL columns.
    // row.isNull() does not exist in this version.
    return .{
        .project_id = pid,
        .slice_filename = sf,
        .markdown_path = md,
        .meta_path = mp,
        .model = mdl,
        .pages = @intCast(row.int(5)),
        .page_markers_found = @intCast(row.int(6)),
        .input_tokens = row.nullableInt(7),
        .output_tokens = row.nullableInt(8),
        .input_cost_usd = row.nullableFloat(9),
        .output_cost_usd = row.nullableFloat(10),
        .latency_s = row.float(11),
        .created_at = created,
    };
}

test "upsert + getByKey round-trip" {
    var db = try Db.open(":memory:");
    defer db.close();
    const gpa = std.testing.allocator;

    try test_helpers.insertProject(&db, "p1");
    try slices.insert(&db, gpa, .{
        .project_id = "p1",
        .filename = "annexure-i.pdf",
        .start_page = 1,
        .end_page = 5,
        .size_bytes = 1024,
        .kind = .annexure,
        .kind_key = "i",
        .created_at = "2026-05-28T00:00:00Z",
    });

    try upsert(&db, gpa, .{
        .project_id = "p1",
        .slice_filename = "annexure-i.pdf",
        .markdown_path = "/tmp/a.md",
        .meta_path = "/tmp/a.meta.json",
        .model = "gemini-2.5-flash",
        .pages = 5,
        .page_markers_found = 5,
        .input_tokens = 1000,
        .output_tokens = 5000,
        .input_cost_usd = 0.0003,
        .output_cost_usd = 0.0125,
        .latency_s = 12.5,
        .created_at = "2026-05-28T00:01:00Z",
    });

    var got = (try getByKey(&db, gpa, "p1", "annexure-i.pdf")).?;
    defer got.deinit(gpa);
    try std.testing.expectEqualStrings("/tmp/a.md", got.markdown_path);
    try std.testing.expectEqual(@as(u32, 5), got.pages);
    try std.testing.expectEqual(@as(?i64, 1000), got.input_tokens);
    try std.testing.expectApproxEqAbs(@as(f64, 12.5), got.latency_s, 0.001);
}

test "upsert overwrites on conflict" {
    var db = try Db.open(":memory:");
    defer db.close();
    const gpa = std.testing.allocator;

    try test_helpers.insertProject(&db, "p1");
    try slices.insert(&db, gpa, .{
        .project_id = "p1",
        .filename = "annexure-i.pdf",
        .start_page = 1,
        .end_page = 5,
        .size_bytes = 1024,
        .kind = .annexure,
        .kind_key = "i",
        .created_at = "2026-05-28T00:00:00Z",
    });

    const base = Extraction{
        .project_id = "p1",
        .slice_filename = "annexure-i.pdf",
        .markdown_path = "/old.md",
        .meta_path = "/old.json",
        .model = "gemini-2.5-flash",
        .pages = 5,
        .page_markers_found = 5,
        .latency_s = 1.0,
        .created_at = "2026-05-28T00:01:00Z",
    };
    try upsert(&db, gpa, base);

    var updated = base;
    updated.markdown_path = "/new.md";
    updated.latency_s = 9.9;
    try upsert(&db, gpa, updated);

    var got = (try getByKey(&db, gpa, "p1", "annexure-i.pdf")).?;
    defer got.deinit(gpa);
    try std.testing.expectEqualStrings("/new.md", got.markdown_path);
    try std.testing.expectApproxEqAbs(@as(f64, 9.9), got.latency_s, 0.001);

    // Still exactly one row.
    const cnt = (try db.conn.row("SELECT count(*) FROM extractions", .{})).?;
    defer cnt.deinit();
    try std.testing.expectEqual(@as(i64, 1), cnt.int(0));
}

test "deleting a slice cascades to extractions" {
    var db = try Db.open(":memory:");
    defer db.close();
    const gpa = std.testing.allocator;

    try test_helpers.insertProject(&db, "p1");
    try slices.insert(&db, gpa, .{
        .project_id = "p1",
        .filename = "annexure-i.pdf",
        .start_page = 1,
        .end_page = 5,
        .size_bytes = 1024,
        .kind = .annexure,
        .kind_key = "i",
        .created_at = "2026-05-28T00:00:00Z",
    });
    try upsert(&db, gpa, .{
        .project_id = "p1",
        .slice_filename = "annexure-i.pdf",
        .markdown_path = "/x.md",
        .meta_path = "/x.json",
        .model = "gemini-2.5-flash",
        .pages = 1,
        .page_markers_found = 1,
        .latency_s = 1.0,
        .created_at = "2026-05-28T00:01:00Z",
    });
    if (try getByKey(&db, gpa, "p1", "annexure-i.pdf")) |ex| { var mex = ex; mex.deinit(gpa); }

    try db.conn.exec("DELETE FROM slices WHERE project_id=? AND filename=?", .{ "p1", "annexure-i.pdf" });

    try std.testing.expect((try getByKey(&db, gpa, "p1", "annexure-i.pdf")) == null);
}
