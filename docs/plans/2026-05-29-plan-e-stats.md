# Plan E — Stats Endpoints + UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface aggregate token / cost / latency stats from the existing `extractions` and `prompt_outputs` tables through 4 read-only HTTP endpoints, plus a per-project stats panel and a dedicated `/stats` page in the SPA.

**Architecture:** Pure-SQL aggregation against existing tables (cost columns already denormalized at write time per Plan A). Stats endpoints are stateless GET handlers returning small JSON documents. UI consumes via 4 API calls. Daily time series is rendered via Chart.js. Currency is USD only — no INR conversion in v1.

**Tech Stack:** Zig 0.16 (`logos`), SvelteKit 2.57 + Svelte 5.55 + zod + Chart.js (`chargesheet-ui`).

---

## Scope check

- Backend touches `~/projects/lambe-haath/logos/` only — pure reads, no schema changes (the cost columns already exist).
- Frontend touches `~/projects/lambe-haath/chargesheet-ui/` only.
- No agent changes. No DB migrations.
- USD only. Per spec the INR toggle would need a settings page; that's deferred — user chose USD-only for v1.

## File structure

**Backend (`~/projects/lambe-haath/logos/`):**

- Create: `src/db/stats.zig` — pure DB query functions returning rollup structs. ~250 LOC.
- Create: `src/api/handlers_stats.zig` — 4 HTTP handler functions that call into `stats.zig` and JSON-serialize results. ~200 LOC.
- Modify: `src/api/router.zig` — add 4 new route enum values + match arms.
- Modify: `src/api/server.zig` — dispatch the 4 new routes to `handlers_stats`.
- Modify: `src/main.zig` — `_ = @import("db/stats.zig");` so its tests run.

**Frontend (`~/projects/lambe-haath/chargesheet-ui/`):**

- Modify: `src/lib/api/schemas.ts` — add stats response schemas.
- Modify: `src/lib/api/types.ts` — re-export inferred types.
- Create: `src/lib/api/stats.ts` — 4 fetch functions.
- Create: `src/lib/api/stats.test.ts` — unit tests for schema parsing.
- Create: `src/lib/stores/stats.svelte.ts` — single class that loads + caches the 4 responses.
- Create: `src/lib/components/LineChart.svelte` — Chart.js wrapper for the daily series.
- Create: `src/lib/components/StatsPanel.svelte` — per-project mini-stats (totals + per-kind breakdown).
- Modify: `src/routes/projects/[id]/+page.svelte` — add `'stats'` tab.
- Create: `src/routes/stats/+page.svelte` — dedicated global stats page.
- Modify: `src/routes/+page.svelte` — header link to `/stats`.
- Modify: `package.json` — add `chart.js` dep.

---

## Task 1: DB stats module — lifetime totals

**Files:**

- Create: `~/projects/lambe-haath/logos/src/db/stats.zig`
- Modify: `~/projects/lambe-haath/logos/src/main.zig`

This task creates the foundation — `KindTotals` struct + `lifetimeTotals()` returning a single `{ocr, prompt}` pair. Add more queries in later tasks.

- [ ] **Step 1: Write failing test**

Create `src/db/stats.zig`:

```zig
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
```

Then add to `src/main.zig` in the test block:

```zig
_ = @import("db/stats.zig");
```

- [ ] **Step 2: Run tests, verify failure (no impl yet)**

```bash
cd ~/projects/lambe-haath/logos && zig build test 2>&1 | tail -20
```

Expected: tests fail/build fails because… wait, the impl is in Step 1. If you wrote both the test and the impl, the tests should pass on first run. That's fine for this task — the "failing test first" is moot when the function is trivial. Move on to Step 3.

- [ ] **Step 3: Run tests, verify pass**

```bash
cd ~/projects/lambe-haath/logos && zig build test 2>&1 | tail -10
```

Expected: all tests pass, including the two new ones in `stats.zig`.

- [ ] **Step 4: Commit**

```bash
cd ~/projects/lambe-haath
git checkout -b feat/plan-e-stats
git add logos/src/db/stats.zig logos/src/main.zig
git commit -m "db: stats module — lifetime totals query"
```

---

## Task 2: DB stats module — per-model breakdown

**Files:**

- Modify: `~/projects/lambe-haath/logos/src/db/stats.zig`

Returns one row per model, sorted by total cost desc. Used by the global `/stats` page.

- [ ] **Step 1: Add struct + function**

Append to `src/db/stats.zig`:

```zig
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
```

- [ ] **Step 2: Add test**

Append to `src/db/stats.zig`:

```zig
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
```

- [ ] **Step 3: Run tests, verify pass**

```bash
cd ~/projects/lambe-haath/logos && zig build test 2>&1 | tail -10
```

- [ ] **Step 4: Commit**

```bash
git add logos/src/db/stats.zig
git commit -m "db: stats module — per-model breakdown"
```

---

## Task 3: DB stats module — per-project totals

**Files:**

- Modify: `~/projects/lambe-haath/logos/src/db/stats.zig`

Returns the rollup for a single project. Used by both the per-project panel and the global `/stats` page's "top-cost projects" table.

- [ ] **Step 1: Add struct + function**

Append:

```zig
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

/// Per-project rollup. Returns null if the project has no extractions and no prompt_outputs.
/// (Use this if you want to treat "project exists but has no activity" specially.)
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
```

- [ ] **Step 2: Add tests**

Append:

```zig
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
```

- [ ] **Step 3: Run tests + commit**

```bash
cd ~/projects/lambe-haath/logos && zig build test 2>&1 | tail -10
git add logos/src/db/stats.zig
git commit -m "db: stats module — per-project totals + top-cost projects"
```

---

## Task 4: DB stats module — slow jobs + daily time series

**Files:**

- Modify: `~/projects/lambe-haath/logos/src/db/stats.zig`

Two more queries: `slowJobs(limit)` returns the highest-latency runs across both tables; `timeseries(from, to)` returns one row per day.

- [ ] **Step 1: Add structs + functions**

Append:

```zig
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
/// Returns ascending by day. Days with no activity are omitted (UI fills gaps with zero).
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
```

- [ ] **Step 2: Add tests**

Append:

```zig
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
```

- [ ] **Step 3: Run tests + commit**

