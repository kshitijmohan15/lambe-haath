const std = @import("std");
const Allocator = std.mem.Allocator;
const Db = @import("db.zig").Db;
const test_helpers = @import("test_helpers.zig");
const slices = @import("slices.zig");
const extractions = @import("extractions.zig");
const prompt_outputs = @import("prompt_outputs.zig");

/// Per-kind ('ocr' | 'prompt') rollup over a set of rows.
pub const KindTotals = struct {
    kind: []const u8, // 'ocr' or 'prompt' — string literal, no allocation
    runs: i64,
    in_tokens: i64,
    out_tokens: i64,
    cost_usd: f64,
    avg_latency_s: f64,
};

pub const LifetimeTotals = struct {
    ocr: KindTotals,
    prompt: KindTotals,
};

/// Lifetime aggregates across all projects, broken into OCR and prompt kinds.
/// NULL token/cost values aggregate as 0 (coalesce in SQL).
pub fn lifetimeTotals(db: *Db) !LifetimeTotals {
    const ocr = try queryOneKind(db, "extractions", "ocr");
    const prompt = try queryOneKind(db, "prompt_outputs", "prompt");
    return .{ .ocr = ocr, .prompt = prompt };
}

fn queryOneKind(db: *Db, table: []const u8, kind: []const u8) !KindTotals {
    // Build the SQL with the table name spliced in — table name is a code
    // literal, not user input, so the format-string interpolation is safe.
    var sql_buf: [512]u8 = undefined;
    const sql = try std.fmt.bufPrint(&sql_buf,
        \\SELECT count(*),
        \\       coalesce(sum(input_tokens), 0),
        \\       coalesce(sum(output_tokens), 0),
        \\       coalesce(sum(coalesce(input_cost_usd,0) + coalesce(output_cost_usd,0)), 0),
        \\       coalesce(avg(latency_s), 0)
        \\FROM {s}
    , .{table});

    const row = (try db.conn.row(sql, .{})) orelse return error.UnexpectedNullRow;
    defer row.deinit();
    return .{
        .kind = kind,
        .runs = row.int(0),
        .in_tokens = row.int(1),
        .out_tokens = row.int(2),
        .cost_usd = row.float(3),
        .avg_latency_s = row.float(4),
    };
}

test "lifetimeTotals empty DB returns zeros" {
    var db = try Db.open(":memory:");
    defer db.close();

    const t = try lifetimeTotals(&db);
    try std.testing.expectEqualStrings("ocr", t.ocr.kind);
    try std.testing.expectEqual(@as(i64, 0), t.ocr.runs);
    try std.testing.expectEqual(@as(i64, 0), t.prompt.runs);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), t.ocr.cost_usd, 0.0001);
}

test "lifetimeTotals sums tokens, cost, and avg latency" {
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
    try extractions.upsert(&db, gpa, .{
        .project_id = "p1",
        .slice_filename = "annexure-i.pdf",
        .markdown_path = "/x.md",
        .meta_path = "/x.json",
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
    try prompt_outputs.upsert(&db, gpa, .{
        .project_id = "p1",
        .prompt_name = "charge_memo_analysis",
        .markdown_path = "/p.md",
        .model = "claude-sonnet-4-6",
        .input_tokens = 48211,
        .output_tokens = 9876,
        .input_cost_usd = 0.1446,
        .output_cost_usd = 0.1481,
        .latency_s = 22.4,
        .warnings_json = "[]",
        .created_at = "2026-05-28T00:02:00Z",
    });

    const t = try lifetimeTotals(&db);
    try std.testing.expectEqual(@as(i64, 1), t.ocr.runs);
    try std.testing.expectEqual(@as(i64, 1000), t.ocr.in_tokens);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0128), t.ocr.cost_usd, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 12.5), t.ocr.avg_latency_s, 0.001);
    try std.testing.expectEqual(@as(i64, 1), t.prompt.runs);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2927), t.prompt.cost_usd, 0.0001);
}

