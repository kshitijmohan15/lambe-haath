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

pub const ProjectTotals = struct {
    project_id: []const u8,
    ocr_cost_usd: f64,
    prompt_cost_usd: f64,
    total_in_tokens: i64,
    total_out_tokens: i64,
    ocr_runs: i64,
    prompt_runs: i64,

    pub fn deinit(self: *ProjectTotals, gpa: Allocator) void {
        gpa.free(self.project_id);
    }
};

pub fn deinitProjectList(list: []ProjectTotals, gpa: Allocator) void {
    for (list) |*p| p.deinit(gpa);
    gpa.free(list);
}

/// Per-project rollup. Returns zeros for a project with no extractions and no prompt_outputs.
pub fn perProject(db: *Db, gpa: Allocator, project_id: []const u8) !ProjectTotals {
    const row = (try db.conn.row(
        \\SELECT
        \\  (SELECT coalesce(sum(coalesce(input_cost_usd,0) + coalesce(output_cost_usd,0)), 0) FROM extractions    WHERE project_id=?) AS ocr_cost,
        \\  (SELECT coalesce(sum(coalesce(input_cost_usd,0) + coalesce(output_cost_usd,0)), 0) FROM prompt_outputs WHERE project_id=?) AS prompt_cost,
        \\  (SELECT coalesce(sum(input_tokens),  0) FROM extractions    WHERE project_id=?) +
        \\  (SELECT coalesce(sum(input_tokens),  0) FROM prompt_outputs WHERE project_id=?) AS total_in,
        \\  (SELECT coalesce(sum(output_tokens), 0) FROM extractions    WHERE project_id=?) +
        \\  (SELECT coalesce(sum(output_tokens), 0) FROM prompt_outputs WHERE project_id=?) AS total_out,
        \\  (SELECT count(*) FROM extractions    WHERE project_id=?) AS ocr_runs,
        \\  (SELECT count(*) FROM prompt_outputs WHERE project_id=?) AS prompt_runs
    , .{ project_id, project_id, project_id, project_id, project_id, project_id, project_id, project_id })) orelse return error.UnexpectedNullRow;
    defer row.deinit();

    const pid = try gpa.dupe(u8, project_id);
    return .{
        .project_id = pid,
        .ocr_cost_usd = row.float(0),
        .prompt_cost_usd = row.float(1),
        .total_in_tokens = row.int(2),
        .total_out_tokens = row.int(3),
        .ocr_runs = row.int(4),
        .prompt_runs = row.int(5),
    };
}

/// Top N projects by total cost (ocr + prompt). Used by the global /stats overview.
pub fn topCostProjects(db: *Db, gpa: Allocator, limit: u32) ![]ProjectTotals {
    var list: std.ArrayList(ProjectTotals) = .empty;
    errdefer {
        for (list.items) |*p| p.deinit(gpa);
        list.deinit(gpa);
    }

    var rows = try db.conn.rows(
        \\WITH all_costs AS (
        \\  SELECT project_id,
        \\         coalesce(input_cost_usd,0) + coalesce(output_cost_usd,0) AS c,
        \\         coalesce(input_tokens, 0) AS in_t,
        \\         coalesce(output_tokens, 0) AS out_t,
        \\         'ocr' AS kind
        \\  FROM extractions
        \\  UNION ALL
        \\  SELECT project_id,
        \\         coalesce(input_cost_usd,0) + coalesce(output_cost_usd,0),
        \\         coalesce(input_tokens, 0),
        \\         coalesce(output_tokens, 0),
        \\         'prompt'
        \\  FROM prompt_outputs
        \\)
        \\SELECT project_id,
        \\       coalesce(sum(CASE WHEN kind='ocr'    THEN c END), 0) AS ocr_cost,
        \\       coalesce(sum(CASE WHEN kind='prompt' THEN c END), 0) AS prompt_cost,
        \\       sum(in_t)  AS total_in,
        \\       sum(out_t) AS total_out,
        \\       sum(CASE WHEN kind='ocr'    THEN 1 ELSE 0 END) AS ocr_runs,
        \\       sum(CASE WHEN kind='prompt' THEN 1 ELSE 0 END) AS prompt_runs
        \\FROM all_costs
        \\GROUP BY project_id
        \\ORDER BY (ocr_cost + prompt_cost) DESC, project_id ASC
        \\LIMIT ?
    , .{@as(i64, @intCast(limit))});
    defer rows.deinit();

    while (rows.next()) |row| {
        const pid = try gpa.dupe(u8, row.text(0));
        errdefer gpa.free(pid);
        try list.append(gpa, .{
            .project_id = pid,
            .ocr_cost_usd = row.float(1),
            .prompt_cost_usd = row.float(2),
            .total_in_tokens = row.int(3),
            .total_out_tokens = row.int(4),
            .ocr_runs = row.int(5),
            .prompt_runs = row.int(6),
        });
    }
    if (rows.err) |e| return e;
    return try list.toOwnedSlice(gpa);
}