```bash
cd ~/projects/lambe-haath/logos && zig build test 2>&1 | tail -10
git add logos/src/db/stats.zig
git commit -m "db: stats module — slow jobs + daily time series"
```

---

## Task 5: HTTP handlers — `handlers_stats.zig`

**Files:**

- Create: `~/projects/lambe-haath/logos/src/api/handlers_stats.zig`

This module contains pure logic — given a `*Db`, return raw structs. The actual `*http.Server.Request` work happens in `server.zig` (Task 6).

Why split: matches the existing pattern (`handlers_ocr.zig`, `handlers_prompts.zig` don't touch http types either — they return data, server.zig does the HTTP work). Read those files to mirror style.

- [ ] **Step 1: Create file with thin pass-throughs**

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const Db = @import("../db/db.zig").Db;
const stats = @import("../db/stats.zig");

pub const Overview = struct {
    lifetime: stats.LifetimeTotals,
    per_model: []stats.ModelTotals,
    top_projects: []stats.ProjectTotals,

    pub fn deinit(self: *Overview, gpa: Allocator) void {
        stats.deinitModelList(self.per_model, gpa);
        stats.deinitProjectList(self.top_projects, gpa);
    }
};

pub fn getOverview(db: *Db, gpa: Allocator) !Overview {
    const lifetime = try stats.lifetimeTotals(db);
    const per_model = try stats.perModel(db, gpa);
    errdefer stats.deinitModelList(per_model, gpa);
    const top = try stats.topCostProjects(db, gpa, 10);
    errdefer stats.deinitProjectList(top, gpa);
    return .{ .lifetime = lifetime, .per_model = per_model, .top_projects = top };
}

pub fn getProject(db: *Db, gpa: Allocator, project_id: []const u8) !stats.ProjectTotals {
    return try stats.perProject(db, gpa, project_id);
}

pub fn getTimeseries(db: *Db, gpa: Allocator, from: []const u8, to: []const u8) ![]stats.DayBucket {
    return try stats.timeseries(db, gpa, from, to);
}

pub fn getSlow(db: *Db, gpa: Allocator, limit: u32) ![]stats.SlowJob {
    return try stats.slowJobs(db, gpa, limit);
}

test "handlers_stats compiles" {
    var db = try Db.open(":memory:");
    defer db.close();
    const gpa = std.testing.allocator;

    var ov = try getOverview(&db, gpa);
    defer ov.deinit(gpa);
    try std.testing.expectEqual(@as(i64, 0), ov.lifetime.ocr.runs);
}
```

- [ ] **Step 2: Register in main.zig**

Add to `logos/src/main.zig` test block:

```zig
_ = @import("api/handlers_stats.zig");
```

- [ ] **Step 3: Build + test + commit**

```bash
cd ~/projects/lambe-haath/logos && zig build test 2>&1 | tail -10
git add logos/src/api/handlers_stats.zig logos/src/main.zig
git commit -m "api: handlers_stats — thin wrappers over db/stats"
```

---

## Task 6: Wire routes + JSON serialization in server.zig

**Files:**

- Modify: `~/projects/lambe-haath/logos/src/api/router.zig`
- Modify: `~/projects/lambe-haath/logos/src/api/server.zig`

- [ ] **Step 1: Add 4 routes to `Route` enum + match arms**

Edit `src/api/router.zig`. Add to the `Route` enum (after the existing routes, before `not_found`):

```zig
stats_overview,
stats_project,
stats_timeseries,
stats_slow,
```

In the `match` function, add matchers. They live AFTER the existing project-scoped matchers but BEFORE the catch-all `not_found`. Example placement: after `/api/v1/jobs/...` block and before the trailing `return .{ .route = .not_found };`.

```zig
if (method == .GET and std.mem.eql(u8, path, "/api/v1/stats")) {
    return .{ .route = .stats_overview };
}
if (method == .GET and std.mem.eql(u8, path, "/api/v1/stats/slow")) {
    return .{ .route = .stats_slow };
}
if (method == .GET and std.mem.eql(u8, path, "/api/v1/stats/timeseries")) {
    return .{ .route = .stats_timeseries };
}
const stats_project_prefix = "/api/v1/stats/project/";
if (method == .GET and std.mem.startsWith(u8, path, stats_project_prefix)) {
    const id = path[stats_project_prefix.len..];
    if (id.len > 0 and std.mem.indexOfScalar(u8, id, '/') == null) {
        return .{ .route = .stats_project, .id = id };
    }
}
```

- [ ] **Step 2: Add router unit tests**

In `router.zig`'s test block, add:

```zig
test "router matches GET /api/v1/stats → stats_overview" {
    const m = match(.GET, "/api/v1/stats");
    try testing.expectEqual(Route.stats_overview, m.route);
}

test "router matches GET /api/v1/stats/project/:id" {
    const m = match(.GET, "/api/v1/stats/project/p_abc");
    try testing.expectEqual(Route.stats_project, m.route);
    try testing.expectEqualStrings("p_abc", m.id.?);
}

test "router matches GET /api/v1/stats/timeseries (query string stripped by caller)" {
    const m = match(.GET, "/api/v1/stats/timeseries");
    try testing.expectEqual(Route.stats_timeseries, m.route);
}

test "router matches GET /api/v1/stats/slow" {
    const m = match(.GET, "/api/v1/stats/slow");
    try testing.expectEqual(Route.stats_slow, m.route);
}
```

(Note: query strings like `?from=...` are stripped by the caller in `server.zig` before `match` is invoked. Verify by reading `server.zig`'s dispatch site — there's a `path` variable extracted from `request.head.target` that excludes the query string.)

- [ ] **Step 3: Wire dispatch in `server.zig`**

In `src/api/server.zig`, find the dispatch switch that maps `Route` values to handlers (search for `route_match.route` or similar). Add cases for the 4 new routes. Each handler reads `*Db`, calls into `handlers_stats`, serializes the result as JSON, and writes via `request.respond(...)` with the standard `cors_headers`.

Add at the top of server.zig (alongside other handler imports):

```zig
const handlers_stats = @import("handlers_stats.zig");
```

Then add 4 dispatch handlers. The pattern matches `respondProjectsExtractionsList` — call into the module, then JSON-emit. Names: `respondStatsOverview`, `respondStatsProject`, `respondStatsTimeseries`, `respondStatsSlow`.

Sample skeleton for `respondStatsOverview` (write the full function inline):

```zig
fn respondStatsOverview(
    gpa: std.mem.Allocator,
    db: *Db,
    request: *http.Server.Request,
) !void {
    var ov = handlers_stats.getOverview(db, gpa) catch {
        return respondError(request, .internal_server_error, "INTERNAL_ERROR", "Stats unavailable");
    };
    defer ov.deinit(gpa);

    var buf: [128 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);

    try w.writeAll("{\"lifetime\":{\"ocr\":");
    try writeKindTotals(&w, ov.lifetime.ocr);
    try w.writeAll(",\"prompt\":");
    try writeKindTotals(&w, ov.lifetime.prompt);
    try w.writeAll("},\"per_model\":[");
    for (ov.per_model, 0..) |m, i| {
        if (i > 0) try w.writeAll(",");
        try writeModelTotals(&w, m);
    }
    try w.writeAll("],\"top_projects\":[");
    for (ov.top_projects, 0..) |p, i| {
        if (i > 0) try w.writeAll(",");
        try writeProjectTotals(&w, p);
    }
    try w.writeAll("]}");

    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    } ++ cors_headers;
    try request.respond(w.buffered(), .{ .status = .ok, .extra_headers = &headers });
}
```

The three writer helpers:

```zig
fn writeKindTotals(w: *std.Io.Writer, k: stats_mod.KindTotals) !void {
    try w.writeAll("{\"kind\":");
    try json.writeJsonString(w, k.kind);
    try w.print(",\"runs\":{d},\"in_tokens\":{d},\"out_tokens\":{d},\"cost_usd\":{d},\"avg_latency_s\":{d}}}", .{
        k.runs, k.in_tokens, k.out_tokens, k.cost_usd, k.avg_latency_s,
    });
}