/// Per-model rollup across both extractions and prompt_outputs.
pub const ModelTotals = struct {
    model: []const u8,
    runs: i64,
    in_tokens: i64,
    out_tokens: i64,
    cost_usd: f64,

    pub fn deinit(self: *ModelTotals, gpa: Allocator) void {
        gpa.free(self.model);
    }
};

pub fn deinitModelList(list: []ModelTotals, gpa: Allocator) void {
    for (list) |*m| m.deinit(gpa);
    gpa.free(list);
}

/// Per-model usage across all extractions and prompt_outputs.
/// Sorted by cost_usd descending. NULL costs aggregate as 0.
pub fn perModel(db: *Db, gpa: Allocator) ![]ModelTotals {
    var list: std.ArrayList(ModelTotals) = .empty;
    errdefer {
        for (list.items) |*m| m.deinit(gpa);
        list.deinit(gpa);
    }

    var rows = try db.conn.rows(
        \\SELECT model,
        \\       count(*) AS runs,
        \\       coalesce(sum(input_tokens), 0) AS in_tok,
        \\       coalesce(sum(output_tokens), 0) AS out_tok,
        \\       coalesce(sum(coalesce(input_cost_usd,0) + coalesce(output_cost_usd,0)), 0) AS cost
        \\FROM (
        \\  SELECT model, input_tokens, output_tokens, input_cost_usd, output_cost_usd FROM extractions
        \\  UNION ALL
        \\  SELECT model, input_tokens, output_tokens, input_cost_usd, output_cost_usd FROM prompt_outputs
        \\)
        \\GROUP BY model
        \\ORDER BY cost DESC, model ASC
    , .{});
    defer rows.deinit();

    while (rows.next()) |row| {
        const model = try gpa.dupe(u8, row.text(0));
        errdefer gpa.free(model);
        try list.append(gpa, .{
            .model = model,
            .runs = row.int(1),
            .in_tokens = row.int(2),
            .out_tokens = row.int(3),
            .cost_usd = row.float(4),
        });
    }
    if (rows.err) |e| return e;
    return try list.toOwnedSlice(gpa);
}

test "perModel groups by model, sorts by cost desc" {
    var db = try Db.open(":memory:");
    defer db.close();
    const gpa = std.testing.allocator;

    try test_helpers.insertProject(&db, "p1");
    try slices.insert(&db, gpa, .{
        .project_id = "p1", .filename = "a.pdf", .start_page = 1, .end_page = 1,
        .size_bytes = 1, .kind = .annexure, .kind_key = "i",
        .created_at = "2026-05-28T00:00:00Z",
    });
    try extractions.upsert(&db, gpa, .{
        .project_id = "p1", .slice_filename = "a.pdf",
        .markdown_path = "/a.md", .meta_path = "/a.json",
        .model = "gemini-2.5-flash",
        .pages = 1, .page_markers_found = 1,
        .input_tokens = 100, .output_tokens = 200,
        .input_cost_usd = 0.001, .output_cost_usd = 0.002,
        .latency_s = 1.0, .created_at = "2026-05-28T00:01:00Z",
    });
    try prompt_outputs.upsert(&db, gpa, .{
        .project_id = "p1", .prompt_name = "x",
        .markdown_path = "/p.md", .model = "claude-sonnet-4-6",
        .input_tokens = 10000, .output_tokens = 20000,
        .input_cost_usd = 0.5, .output_cost_usd = 1.0,
        .latency_s = 1.0, .warnings_json = "[]",
        .created_at = "2026-05-28T00:02:00Z",
    });

    const list = try perModel(&db, gpa);
    defer deinitModelList(list, gpa);

    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("claude-sonnet-4-6", list[0].model);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), list[0].cost_usd, 0.001);
    try std.testing.expectEqualStrings("gemini-2.5-flash", list[1].model);
}