test "perProject returns zeros for project with no rows" {
    var db = try Db.open(":memory:");
    defer db.close();
    const gpa = std.testing.allocator;
    try test_helpers.insertProject(&db, "empty");

    var t = try perProject(&db, gpa, "empty");
    defer t.deinit(gpa);
    try std.testing.expectEqualStrings("empty", t.project_id);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), t.ocr_cost_usd, 0.0001);
    try std.testing.expectEqual(@as(i64, 0), t.total_in_tokens);
}

test "topCostProjects orders by total cost desc" {
    var db = try Db.open(":memory:");
    defer db.close();
    const gpa = std.testing.allocator;

    try test_helpers.insertProject(&db, "p_cheap");
    try test_helpers.insertProject(&db, "p_expensive");
    try slices.insert(&db, gpa, .{
        .project_id = "p_cheap", .filename = "a.pdf", .start_page = 1, .end_page = 1,
        .size_bytes = 1, .kind = .annexure, .kind_key = "i",
        .created_at = "2026-05-28T00:00:00Z",
    });
    try slices.insert(&db, gpa, .{
        .project_id = "p_expensive", .filename = "a.pdf", .start_page = 1, .end_page = 1,
        .size_bytes = 1, .kind = .annexure, .kind_key = "i",
        .created_at = "2026-05-28T00:00:00Z",
    });
    try extractions.upsert(&db, gpa, .{
        .project_id = "p_cheap", .slice_filename = "a.pdf",
        .markdown_path = "/c.md", .meta_path = "/c.json", .model = "g",
        .pages = 1, .page_markers_found = 1,
        .input_cost_usd = 0.10, .output_cost_usd = 0.10,
        .latency_s = 1.0, .created_at = "2026-05-28T00:00:00Z",
    });
    try extractions.upsert(&db, gpa, .{
        .project_id = "p_expensive", .slice_filename = "a.pdf",
        .markdown_path = "/e.md", .meta_path = "/e.json", .model = "g",
        .pages = 1, .page_markers_found = 1,
        .input_cost_usd = 5.0, .output_cost_usd = 5.0,
        .latency_s = 1.0, .created_at = "2026-05-28T00:00:00Z",
    });

    const list = try topCostProjects(&db, gpa, 10);
    defer deinitProjectList(list, gpa);
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("p_expensive", list[0].project_id);
    try std.testing.expectEqualStrings("p_cheap", list[1].project_id);
}

pub const SlowJob = struct {
    kind: []const u8, // 'extraction' or 'prompt'
    project_id: []const u8,
    subject: []const u8, // slice_filename for OCR, prompt_name for prompts
    model: []const u8,
    latency_s: f64,
    total_tokens: i64,
    created_at: []const u8,

    pub fn deinit(self: *SlowJob, gpa: Allocator) void {
        gpa.free(self.kind);
        gpa.free(self.project_id);
        gpa.free(self.subject);
        gpa.free(self.model);
        gpa.free(self.created_at);
    }
};

pub fn deinitSlowJobList(list: []SlowJob, gpa: Allocator) void {
    for (list) |*s| s.deinit(gpa);
    gpa.free(list);
}

pub fn slowJobs(db: *Db, gpa: Allocator, limit: u32) ![]SlowJob {
    var list: std.ArrayList(SlowJob) = .empty;
    errdefer {
        for (list.items) |*s| s.deinit(gpa);
        list.deinit(gpa);
    }

    var rows = try db.conn.rows(
        \\SELECT 'extraction' AS kind, project_id, slice_filename AS subject, model,
        \\       latency_s, coalesce(input_tokens,0) + coalesce(output_tokens,0) AS total_tokens, created_at
        \\FROM extractions
        \\UNION ALL
        \\SELECT 'prompt' AS kind, project_id, prompt_name AS subject, model,
        \\       latency_s, coalesce(input_tokens,0) + coalesce(output_tokens,0) AS total_tokens, created_at
        \\FROM prompt_outputs
        \\ORDER BY latency_s DESC
        \\LIMIT ?
    , .{@as(i64, @intCast(limit))});
    defer rows.deinit();

    while (rows.next()) |row| {
        const kind = try gpa.dupe(u8, row.text(0));
        errdefer gpa.free(kind);
        const pid = try gpa.dupe(u8, row.text(1));
        errdefer gpa.free(pid);
        const subject = try gpa.dupe(u8, row.text(2));
        errdefer gpa.free(subject);
        const model = try gpa.dupe(u8, row.text(3));
        errdefer gpa.free(model);
        const created = try gpa.dupe(u8, row.text(6));
        errdefer gpa.free(created);
        try list.append(gpa, .{
            .kind = kind,
            .project_id = pid,
            .subject = subject,
            .model = model,
            .latency_s = row.float(4),
            .total_tokens = row.int(5),
            .created_at = created,
        });
    }
    if (rows.err) |e| return e;
    return try list.toOwnedSlice(gpa);
}

pub const DayBucket = struct {
    day: []const u8, // 'YYYY-MM-DD'
    in_tokens: i64,
    out_tokens: i64,
    cost_usd: f64,

    pub fn deinit(self: *DayBucket, gpa: Allocator) void {
        gpa.free(self.day);
    }
};