fn writeModelTotals(w: *std.Io.Writer, m: stats_mod.ModelTotals) !void {
    try w.writeAll("{\"model\":");
    try json.writeJsonString(w, m.model);
    try w.print(",\"runs\":{d},\"in_tokens\":{d},\"out_tokens\":{d},\"cost_usd\":{d}}}", .{
        m.runs, m.in_tokens, m.out_tokens, m.cost_usd,
    });
}

fn writeProjectTotals(w: *std.Io.Writer, p: stats_mod.ProjectTotals) !void {
    try w.writeAll("{\"project_id\":");
    try json.writeJsonString(w, p.project_id);
    try w.print(",\"ocr_cost_usd\":{d},\"prompt_cost_usd\":{d},\"total_in_tokens\":{d},\"total_out_tokens\":{d},\"ocr_runs\":{d},\"prompt_runs\":{d}}}", .{
        p.ocr_cost_usd, p.prompt_cost_usd, p.total_in_tokens, p.total_out_tokens, p.ocr_runs, p.prompt_runs,
    });
}
```

Add at the top: `const stats_mod = @import("../db/stats.zig");`

`respondStatsProject`:

```zig
fn respondStatsProject(
    gpa: std.mem.Allocator,
    db: *Db,
    request: *http.Server.Request,
    project_id: []const u8,
) !void {
    var pt = handlers_stats.getProject(db, gpa, project_id) catch {
        return respondError(request, .internal_server_error, "INTERNAL_ERROR", "Stats unavailable");
    };
    defer pt.deinit(gpa);
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeProjectTotals(&w, pt);
    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    } ++ cors_headers;
    try request.respond(w.buffered(), .{ .status = .ok, .extra_headers = &headers });
}
```

`respondStatsTimeseries` — parses `?from=YYYY-MM-DD&to=YYYY-MM-DD` from the query string. Defaults are wide sentinels (`"1970-01-01"` / `"9999-12-31"`) — no date math needed because the UI always sends explicit dates (Task 12). Sentinels just mean "naked curl gives all-time" which is a reasonable smoke-test behavior.

Strategy: extract the raw query string from `request.head.target` (e.g. `path?from=2026-05-01&to=2026-05-29`), parse via a small helper `extractQueryParam(target, "from")`.

```zig
fn respondStatsTimeseries(
    gpa: std.mem.Allocator,
    db: *Db,
    request: *http.Server.Request,
) !void {
    const from = extractQueryParam(request.head.target, "from") orelse "1970-01-01";
    const to = extractQueryParam(request.head.target, "to") orelse "9999-12-31";

    const list = handlers_stats.getTimeseries(db, gpa, from, to) catch {
        return respondError(request, .internal_server_error, "INTERNAL_ERROR", "Timeseries unavailable");
    };
    defer stats_mod.deinitTimeseries(list, gpa);

    var buf: [64 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.writeAll("[");
    for (list, 0..) |d, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"day\":");
        try json.writeJsonString(&w, d.day);
        try w.print(",\"in_tokens\":{d},\"out_tokens\":{d},\"cost_usd\":{d}}}", .{
            d.in_tokens, d.out_tokens, d.cost_usd,
        });
    }
    try w.writeAll("]");
    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    } ++ cors_headers;
    try request.respond(w.buffered(), .{ .status = .ok, .extra_headers = &headers });
}
```

Helpers (add to server.zig):

```zig
/// Return the value of `?<name>=<value>` from a target like `/path?from=2026-05-01&to=2026-05-29`.
/// Returns null if absent.
fn extractQueryParam(target: []const u8, name: []const u8) ?[]const u8 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var it = std.mem.tokenizeScalar(u8, target[q + 1 ..], '&');
    while (it.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        if (std.mem.eql(u8, kv[0..eq], name)) return kv[eq + 1 ..];
    }
    return null;
}

```

`respondStatsSlow`:

```zig
fn respondStatsSlow(
    gpa: std.mem.Allocator,
    db: *Db,
    request: *http.Server.Request,
) !void {
    var limit: u32 = 20;
    if (extractQueryParam(request.head.target, "limit")) |lim| {
        limit = std.fmt.parseInt(u32, lim, 10) catch 20;
        if (limit == 0 or limit > 200) limit = 20;
    }
    const list = handlers_stats.getSlow(db, gpa, limit) catch {
        return respondError(request, .internal_server_error, "INTERNAL_ERROR", "Slow jobs unavailable");
    };
    defer stats_mod.deinitSlowJobList(list, gpa);

    var buf: [64 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.writeAll("[");
    for (list, 0..) |s, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"kind\":");
        try json.writeJsonString(&w, s.kind);
        try w.writeAll(",\"project_id\":");
        try json.writeJsonString(&w, s.project_id);
        try w.writeAll(",\"subject\":");
        try json.writeJsonString(&w, s.subject);
        try w.writeAll(",\"model\":");
        try json.writeJsonString(&w, s.model);
        try w.print(",\"latency_s\":{d},\"total_tokens\":{d}", .{ s.latency_s, s.total_tokens });
        try w.writeAll(",\"created_at\":");
        try json.writeJsonString(&w, s.created_at);
        try w.writeAll("}");
    }
    try w.writeAll("]");
    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    } ++ cors_headers;
    try request.respond(w.buffered(), .{ .status = .ok, .extra_headers = &headers });
}
```

- [ ] **Step 4: Hook 4 routes into dispatch switch in server.zig**

Find the switch on `route_match.route` (or equivalent in server.zig). Add:

```zig
.stats_overview => try respondStatsOverview(gpa, db, &request),
.stats_project => try respondStatsProject(gpa, db, &request, route_match.id.?),
.stats_timeseries => try respondStatsTimeseries(gpa, db, &request),
.stats_slow => try respondStatsSlow(gpa, db, &request),
```

- [ ] **Step 5: Build + test + smoke**

```bash
cd ~/projects/lambe-haath/logos && zig build && zig build test 2>&1 | tail -10
```

Manual smoke (in two terminals):

```bash
# Terminal 1: start daemon
cd ~/projects/lambe-haath/logos
~/projects/lambe-haath/logos/zig-out/bin/logos -p 7777
# Terminal 2: hit each endpoint
curl -s http://localhost:7777/api/v1/stats | jq .
curl -s "http://localhost:7777/api/v1/stats/slow?limit=5" | jq .
curl -s "http://localhost:7777/api/v1/stats/timeseries?from=2026-05-01&to=2026-05-29" | jq .
```

Expected: each returns valid JSON. Empty DB → zeros / empty arrays.

- [ ] **Step 6: Commit**

```bash
git add logos/src/api/router.zig logos/src/api/server.zig
git commit -m "api: wire 4 stats endpoints into router + dispatch"
```

---

## Task 7: UI — schemas, types, API client (+ tests)

**Files:**

- Modify: `~/projects/lambe-haath/chargesheet-ui/src/lib/api/schemas.ts`
- Modify: `~/projects/lambe-haath/chargesheet-ui/src/lib/api/types.ts`
- Create: `~/projects/lambe-haath/chargesheet-ui/src/lib/api/stats.ts`
- Create: `~/projects/lambe-haath/chargesheet-ui/src/lib/api/stats.test.ts`

- [ ] **Step 1: Add schemas**

Append to `src/lib/api/schemas.ts`:

```typescript
// --- Stats ---

export const KindTotalsSchema = z.object({
    kind: z.string(),
    runs: z.number().int().nonnegative(),
    in_tokens: z.number().int().nonnegative(),
    out_tokens: z.number().int().nonnegative(),
    cost_usd: z.number().nonnegative(),
    avg_latency_s: z.number().nonnegative(),
});

export const ModelTotalsSchema = z.object({
    model: z.string(),
    runs: z.number().int().nonnegative(),
    in_tokens: z.number().int().nonnegative(),
    out_tokens: z.number().int().nonnegative(),
    cost_usd: z.number().nonnegative(),
});

export const ProjectTotalsSchema = z.object({
    project_id: z.string(),
    ocr_cost_usd: z.number().nonnegative(),
    prompt_cost_usd: z.number().nonnegative(),
    total_in_tokens: z.number().int().nonnegative(),
    total_out_tokens: z.number().int().nonnegative(),
    ocr_runs: z.number().int().nonnegative(),
    prompt_runs: z.number().int().nonnegative(),
});

export const OverviewSchema = z.object({
    lifetime: z.object({
        ocr: KindTotalsSchema,
        prompt: KindTotalsSchema,
    }),
    per_model: z.array(ModelTotalsSchema),
    top_projects: z.array(ProjectTotalsSchema),
});

export const DayBucketSchema = z.object({
    day: z.string(),
    in_tokens: z.number().int().nonnegative(),
    out_tokens: z.number().int().nonnegative(),
    cost_usd: z.number().nonnegative(),
});

export const TimeseriesResponseSchema = z.array(DayBucketSchema);

export const SlowJobSchema = z.object({
    kind: z.enum(['extraction', 'prompt']),
    project_id: z.string(),
    subject: z.string(),
    model: z.string(),
    latency_s: z.number().nonnegative(),
    total_tokens: z.number().int().nonnegative(),
    created_at: z.string(),
});

export const SlowJobsResponseSchema = z.array(SlowJobSchema);
```

Append to `src/lib/api/types.ts`:

```typescript
export type KindTotals = z.infer<typeof s.KindTotalsSchema>;
export type ModelTotals = z.infer<typeof s.ModelTotalsSchema>;
export type ProjectTotals = z.infer<typeof s.ProjectTotalsSchema>;
export type Overview = z.infer<typeof s.OverviewSchema>;
export type DayBucket = z.infer<typeof s.DayBucketSchema>;
export type SlowJob = z.infer<typeof s.SlowJobSchema>;
```

- [ ] **Step 2: Create stats.ts API client**

```typescript
// src/lib/api/stats.ts
import { apiFetch } from './client';
import {
    OverviewSchema,
    ProjectTotalsSchema,
    TimeseriesResponseSchema,
    SlowJobsResponseSchema,
} from './schemas';

export async function getOverview() {
    return apiFetch('/api/v1/stats', { method: 'GET' }, OverviewSchema);
}

export async function getProjectStats(projectId: string) {
    return apiFetch(`/api/v1/stats/project/${encodeURIComponent(projectId)}`, { method: 'GET' }, ProjectTotalsSchema);
}

export async function getTimeseries(fromIso: string, toIso: string) {
    const qs = new URLSearchParams({ from: fromIso, to: toIso }).toString();
    return apiFetch(`/api/v1/stats/timeseries?${qs}`, { method: 'GET' }, TimeseriesResponseSchema);
}

export async function getSlowJobs(limit = 20) {
    return apiFetch(`/api/v1/stats/slow?limit=${limit}`, { method: 'GET' }, SlowJobsResponseSchema);
}
```

- [ ] **Step 3: Add unit tests**

```typescript
// src/lib/api/stats.test.ts
import { describe, it, expect, vi, beforeEach } from 'vitest';
import * as stats from './stats';