pub fn deinitTimeseries(list: []DayBucket, gpa: Allocator) void {
    for (list) |*d| d.deinit(gpa);
    gpa.free(list);
}

/// Daily aggregates between [from, to] inclusive. Both bounds are 'YYYY-MM-DD' strings.
/// Returns ascending by day. Days with no activity are omitted (UI fills gaps with zero if it wants).
pub fn timeseries(db: *Db, gpa: Allocator, from: []const u8, to: []const u8) ![]DayBucket {
    var list: std.ArrayList(DayBucket) = .empty;
    errdefer {
        for (list.items) |*d| d.deinit(gpa);
        list.deinit(gpa);
    }

    var rows = try db.conn.rows(
        \\SELECT date(created_at) AS day,
        \\       coalesce(sum(input_tokens), 0) AS in_tokens,
        \\       coalesce(sum(output_tokens), 0) AS out_tokens,
        \\       coalesce(sum(coalesce(input_cost_usd,0) + coalesce(output_cost_usd,0)), 0) AS cost
        \\FROM (
        \\  SELECT created_at, input_tokens, output_tokens, input_cost_usd, output_cost_usd FROM extractions
        \\  UNION ALL
        \\  SELECT created_at, input_tokens, output_tokens, input_cost_usd, output_cost_usd FROM prompt_outputs
        \\)
        \\WHERE date(created_at) BETWEEN ? AND ?
        \\GROUP BY day
        \\ORDER BY day ASC
    , .{ from, to });
    defer rows.deinit();

    while (rows.next()) |row| {
        const day = try gpa.dupe(u8, row.text(0));
        errdefer gpa.free(day);
        try list.append(gpa, .{
            .day = day,
            .in_tokens = row.int(1),
            .out_tokens = row.int(2),
            .cost_usd = row.float(3),
        });
    }
    if (rows.err) |e| return e;
    return try list.toOwnedSlice(gpa);
}

test "slowJobs orders by latency desc and tags kind" {
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
        .markdown_path = "/x.md", .meta_path = "/x.json", .model = "g",
        .pages = 1, .page_markers_found = 1,
        .input_tokens = 100, .output_tokens = 200,
        .latency_s = 3.5, .created_at = "2026-05-28T00:00:00Z",
    });
    try prompt_outputs.upsert(&db, gpa, .{
        .project_id = "p1", .prompt_name = "x",
        .markdown_path = "/p.md", .model = "claude-sonnet-4-6",
        .input_tokens = 1, .output_tokens = 1,
        .latency_s = 99.0, .warnings_json = "[]",
        .created_at = "2026-05-28T00:00:00Z",
    });

    const list = try slowJobs(&db, gpa, 10);
    defer deinitSlowJobList(list, gpa);
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("prompt", list[0].kind);
    try std.testing.expectApproxEqAbs(@as(f64, 99.0), list[0].latency_s, 0.001);
    try std.testing.expectEqualStrings("extraction", list[1].kind);
}

test "timeseries buckets by day, respects from/to" {
    var db = try Db.open(":memory:");
    defer db.close();
    const gpa = std.testing.allocator;

    try test_helpers.insertProject(&db, "p1");
    try slices.insert(&db, gpa, .{
        .project_id = "p1", .filename = "a.pdf", .start_page = 1, .end_page = 1,
        .size_bytes = 1, .kind = .annexure, .kind_key = "i",
        .created_at = "2026-05-25T00:00:00Z",
    });
    try slices.insert(&db, gpa, .{
        .project_id = "p1", .filename = "b.pdf", .start_page = 1, .end_page = 1,
        .size_bytes = 1, .kind = .annexure, .kind_key = "ii",
        .created_at = "2026-05-27T00:00:00Z",
    });
    try extractions.upsert(&db, gpa, .{
        .project_id = "p1", .slice_filename = "a.pdf",
        .markdown_path = "/a.md", .meta_path = "/a.json", .model = "g",
        .pages = 1, .page_markers_found = 1,
        .input_tokens = 100, .output_tokens = 200,
        .input_cost_usd = 0.01, .output_cost_usd = 0.02,
        .latency_s = 1.0, .created_at = "2026-05-25T10:00:00Z",
    });
    try extractions.upsert(&db, gpa, .{
        .project_id = "p1", .slice_filename = "b.pdf",
        .markdown_path = "/b.md", .meta_path = "/b.json", .model = "g",
        .pages = 1, .page_markers_found = 1,
        .input_tokens = 50, .output_tokens = 100,
        .input_cost_usd = 0.005, .output_cost_usd = 0.01,
        .latency_s = 1.0, .created_at = "2026-05-27T10:00:00Z",
    });

    const list = try timeseries(&db, gpa, "2026-05-26", "2026-05-28");
    defer deinitTimeseries(list, gpa);
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqualStrings("2026-05-27", list[0].day);
    try std.testing.expectEqual(@as(i64, 50), list[0].in_tokens);
}