const fetchMock = vi.fn();
beforeEach(() => {
    fetchMock.mockReset();
    globalThis.fetch = fetchMock as unknown as typeof fetch;
});

function ok(body: unknown) {
    return new Response(JSON.stringify(body), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
    });
}

describe('stats API', () => {
    it('getOverview parses lifetime + per_model + top_projects', async () => {
        fetchMock.mockResolvedValueOnce(ok({
            lifetime: {
                ocr: { kind: 'ocr', runs: 1, in_tokens: 100, out_tokens: 200, cost_usd: 0.01, avg_latency_s: 1.5 },
                prompt: { kind: 'prompt', runs: 0, in_tokens: 0, out_tokens: 0, cost_usd: 0, avg_latency_s: 0 },
            },
            per_model: [{ model: 'g', runs: 1, in_tokens: 100, out_tokens: 200, cost_usd: 0.01 }],
            top_projects: [],
        }));
        const ov = await stats.getOverview();
        expect(ov.lifetime.ocr.runs).toBe(1);
        expect(ov.per_model).toHaveLength(1);
    });

    it('getProjectStats encodes project id', async () => {
        fetchMock.mockResolvedValueOnce(ok({
            project_id: 'p_abc',
            ocr_cost_usd: 0,
            prompt_cost_usd: 0,
            total_in_tokens: 0,
            total_out_tokens: 0,
            ocr_runs: 0,
            prompt_runs: 0,
        }));
        await stats.getProjectStats('p abc');
        expect(fetchMock).toHaveBeenCalledWith(
            expect.stringContaining('/api/v1/stats/project/p%20abc'),
            expect.objectContaining({ method: 'GET' }),
        );
    });

    it('getSlowJobs respects limit', async () => {
        fetchMock.mockResolvedValueOnce(ok([]));
        await stats.getSlowJobs(5);
        expect(fetchMock).toHaveBeenCalledWith(
            expect.stringContaining('limit=5'),
            expect.objectContaining({ method: 'GET' }),
        );
    });

    it('getTimeseries builds query string', async () => {
        fetchMock.mockResolvedValueOnce(ok([]));
        await stats.getTimeseries('2026-05-01', '2026-05-29');
        expect(fetchMock).toHaveBeenCalledWith(
            expect.stringContaining('from=2026-05-01'),
            expect.objectContaining({ method: 'GET' }),
        );
    });
});
```

- [ ] **Step 4: Run + commit**

```bash
cd ~/projects/lambe-haath/chargesheet-ui && yarn check && yarn test
git add chargesheet-ui/src/lib/api/schemas.ts chargesheet-ui/src/lib/api/types.ts chargesheet-ui/src/lib/api/stats.ts chargesheet-ui/src/lib/api/stats.test.ts
git commit -m "chargesheet-ui/api: schemas + client for stats endpoints"
```

---

## Task 8: UI — stats store

**Files:**

- Create: `~/projects/lambe-haath/chargesheet-ui/src/lib/stores/stats.svelte.ts`

A single class that holds the 4 response shapes as `$state` and exposes a `loadAll()` plus per-section reload methods. Mirror the pattern from `extractions.svelte.ts`.

- [ ] **Step 1: Create file**

```typescript
// src/lib/stores/stats.svelte.ts
import * as api from '$lib/api/stats';
import type { Overview, DayBucket, SlowJob, ProjectTotals } from '$lib/api/types';

class StatsStore {
    overview = $state<Overview | null>(null);
    timeseries = $state<DayBucket[]>([]);
    slow = $state<SlowJob[]>([]);
    perProject = $state<Record<string, ProjectTotals>>({});
    loading = $state(false);
    error = $state<string | null>(null);

    async loadOverview(): Promise<void> {
        this.loading = true;
        this.error = null;
        try {
            this.overview = await api.getOverview();
        } catch (e) {
            this.error = e instanceof Error ? e.message : 'Failed to load stats';
        } finally {
            this.loading = false;
        }
    }

    async loadTimeseries(from: string, to: string): Promise<void> {
        try {
            this.timeseries = await api.getTimeseries(from, to);
        } catch (e) {
            this.error = e instanceof Error ? e.message : 'Failed to load timeseries';
        }
    }

    async loadSlow(limit = 20): Promise<void> {
        try {
            this.slow = await api.getSlowJobs(limit);
        } catch (e) {
            this.error = e instanceof Error ? e.message : 'Failed to load slow jobs';
        }
    }

    async loadProject(projectId: string): Promise<void> {
        try {
            const pt = await api.getProjectStats(projectId);
            this.perProject = { ...this.perProject, [projectId]: pt };
        } catch (e) {
            this.error = e instanceof Error ? e.message : 'Failed to load project stats';
        }
    }

    clear(): void {
        this.overview = null;
        this.timeseries = [];
        this.slow = [];
        this.perProject = {};
        this.error = null;
    }
}

export const statsStore = new StatsStore();
```

- [ ] **Step 2: Commit**

```bash
cd ~/projects/lambe-haath/chargesheet-ui && yarn check
git add chargesheet-ui/src/lib/stores/stats.svelte.ts
git commit -m "chargesheet-ui/stores: stats store"
```

---

## Task 9: UI — LineChart wrapper (Chart.js)

**Files:**

- Modify: `~/projects/lambe-haath/chargesheet-ui/package.json`
- Create: `~/projects/lambe-haath/chargesheet-ui/src/lib/components/LineChart.svelte`

- [ ] **Step 1: Add chart.js dep**

```bash
cd ~/projects/lambe-haath/chargesheet-ui
yarn add chart.js@^4
```

- [ ] **Step 2: Create LineChart.svelte**

```svelte
<script lang="ts">
    import { onMount, onDestroy } from 'svelte';
    import { Chart, registerables, type ChartConfiguration } from 'chart.js';

    Chart.register(...registerables);

    let {
        labels,
        datasets,
        height = 240,
    }: {
        labels: string[];
        datasets: Array<{ label: string; data: number[]; borderColor?: string; backgroundColor?: string; yAxisID?: string }>;
        height?: number;
    } = $props();

    let canvas = $state<HTMLCanvasElement | undefined>();
    let chart: Chart | null = null;

    function build() {
        if (!canvas) return;
        const ctx = canvas.getContext('2d');
        if (!ctx) return;
        const cfg: ChartConfiguration<'line'> = {
            type: 'line',
            data: {
                labels,
                datasets: datasets.map((d) => ({
                    label: d.label,
                    data: d.data,
                    borderColor: d.borderColor ?? '#2563eb',
                    backgroundColor: d.backgroundColor ?? 'rgba(37, 99, 235, 0.1)',
                    yAxisID: d.yAxisID,
                    tension: 0.25,
                    fill: false,
                })),
            },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                interaction: { mode: 'index', intersect: false },
                plugins: { legend: { position: 'top' } },
                scales: {
                    x: { ticks: { maxTicksLimit: 12 } },
                    y: { type: 'linear', position: 'left' },
                    yRight: { type: 'linear', position: 'right', grid: { drawOnChartArea: false } },
                },
            },
        };
        chart = new Chart(ctx, cfg);
    }

    onMount(() => {
        build();
    });

    $effect(() => {
        // Rebuild when inputs change. (Cheap because Chart.js diffs DOM.)
        if (chart) {
            chart.data.labels = labels;
            chart.data.datasets.forEach((ds, i) => {
                ds.data = datasets[i]?.data ?? [];
            });
            chart.update();
        }
    });

    onDestroy(() => {
        chart?.destroy();
        chart = null;
    });
</script>

<div style="height: {height}px;">
    <canvas bind:this={canvas}></canvas>
</div>
```

- [ ] **Step 3: Commit**

```bash
cd ~/projects/lambe-haath/chargesheet-ui && yarn check
git add chargesheet-ui/package.json chargesheet-ui/yarn.lock chargesheet-ui/src/lib/components/LineChart.svelte
git commit -m "chargesheet-ui/components: LineChart wrapper (Chart.js)"
```

---

## Task 10: UI — StatsPanel (per-project mini-stats)

**Files:**

- Create: `~/projects/lambe-haath/chargesheet-ui/src/lib/components/StatsPanel.svelte`

Small panel meant to embed in the project page tab. Renders the per-project rollup: total cost (with OCR vs prompt split), total tokens, run counts.

- [ ] **Step 1: Create file**

```svelte
<script lang="ts">
    import { onMount } from 'svelte';
    import { statsStore } from '$lib/stores/stats.svelte';
    import EmptyState from './EmptyState.svelte';
    import Button from './Button.svelte';

    let { projectId }: { projectId: string } = $props();

    const stats = $derived(statsStore.perProject[projectId]);

    onMount(() => {
        void statsStore.loadProject(projectId);
    });

    function fmtUsd(v: number): string {
        return `$${v.toFixed(4)}`;
    }
    function fmtTok(v: number): string {
        return v.toLocaleString('en-US');
    }
</script>

<div class="space-y-4">
    {#if statsStore.loading && !stats}
        <div class="grid grid-cols-3 gap-3">
            {#each Array(3) as _, i (i)}
                <div class="h-20 animate-pulse rounded-lg border border-gray-200 bg-gray-100"></div>
            {/each}
        </div>
    {:else if statsStore.error && !stats}
        <EmptyState title="Couldn't load stats" description={statsStore.error} />
    {:else if stats}
        <div class="grid grid-cols-1 gap-3 sm:grid-cols-3">
            <div class="rounded-lg border border-gray-200 bg-white p-4">
                <div class="text-xs uppercase tracking-wide text-gray-500">Total cost</div>
                <div class="mt-1 text-2xl font-semibold text-gray-900">
                    {fmtUsd(stats.ocr_cost_usd + stats.prompt_cost_usd)}
                </div>
                <div class="mt-2 text-xs text-gray-500">
                    OCR {fmtUsd(stats.ocr_cost_usd)} · Prompts {fmtUsd(stats.prompt_cost_usd)}
                </div>
            </div>
            <div class="rounded-lg border border-gray-200 bg-white p-4">
                <div class="text-xs uppercase tracking-wide text-gray-500">Tokens</div>
                <div class="mt-1 text-2xl font-semibold text-gray-900">
                    {fmtTok(stats.total_in_tokens + stats.total_out_tokens)}
                </div>
                <div class="mt-2 text-xs text-gray-500">
                    In {fmtTok(stats.total_in_tokens)} · Out {fmtTok(stats.total_out_tokens)}
                </div>
            </div>
            <div class="rounded-lg border border-gray-200 bg-white p-4">
                <div class="text-xs uppercase tracking-wide text-gray-500">Runs</div>
                <div class="mt-1 text-2xl font-semibold text-gray-900">
                    {stats.ocr_runs + stats.prompt_runs}
                </div>
                <div class="mt-2 text-xs text-gray-500">
                    OCR {stats.ocr_runs} · Prompts {stats.prompt_runs}
                </div>
            </div>
        </div>
        <div class="flex justify-end">
            <Button variant="secondary" onclick={() => void statsStore.loadProject(projectId)}>Refresh</Button>
        </div>
    {/if}
</div>
```

- [ ] **Step 2: Commit**

```bash
cd ~/projects/lambe-haath/chargesheet-ui && yarn check
git add chargesheet-ui/src/lib/components/StatsPanel.svelte
git commit -m "chargesheet-ui/components: StatsPanel (per-project mini-stats)"
```

---

## Task 11: UI — wire StatsPanel as 4th tab on project page

**Files:**

- Modify: `~/projects/lambe-haath/chargesheet-ui/src/routes/projects/[id]/+page.svelte`

- [ ] **Step 1: Add `'stats'` to activeTab union + tabs array + branch**

Read the file first to find the existing `tabs: Tab[]` definition. Add a fourth entry:

```typescript
{ key: 'stats', label: 'Stats' }
```

Add to the `activeTab` type union: `'slice' | 'extractions' | 'prompts' | 'stats'`.

In the template, after the existing `{#if activeTab === 'prompts'}{:/if}` branch, add:

```svelte
{:else if activeTab === 'stats'}
    <StatsPanel projectId={data.project.id} />
```

(Adjust `data.project.id` to whatever the existing page uses for the project ID.)

Add the import:

```typescript
import StatsPanel from '$lib/components/StatsPanel.svelte';
```

- [ ] **Step 2: Build + smoke**

```bash
cd ~/projects/lambe-haath/chargesheet-ui && yarn check && yarn test && yarn build
```

(Manual browser smoke: open a project, click Stats tab, verify panel renders.)

- [ ] **Step 3: Commit**

```bash
git add chargesheet-ui/src/routes/projects/[id]/+page.svelte
git commit -m "chargesheet-ui/projects/[id]: add Stats tab"
```

---

## Task 12: UI — dedicated /stats route (Overview + Slow + Chart)

**Files:**

- Create: `~/projects/lambe-haath/chargesheet-ui/src/routes/stats/+page.svelte`

Sections (top to bottom):

1. **Lifetime summary cards** — 2 cards side by side: OCR totals (runs, cost, in/out tokens, avg latency), Prompts totals.
2. **Per-model table** — model | runs | in_tok | out_tok | cost.
3. **Daily chart** — LineChart of cost_usd per day for the last 30 days.
4. **Top-cost projects table** — top 10 from `overview.top_projects`.
5. **Slow jobs table** — slowest 20 jobs.

- [ ] **Step 1: Create page**

```svelte
<script lang="ts">
    import { onMount } from 'svelte';
    import { statsStore } from '$lib/stores/stats.svelte';
    import LineChart from '$lib/components/LineChart.svelte';
    import EmptyState from '$lib/components/EmptyState.svelte';

    function ymd(d: Date): string {
        return d.toISOString().slice(0, 10);
    }

    function loadAll() {
        const to = new Date();
        const from = new Date(to.getTime() - 30 * 24 * 60 * 60 * 1000);
        void statsStore.loadOverview();
        void statsStore.loadTimeseries(ymd(from), ymd(to));
        void statsStore.loadSlow(20);
    }

    onMount(loadAll);

    const overview = $derived(statsStore.overview);
    const series = $derived(statsStore.timeseries);
    const slow = $derived(statsStore.slow);

    function fmtUsd(v: number) {
        return `$${v.toFixed(4)}`;
    }
    function fmtTok(v: number) {
        return v.toLocaleString('en-US');
    }
</script>

<div class="mx-auto max-w-6xl px-6 py-10 space-y-8">
    <div class="flex items-end justify-between">
        <div>
            <h1 class="text-2xl font-semibold text-gray-900">Stats</h1>
            <p class="text-sm text-gray-500">Tokens, cost, and latency across all projects.</p>
        </div>
        <a href="/" class="text-sm text-blue-600 hover:underline">← Projects</a>
    </div>

    {#if !overview}
        <div class="grid grid-cols-2 gap-4">
            {#each Array(2) as _, i (i)}
                <div class="h-32 animate-pulse rounded-lg border border-gray-200 bg-gray-100"></div>
            {/each}
        </div>
    {:else}
        <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
            {#each [['OCR', overview.lifetime.ocr], ['Prompts', overview.lifetime.prompt]] as [name, k]}
                <div class="rounded-lg border border-gray-200 bg-white p-4">
                    <div class="text-xs uppercase tracking-wide text-gray-500">{name}</div>
                    <div class="mt-1 text-3xl font-semibold text-gray-900">{fmtUsd(k.cost_usd)}</div>
                    <div class="mt-2 grid grid-cols-3 gap-2 text-xs text-gray-500">
                        <div>Runs<br><span class="text-gray-900">{k.runs}</span></div>
                        <div>In tok<br><span class="text-gray-900">{fmtTok(k.in_tokens)}</span></div>
                        <div>Out tok<br><span class="text-gray-900">{fmtTok(k.out_tokens)}</span></div>
                    </div>
                    <div class="mt-2 text-xs text-gray-500">Avg latency: {k.avg_latency_s.toFixed(2)}s</div>
                </div>
            {/each}
        </div>

        <section>
            <h2 class="mb-2 text-sm font-semibold text-gray-900">Per-model usage</h2>
            {#if overview.per_model.length === 0}
                <EmptyState title="No model usage yet" description="Run a pipeline to see model rollups." />
            {:else}
                <div class="overflow-hidden rounded-lg border border-gray-200">
                    <table class="min-w-full text-sm">
                        <thead class="bg-gray-50 text-xs uppercase tracking-wide text-gray-500">
                            <tr><th class="px-3 py-2 text-left">Model</th><th class="px-3 py-2 text-right">Runs</th><th class="px-3 py-2 text-right">In tok</th><th class="px-3 py-2 text-right">Out tok</th><th class="px-3 py-2 text-right">Cost</th></tr>
                        </thead>
                        <tbody class="divide-y divide-gray-100 bg-white">
                            {#each overview.per_model as m (m.model)}
                                <tr><td class="px-3 py-2 font-mono">{m.model}</td><td class="px-3 py-2 text-right">{m.runs}</td><td class="px-3 py-2 text-right">{fmtTok(m.in_tokens)}</td><td class="px-3 py-2 text-right">{fmtTok(m.out_tokens)}</td><td class="px-3 py-2 text-right">{fmtUsd(m.cost_usd)}</td></tr>
                            {/each}
                        </tbody>
                    </table>
                </div>
            {/if}
        </section>

        <section>
            <h2 class="mb-2 text-sm font-semibold text-gray-900">Cost &amp; tokens — last 30 days</h2>
            {#if series.length === 0}
                <EmptyState title="No activity in this range" description="Run a pipeline; data will appear here." />
            {:else}
                <LineChart
                    labels={series.map((d) => d.day)}
                    datasets={[
                        { label: 'Cost (USD)', data: series.map((d) => d.cost_usd), borderColor: '#2563eb', yAxisID: 'y' },
                        { label: 'Total tokens', data: series.map((d) => d.in_tokens + d.out_tokens), borderColor: '#16a34a', yAxisID: 'yRight' },
                    ]}
                />
            {/if}
        </section>

        <section>
            <h2 class="mb-2 text-sm font-semibold text-gray-900">Top-cost projects</h2>
            {#if overview.top_projects.length === 0}
                <EmptyState title="No project usage yet" description="" />
            {:else}
                <div class="overflow-hidden rounded-lg border border-gray-200">
                    <table class="min-w-full text-sm">
                        <thead class="bg-gray-50 text-xs uppercase tracking-wide text-gray-500">
                            <tr><th class="px-3 py-2 text-left">Project</th><th class="px-3 py-2 text-right">OCR cost</th><th class="px-3 py-2 text-right">Prompt cost</th><th class="px-3 py-2 text-right">Total tokens</th></tr>
                        </thead>
                        <tbody class="divide-y divide-gray-100 bg-white">
                            {#each overview.top_projects as p (p.project_id)}
                                <tr>
                                    <td class="px-3 py-2"><a class="text-blue-600 hover:underline" href="/projects/{p.project_id}">{p.project_id}</a></td>
                                    <td class="px-3 py-2 text-right">{fmtUsd(p.ocr_cost_usd)}</td>
                                    <td class="px-3 py-2 text-right">{fmtUsd(p.prompt_cost_usd)}</td>
                                    <td class="px-3 py-2 text-right">{fmtTok(p.total_in_tokens + p.total_out_tokens)}</td>
                                </tr>
                            {/each}
                        </tbody>
                    </table>
                </div>
            {/if}
        </section>
    {/if}

    <section>
        <h2 class="mb-2 text-sm font-semibold text-gray-900">Slowest jobs</h2>
        {#if slow.length === 0}
            <EmptyState title="No jobs to rank" description="" />
        {:else}
            <div class="overflow-hidden rounded-lg border border-gray-200">
                <table class="min-w-full text-sm">
                    <thead class="bg-gray-50 text-xs uppercase tracking-wide text-gray-500">
                        <tr><th class="px-3 py-2 text-left">Kind</th><th class="px-3 py-2 text-left">Project</th><th class="px-3 py-2 text-left">Subject</th><th class="px-3 py-2 text-left">Model</th><th class="px-3 py-2 text-right">Latency</th><th class="px-3 py-2 text-right">Tokens</th><th class="px-3 py-2 text-left">When</th></tr>
                    </thead>
                    <tbody class="divide-y divide-gray-100 bg-white">
                        {#each slow as s (s.created_at + s.subject)}
                            <tr>
                                <td class="px-3 py-2">{s.kind}</td>
                                <td class="px-3 py-2"><a class="text-blue-600 hover:underline" href="/projects/{s.project_id}">{s.project_id}</a></td>
                                <td class="px-3 py-2 font-mono text-xs">{s.subject}</td>
                                <td class="px-3 py-2 font-mono text-xs">{s.model}</td>
                                <td class="px-3 py-2 text-right">{s.latency_s.toFixed(2)}s</td>
                                <td class="px-3 py-2 text-right">{fmtTok(s.total_tokens)}</td>
                                <td class="px-3 py-2 text-xs text-gray-500">{s.created_at}</td>
                            </tr>
                        {/each}
                    </tbody>
                </table>
            </div>
        {/if}
    </section>
</div>
```

- [ ] **Step 2: Build + smoke**

```bash
cd ~/projects/lambe-haath/chargesheet-ui && yarn check && yarn test && yarn build
```

Manual: navigate to `/stats` with daemon running, verify all 4 sections render. Empty DB shows empty states. Populated DB shows data.

- [ ] **Step 3: Commit**

```bash
git add chargesheet-ui/src/routes/stats/+page.svelte
git commit -m "chargesheet-ui/routes: /stats page with chart + tables"
```

---

## Task 13: UI — header link from home page

**Files:**

- Modify: `~/projects/lambe-haath/chargesheet-ui/src/routes/+page.svelte`

- [ ] **Step 1: Add link**

Read the file to find the header `<div class="mb-6 flex items-end justify-between">` block. Beside the `+ New project` button, add a Stats link:

```svelte
<div class="flex items-center gap-3">
    <a
        href="/stats"
        class="text-sm text-gray-600 hover:text-gray-900"
    >
        Stats
    </a>
    <a
        href="/new"
        class="inline-flex items-center rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700"
    >
        + New project
    </a>
</div>
```

- [ ] **Step 2: Build + commit**

```bash
cd ~/projects/lambe-haath/chargesheet-ui && yarn check && yarn test && yarn build
git add chargesheet-ui/src/routes/+page.svelte
git commit -m "chargesheet-ui: header link to /stats"
```

---

## Task 14: Manual e2e verification

Hand off to the user. Daemon + UI dev server commands:

```bash
# Terminal 1: daemon
cd ~/projects/lambe-haath/logos && zig build
~/projects/lambe-haath/logos/zig-out/bin/logos -p 7777

# Terminal 2: UI
cd ~/projects/lambe-haath/chargesheet-ui && yarn dev
```

Test checklist (open `http://localhost:5173/`):

- [ ] Header shows "Stats" link
- [ ] Click "Stats" → `/stats` renders, empty DB shows empty states (no errors in console)
- [ ] Open a project with some OCR + prompt runs → Stats tab → mini-panel shows totals
- [ ] Go back to `/stats` → daily chart renders, per-model and slow-jobs tables populated
- [ ] Click a project in "Top-cost projects" → navigates to project page

---

## Task 15: Final cross-task review

After all implementation tasks merged-but-not-deleted on the feature branch, dispatch a final review subagent covering:

- All commits on `feat/plan-e-stats`
- Schema contract correctness (`stats.ts` parses what `server.zig` emits)
- Memory / leak checks in stats.zig (`deinit*` correctness)
- Chart.js wrapper $effect doesn't double-render or leak
- Scope discipline (no agent changes, no DB migrations)
- Verify `yarn check && yarn test && zig build test` all green

---

## Plan summary

15 tasks, ~12 commits expected:

| # | Task | Files touched | Repo |
|---|---|---|---|
| 1 | DB stats — lifetime totals | 2 | logos |
| 2 | DB stats — per-model | 1 | logos |
| 3 | DB stats — per-project + top-cost | 1 | logos |
| 4 | DB stats — slow + timeseries | 1 | logos |
| 5 | handlers_stats wrapper | 2 | logos |
| 6 | Routes + JSON serialization | 2 | logos |
| 7 | UI schemas + API client + tests | 4 | chargesheet-ui |
| 8 | UI stats store | 1 | chargesheet-ui |
| 9 | LineChart Chart.js wrapper | 2 | chargesheet-ui |
| 10 | StatsPanel | 1 | chargesheet-ui |
| 11 | Stats tab on project page | 1 | chargesheet-ui |
| 12 | /stats route | 1 | chargesheet-ui |
| 13 | Header link from / | 1 | chargesheet-ui |
| 14 | e2e verification | — | — |
| 15 | Final review | — | — |
