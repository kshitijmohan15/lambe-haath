# Plan A — Foundation: Schema v2 + JSON-RPC Codec + Mock Agent

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the v2 SQLite schema in `logos`, ship the JSON-RPC 2.0 codec, and deliver a language-agnostic mock agent + conformance harness — the foundation every subsequent plan depends on.

**Architecture:** Two repos. Zig work (schema migration, DB modules, JSON-RPC codec) lands in `~/projects/lambe-haath/logos/`. Python work (mock agent + conformance harness) lands in `~/projects/chargesheets/pdf-extraction-experiments/`. Plan A ships when (a) `zig build test` is green inside `logos/` with all new modules under test, and (b) `pytest -m protocol` is green and proves the mock agent speaks the `lambe-haath/1` protocol end-to-end.

**Tech Stack:** Zig 0.16 + zqlite + std.testing for the daemon side. Python 3.12 + pytest + the stdlib only (no new third-party deps for Plan A — keeping the mock agent dep-light so any future implementer can read it cold).

**Spec reference:** [`docs/superpowers/specs/2026-05-28-chargesheet-pipeline-design.md`](../specs/2026-05-28-chargesheet-pipeline-design.md). Sections this plan implements: _Database schema additions_, parts of _logos modules to add_ (only `db/*` and `agents/jsonrpc.zig`), _JSON-RPC protocol_, and _Testing strategy_ → _Mock agent_.

**Out of scope for Plan A** (deferred to later plans): supervisor, dispatcher, worker, HTTP handlers, SSE, real OCR/prompt agents, UI changes, stats endpoints.

---

## File structure

What this plan creates or modifies:

### `~/projects/lambe-haath/logos/`

```
src/
  db/
    v2.sql                       ← CREATE
    migrations.zig               ← MODIFY (add applyV2)
    slices.zig                   ← MODIFY (add kind/kind_key fields, parser)
    extractions.zig              ← CREATE
    prompt_outputs.zig           ← CREATE
    job_logs.zig                 ← CREATE
    test_helpers.zig             ← MODIFY (bump latest_version comment)
  agents/
    jsonrpc.zig                  ← CREATE  (Message types, encode, decodeLine)
    pricing.zig                  ← CREATE  (model → rate lookup; cost computation)
  root.zig                       ← MODIFY (re-export new modules)
build.zig                        ← MODIFY (add new .zig files to test step if needed)
```

### `~/projects/chargesheets/pdf-extraction-experiments/`

```
tests/
  mock_agent.py                  ← CREATE
  conformance_harness.py         ← CREATE
  test_mock_agent.py             ← CREATE (pytest tests for the mock agent)
  test_conformance.py            ← CREATE (drives harness against mock agent)
  __init__.py                    ← CREATE (empty)
  conftest.py                    ← CREATE (pytest fixtures)
pyproject.toml                   ← MODIFY (add pytest dep, mark `protocol` marker)
```

Each file has one clear responsibility:
- Zig DB modules each own one table's CRUD + structs.
- `jsonrpc.zig` is pure codec — no I/O.
- `mock_agent.py` is a self-contained executable that speaks the protocol.
- `conformance_harness.py` is a library that drives any agent through the protocol; tests use it.

---

## Working-directory note

**Every task explicitly states which repo it operates in.** The plan lives in `pdf-extraction-experiments/docs/...` but the majority of work happens in `~/projects/lambe-haath/logos/`. Don't conflate.

---

## Task 1: Add `v2.sql` migration file

**Target repo:** `~/projects/lambe-haath/logos/`

**Files:**
- Create: `src/db/v2.sql`

This file is `@embedFile`'d by `migrations.zig` in Task 2.

- [ ] **Step 1: Create `src/db/v2.sql`**

```sql
-- v2: chargesheet pipeline additions
-- Migration runs inside a single transaction wrapped by migrations.zig::applyV2.

INSERT INTO schema_version VALUES (2);

-- slices: add kind/kind_key for fast dispatcher lookup
ALTER TABLE slices ADD COLUMN kind TEXT;
ALTER TABLE slices ADD COLUMN kind_key TEXT;

CREATE INDEX idx_slices_kind ON slices(project_id, kind, kind_key);

-- jobs: expand type CHECK and add 'canceled' status; SQLite requires table rebuild
CREATE TABLE jobs_new (
    id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    type TEXT NOT NULL CHECK (type IN ('slice', 'ocr', 'prompt')),
    status TEXT NOT NULL CHECK (status IN ('queued', 'running', 'completed', 'failed', 'canceled')),
    progress REAL NOT NULL DEFAULT 0 CHECK (progress >= 0 AND progress <= 1),
    payload TEXT NOT NULL,
    results TEXT,
    error TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
INSERT INTO jobs_new SELECT * FROM jobs;
DROP TABLE jobs;
ALTER TABLE jobs_new RENAME TO jobs;
CREATE INDEX idx_jobs_status      ON jobs(status);
CREATE INDEX idx_jobs_project     ON jobs(project_id);
CREATE INDEX idx_jobs_status_type ON jobs(status, type);

-- extractions: one row per OCR'd slice (upsert on conflict)
CREATE TABLE extractions (
    project_id          TEXT    NOT NULL,
    slice_filename      TEXT    NOT NULL,
    markdown_path       TEXT    NOT NULL,
    meta_path           TEXT    NOT NULL,
    model               TEXT    NOT NULL,
    pages               INTEGER NOT NULL CHECK (pages > 0),
    page_markers_found  INTEGER NOT NULL CHECK (page_markers_found >= 0),
    input_tokens        INTEGER,
    output_tokens       INTEGER,
    input_cost_usd      REAL,
    output_cost_usd     REAL,
    latency_s           REAL    NOT NULL,
    created_at          TEXT    NOT NULL,
    PRIMARY KEY (project_id, slice_filename),
    FOREIGN KEY (project_id, slice_filename)
        REFERENCES slices(project_id, filename) ON DELETE CASCADE
);

-- prompt_outputs: one row per (project_id, prompt_name) (upsert on conflict)
CREATE TABLE prompt_outputs (
    project_id       TEXT    NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    prompt_name      TEXT    NOT NULL,
    markdown_path    TEXT    NOT NULL,
    model            TEXT    NOT NULL,
    input_tokens     INTEGER,
    output_tokens    INTEGER,
    input_cost_usd   REAL,
    output_cost_usd  REAL,
    latency_s        REAL    NOT NULL,
    warnings         TEXT    NOT NULL DEFAULT '[]',
    created_at       TEXT    NOT NULL,
    PRIMARY KEY (project_id, prompt_name)
);

-- job_logs: per-line agent logs
CREATE TABLE job_logs (
    id       INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id   TEXT    NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    ts       TEXT    NOT NULL,
    level    TEXT    NOT NULL CHECK (level IN ('debug','info','warning','error')),
    logger   TEXT    NOT NULL,
    message  TEXT    NOT NULL
);
CREATE INDEX idx_job_logs_job_ts ON job_logs(job_id, ts);
```

- [ ] **Step 2: Commit**

```bash
cd ~/projects/lambe-haath/logos
git add src/db/v2.sql
git commit -m "db: add v2.sql migration (extractions, prompt_outputs, job_logs, slices.kind, jobs type expansion)"
```

---

## Task 2: Extend `migrations.zig` to apply v2

**Target repo:** `~/projects/lambe-haath/logos/`

**Files:**
- Modify: `src/db/migrations.zig`

- [ ] **Step 1: Replace contents of `src/db/migrations.zig`**

```zig
const std = @import("std");
const zqlite = @import("zqlite");

const v1_sql = @embedFile("v1.sql");
const v2_sql = @embedFile("v2.sql");

pub const latest_version: i64 = 2;

pub fn run(conn: zqlite.Conn) !void {
    const current = try currentVersion(conn);
    if (current >= latest_version) return;
    if (current < 1) try applyV1(conn);
    if (current < 2) try applyV2(conn);
    // Future: if (current < 3) try applyV3(conn);
}

fn applyV1(conn: zqlite.Conn) !void {
    try conn.transaction();
    errdefer conn.rollback();
    try conn.execNoArgs(v1_sql);
    try conn.commit();
}

fn applyV2(conn: zqlite.Conn) !void {
    try conn.transaction();
    errdefer conn.rollback();
    try conn.execNoArgs(v2_sql);
    try conn.commit();
}

fn currentVersion(conn: zqlite.Conn) !i64 {
    if (try conn.row(
        "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='schema_version'",
        .{},
    )) |r| {
        defer r.deinit();
        if (r.int(0) == 0) return 0;
    } else return 0;

    if (try conn.row("SELECT MAX(version) FROM schema_version", .{})) |r| {
        defer r.deinit();
        return r.int(0);
    }
    return 0;
}

test "fresh DB migrates to latest_version" {
    const Db = @import("db.zig").Db;
    var db = try Db.open(":memory:");
    defer db.close();

    const row = (try db.conn.row("SELECT MAX(version) FROM schema_version", .{})).?;
    defer row.deinit();
    try std.testing.expectEqual(latest_version, row.int(0));
}

test "v2 creates extractions, prompt_outputs, job_logs tables" {
    const Db = @import("db.zig").Db;
    var db = try Db.open(":memory:");
    defer db.close();

    const expected_tables = [_][]const u8{ "extractions", "prompt_outputs", "job_logs" };
    for (expected_tables) |table| {
        const row = (try db.conn.row(
            "SELECT count(*) FROM sqlite_master WHERE type='table' AND name=?",
            .{table},
        )).?;
        defer row.deinit();
        try std.testing.expectEqual(@as(i64, 1), row.int(0));
    }
}

test "v2 adds slices.kind and slices.kind_key columns" {
    const Db = @import("db.zig").Db;
    var db = try Db.open(":memory:");
    defer db.close();

    var rows = try db.conn.rows("PRAGMA table_info(slices)", .{});
    defer rows.deinit();
    var found_kind = false;
    var found_kind_key = false;
    while (rows.next()) |row| {
        const col_name = row.text(1);
        if (std.mem.eql(u8, col_name, "kind")) found_kind = true;
        if (std.mem.eql(u8, col_name, "kind_key")) found_kind_key = true;
    }
    try std.testing.expect(found_kind);
    try std.testing.expect(found_kind_key);
}

test "v2 expands jobs.type CHECK to include ocr and prompt" {
    const Db = @import("db.zig").Db;
    var db = try Db.open(":memory:");
    defer db.close();

    // Need a project to satisfy the FK
    try db.conn.exec(
        \\INSERT INTO projects (id, name, created_at, last_opened_at,
        \\  chargesheet_filename, chargesheet_page_count, chargesheet_size_bytes)
        \\VALUES ('p1', 'test', '2026-05-28T00:00:00Z', '2026-05-28T00:00:00Z', 'c.pdf', 1, 1)
    , .{});

    // Each of these should succeed
    inline for (.{ "slice", "ocr", "prompt" }) |t| {
        try db.conn.exec(
            \\INSERT INTO jobs (id, project_id, type, status, payload, created_at, updated_at)
            \\VALUES (?, 'p1', ?, 'queued', '{}', '2026-05-28T00:00:00Z', '2026-05-28T00:00:00Z')
        , .{ "j_" ++ t, t });
    }

    // And a bogus type should fail
    const result = db.conn.exec(
        \\INSERT INTO jobs (id, project_id, type, status, payload, created_at, updated_at)
        \\VALUES ('jbogus', 'p1', 'bogus', 'queued', '{}', '2026-05-28T00:00:00Z', '2026-05-28T00:00:00Z')
    , .{});
    try std.testing.expectError(error.ConstraintCheck, result);
}
```

- [ ] **Step 2: Run tests**

```bash
cd ~/projects/lambe-haath/logos
zig build test
```

Expected: all 4 new tests pass, plus the pre-existing 79.

- [ ] **Step 3: Commit**

```bash
git add src/db/migrations.zig
git commit -m "db: applyV2 migration runner with rollback-on-error semantics + tests"
```

---

## Task 3: Extend `slices.zig` with `kind` / `kind_key` + filename parser

**Target repo:** `~/projects/lambe-haath/logos/`

**Files:**
- Modify: `src/db/slices.zig`

- [ ] **Step 1: Read the existing file**

```bash
cd ~/projects/lambe-haath/logos
cat src/db/slices.zig
```

You should see the existing `Slice` struct, `insert`, `getByKey`, `listByProject`. Plan: add `kind` and `kind_key` to the struct, update `insert` to include them, add `parseKindFromFilename` helper.

- [ ] **Step 2: Update `Slice` struct (top of file)**

Replace the existing `Slice` struct with:

```zig
pub const Slice = struct {
    project_id: []const u8,
    filename: []const u8,
    start_page: u32,
    end_page: u32,
    size_bytes: u64,
    kind: ?SliceKind = null,        // populated from filename parse; null = unknown/other
    kind_key: ?[]const u8 = null,   // 'i'/'ii'/'iii'/'iv' for annexures; '01'/'02'/... for RUDs
    created_at: []const u8,

    pub fn deinit(self: *Slice, gpa: Allocator) void {
        gpa.free(self.project_id);
        gpa.free(self.filename);
        gpa.free(self.created_at);
        if (self.kind_key) |kk| gpa.free(kk);
    }
};

pub const SliceKind = enum {
    annexure,
    rud,
    other,

    pub fn toText(self: SliceKind) []const u8 {
        return switch (self) {
            .annexure => "annexure",
            .rud => "rud",
            .other => "other",
        };
    }

    pub fn fromText(s: []const u8) ?SliceKind {
        if (std.mem.eql(u8, s, "annexure")) return .annexure;
        if (std.mem.eql(u8, s, "rud")) return .rud;
        if (std.mem.eql(u8, s, "other")) return .other;
        return null;
    }
};
```

- [ ] **Step 3: Add filename parser**

Add this function below the struct definitions, above `insert`:

```zig
/// ParsedKind holds the kind + (newly allocated) kind_key extracted from a filename.
/// Caller owns kind_key memory and must free with gpa.free.
pub const ParsedKind = struct { kind: SliceKind, kind_key: ?[]const u8 };

/// Parse a slice filename against the lambe-haath convention.
/// - "annexure-{i,ii,iii,iv}.pdf"  -> { .annexure, kind_key=<roman> }
/// - "rud-NN.pdf" (NN = two digits) -> { .rud,      kind_key=<NN>    }
/// - anything else                  -> { .other,    kind_key=null    }
pub fn parseKindFromFilename(gpa: Allocator, filename: []const u8) !ParsedKind {
    // strip ".pdf"
    if (!std.mem.endsWith(u8, filename, ".pdf")) return .{ .kind = .other, .kind_key = null };
    const stem = filename[0 .. filename.len - ".pdf".len];

    // annexure-{i,ii,iii,iv}
    inline for ([_][]const u8{ "i", "ii", "iii", "iv" }) |roman| {
        if (std.mem.eql(u8, stem, "annexure-" ++ roman)) {
            const owned = try gpa.dupe(u8, roman);
            return .{ .kind = .annexure, .kind_key = owned };
        }
    }

    // rud-NN (exactly two digits)
    const rud_prefix = "rud-";
    if (std.mem.startsWith(u8, stem, rud_prefix)) {
        const tail = stem[rud_prefix.len..];
        if (tail.len == 2 and std.ascii.isDigit(tail[0]) and std.ascii.isDigit(tail[1])) {
            const owned = try gpa.dupe(u8, tail);
            return .{ .kind = .rud, .kind_key = owned };
        }
    }

    return .{ .kind = .other, .kind_key = null };
}
```

- [ ] **Step 4: Update `insert` to write kind + kind_key**

Replace the existing `insert` function with:

```zig
pub fn insert(db: *Db, gpa: Allocator, slice: Slice) !void {
    _ = gpa;
    db.conn.exec(
        \\INSERT INTO slices
        \\  (project_id, filename, start_page, end_page, size_bytes,
        \\   kind, kind_key, created_at)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ,
        .{
            slice.project_id,
            slice.filename,
            @as(i64, @intCast(slice.start_page)),
            @as(i64, @intCast(slice.end_page)),
            @as(i64, @intCast(slice.size_bytes)),
            if (slice.kind) |k| k.toText() else null,
            slice.kind_key,
            slice.created_at,
        },
    ) catch |err| return errors.mapConstraintErr(err);
}
```

- [ ] **Step 5: Update `getByKey` and `listByProject` to populate kind + kind_key**

Replace the SELECT column list in `getByKey` (and the matching field assignments) with:

```zig
pub fn getByKey(db: *Db, gpa: Allocator, project_id: []const u8, filename: []const u8) !?Slice {
    const row = (try db.conn.row(
        \\SELECT project_id, filename, start_page, end_page, size_bytes,
        \\       kind, kind_key, created_at
        \\FROM slices WHERE project_id = ? AND filename = ?
    ,
        .{ project_id, filename },
    )) orelse return null;
    defer row.deinit();

    const pid = try gpa.dupe(u8, row.text(0));
    errdefer gpa.free(pid);
    const fname = try gpa.dupe(u8, row.text(1));
    errdefer gpa.free(fname);
    const kind_opt: ?SliceKind = if (row.isNull(5)) null else SliceKind.fromText(row.text(5));
    const kk_opt: ?[]const u8 = if (row.isNull(6)) null else try gpa.dupe(u8, row.text(6));
    errdefer if (kk_opt) |kk| gpa.free(kk);
    const created = try gpa.dupe(u8, row.text(7));
    errdefer gpa.free(created);

    return .{
        .project_id = pid,
        .filename = fname,
        .start_page = @intCast(row.int(2)),
        .end_page = @intCast(row.int(3)),
        .size_bytes = @intCast(row.int(4)),
        .kind = kind_opt,
        .kind_key = kk_opt,
        .created_at = created,
    };
}
```

Apply the analogous change to `listByProject` (extend SELECT, populate kind/kind_key per row). Use the existing `listByProject` as a template — keep the same iteration shape.

- [ ] **Step 6: Add tests at the bottom of `slices.zig`**

```zig
test "parseKindFromFilename: annexure variants" {
    const gpa = std.testing.allocator;

    inline for ([_][]const u8{ "i", "ii", "iii", "iv" }) |roman| {
        var pk = try parseKindFromFilename(gpa, "annexure-" ++ roman ++ ".pdf");
        defer if (pk.kind_key) |kk| gpa.free(kk);
        try std.testing.expectEqual(SliceKind.annexure, pk.kind);
        try std.testing.expectEqualStrings(roman, pk.kind_key.?);
    }
}

test "parseKindFromFilename: rud variants" {
    const gpa = std.testing.allocator;

    var pk1 = try parseKindFromFilename(gpa, "rud-01.pdf");
    defer if (pk1.kind_key) |kk| gpa.free(kk);
    try std.testing.expectEqual(SliceKind.rud, pk1.kind);
    try std.testing.expectEqualStrings("01", pk1.kind_key.?);

    var pk2 = try parseKindFromFilename(gpa, "rud-42.pdf");
    defer if (pk2.kind_key) |kk| gpa.free(kk);
    try std.testing.expectEqual(SliceKind.rud, pk2.kind);
    try std.testing.expectEqualStrings("42", pk2.kind_key.?);
}

test "parseKindFromFilename: non-conforming names are other" {
    const gpa = std.testing.allocator;

    inline for ([_][]const u8{
        "supplement.pdf",          // not annexure / rud
        "annexure-v.pdf",          // Roman not in {i, ii, iii, iv}
        "rud-1.pdf",               // one digit, not two
        "rud-001.pdf",             // three digits, not two
        "annexure-i.txt",          // not .pdf
        "annexure-ii.PDF",         // case-sensitive: must be lowercase
    }) |name| {
        var pk = try parseKindFromFilename(gpa, name);
        defer if (pk.kind_key) |kk| gpa.free(kk);
        try std.testing.expectEqual(SliceKind.other, pk.kind);
        try std.testing.expect(pk.kind_key == null);
    }
}

test "insert + getByKey round-trips kind and kind_key" {
    const Db = @import("db.zig").Db;
    var db = try Db.open(":memory:");
    defer db.close();
    const gpa = std.testing.allocator;

    try test_helpers.insertProject(&db, "p1");

    try insert(&db, gpa, .{
        .project_id = "p1",
        .filename = "annexure-ii.pdf",
        .start_page = 5,
        .end_page = 10,
        .size_bytes = 1024,
        .kind = .annexure,
        .kind_key = "ii",
        .created_at = "2026-05-28T00:00:00Z",
    });

    var got = (try getByKey(&db, gpa, "p1", "annexure-ii.pdf")).?;
    defer got.deinit(gpa);
    try std.testing.expectEqual(SliceKind.annexure, got.kind.?);
    try std.testing.expectEqualStrings("ii", got.kind_key.?);
}
```

You'll need a `test_helpers.insertProject` helper. If it doesn't exist, add it to `src/db/test_helpers.zig`:

```zig
pub fn insertProject(db: *Db, id: []const u8) !void {
    try db.conn.exec(
        \\INSERT INTO projects (id, name, created_at, last_opened_at,
        \\  chargesheet_filename, chargesheet_page_count, chargesheet_size_bytes)
        \\VALUES (?, ?, '2026-05-28T00:00:00Z', '2026-05-28T00:00:00Z', 'c.pdf', 1, 1)
    , .{ id, id });
}
```

- [ ] **Step 7: Run tests**

```bash
cd ~/projects/lambe-haath/logos
zig build test
```

Expected: 6+ new tests pass.

- [ ] **Step 8: Commit**

```bash
git add src/db/slices.zig src/db/test_helpers.zig
git commit -m "db/slices: add kind/kind_key + filename parser per lambe-haath convention"
```

---

## Task 4: Create `db/extractions.zig`

**Target repo:** `~/projects/lambe-haath/logos/`

**Files:**
- Create: `src/db/extractions.zig`
- Modify: `src/root.zig` to re-export it

- [ ] **Step 1: Create `src/db/extractions.zig`**

```zig
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

    while (rows.next()) |row| {
        const e = try rowToExtraction(row, gpa);
        try list.append(gpa, e);
    }
    return try list.toOwnedSlice(gpa);
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

    return .{
        .project_id = pid,
        .slice_filename = sf,
        .markdown_path = md,
        .meta_path = mp,
        .model = mdl,
        .pages = @intCast(row.int(5)),
        .page_markers_found = @intCast(row.int(6)),
        .input_tokens = if (row.isNull(7)) null else row.int(7),
        .output_tokens = if (row.isNull(8)) null else row.int(8),
        .input_cost_usd = if (row.isNull(9)) null else row.float(9),
        .output_cost_usd = if (row.isNull(10)) null else row.float(10),
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

    try db.conn.exec("DELETE FROM slices WHERE project_id=? AND filename=?", .{ "p1", "annexure-i.pdf" });

    try std.testing.expect((try getByKey(&db, gpa, "p1", "annexure-i.pdf")) == null);
}
```

- [ ] **Step 2: Re-export from `src/root.zig`**

Add to `src/root.zig`:

```zig
pub const extractions = @import("db/extractions.zig");
```

- [ ] **Step 3: Run tests**

```bash
cd ~/projects/lambe-haath/logos
zig build test
```

Expected: 3 new tests pass.

- [ ] **Step 4: Commit**

```bash
git add src/db/extractions.zig src/root.zig
git commit -m "db/extractions: upsert+get+list with idempotency + FK cascade tests"
```

---

## Task 5: Create `db/prompt_outputs.zig`

**Target repo:** `~/projects/lambe-haath/logos/`

**Files:**
- Create: `src/db/prompt_outputs.zig`
- Modify: `src/root.zig`

- [ ] **Step 1: Create `src/db/prompt_outputs.zig`**

Mirror the structure of `extractions.zig`. The shape is:

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const Db = @import("db.zig").Db;
const errors = @import("errors.zig");
const test_helpers = @import("test_helpers.zig");

pub const PromptOutput = struct {
    project_id: []const u8,
    prompt_name: []const u8,
    markdown_path: []const u8,
    model: []const u8,
    input_tokens: ?i64 = null,
    output_tokens: ?i64 = null,
    input_cost_usd: ?f64 = null,
    output_cost_usd: ?f64 = null,
    latency_s: f64,
    warnings_json: []const u8,  // raw JSON array text; caller parses if needed
    created_at: []const u8,

    pub fn deinit(self: *PromptOutput, gpa: Allocator) void {
        gpa.free(self.project_id);
        gpa.free(self.prompt_name);
        gpa.free(self.markdown_path);
        gpa.free(self.model);
        gpa.free(self.warnings_json);
        gpa.free(self.created_at);
    }
};

pub fn deinitList(list: []PromptOutput, gpa: Allocator) void {
    for (list) |*p| p.deinit(gpa);
    gpa.free(list);
}

pub fn upsert(db: *Db, gpa: Allocator, p: PromptOutput) !void {
    _ = gpa;
    db.conn.exec(
        \\INSERT INTO prompt_outputs
        \\  (project_id, prompt_name, markdown_path, model,
        \\   input_tokens, output_tokens, input_cost_usd, output_cost_usd,
        \\   latency_s, warnings, created_at)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        \\ON CONFLICT(project_id, prompt_name) DO UPDATE SET
        \\  markdown_path   = excluded.markdown_path,
        \\  model           = excluded.model,
        \\  input_tokens    = excluded.input_tokens,
        \\  output_tokens   = excluded.output_tokens,
        \\  input_cost_usd  = excluded.input_cost_usd,
        \\  output_cost_usd = excluded.output_cost_usd,
        \\  latency_s       = excluded.latency_s,
        \\  warnings        = excluded.warnings,
        \\  created_at      = excluded.created_at
    , .{
        p.project_id,
        p.prompt_name,
        p.markdown_path,
        p.model,
        p.input_tokens,
        p.output_tokens,
        p.input_cost_usd,
        p.output_cost_usd,
        p.latency_s,
        p.warnings_json,
        p.created_at,
    }) catch |err| return errors.mapConstraintErr(err);
}

pub fn getByKey(
    db: *Db,
    gpa: Allocator,
    project_id: []const u8,
    prompt_name: []const u8,
) !?PromptOutput {
    const row = (try db.conn.row(
        \\SELECT project_id, prompt_name, markdown_path, model,
        \\       input_tokens, output_tokens, input_cost_usd, output_cost_usd,
        \\       latency_s, warnings, created_at
        \\FROM prompt_outputs WHERE project_id = ? AND prompt_name = ?
    , .{ project_id, prompt_name })) orelse return null;
    defer row.deinit();

    return try rowToPromptOutput(row, gpa);
}

pub fn listByProject(db: *Db, gpa: Allocator, project_id: []const u8) ![]PromptOutput {
    var list: std.ArrayList(PromptOutput) = .empty;
    errdefer {
        for (list.items) |*p| p.deinit(gpa);
        list.deinit(gpa);
    }
    var rows = try db.conn.rows(
        \\SELECT project_id, prompt_name, markdown_path, model,
        \\       input_tokens, output_tokens, input_cost_usd, output_cost_usd,
        \\       latency_s, warnings, created_at
        \\FROM prompt_outputs WHERE project_id = ? ORDER BY prompt_name ASC
    , .{project_id});
    defer rows.deinit();

    while (rows.next()) |row| {
        const p = try rowToPromptOutput(row, gpa);
        try list.append(gpa, p);
    }
    return try list.toOwnedSlice(gpa);
}

fn rowToPromptOutput(row: anytype, gpa: Allocator) !PromptOutput {
    const pid = try gpa.dupe(u8, row.text(0));
    errdefer gpa.free(pid);
    const pn = try gpa.dupe(u8, row.text(1));
    errdefer gpa.free(pn);
    const md = try gpa.dupe(u8, row.text(2));
    errdefer gpa.free(md);
    const mdl = try gpa.dupe(u8, row.text(3));
    errdefer gpa.free(mdl);
    const warnings = try gpa.dupe(u8, row.text(9));
    errdefer gpa.free(warnings);
    const created = try gpa.dupe(u8, row.text(10));
    errdefer gpa.free(created);

    return .{
        .project_id = pid,
        .prompt_name = pn,
        .markdown_path = md,
        .model = mdl,
        .input_tokens = if (row.isNull(4)) null else row.int(4),
        .output_tokens = if (row.isNull(5)) null else row.int(5),
        .input_cost_usd = if (row.isNull(6)) null else row.float(6),
        .output_cost_usd = if (row.isNull(7)) null else row.float(7),
        .latency_s = row.float(8),
        .warnings_json = warnings,
        .created_at = created,
    };
}

test "upsert + getByKey round-trip" {
    var db = try Db.open(":memory:");
    defer db.close();
    const gpa = std.testing.allocator;
    try test_helpers.insertProject(&db, "p1");

    try upsert(&db, gpa, .{
        .project_id = "p1",
        .prompt_name = "evidence_audit",
        .markdown_path = "/tmp/ea.md",
        .model = "claude-sonnet-4-6",
        .input_tokens = 50000,
        .output_tokens = 10000,
        .input_cost_usd = 0.15,
        .output_cost_usd = 0.15,
        .latency_s = 42.0,
        .warnings_json = "[]",
        .created_at = "2026-05-28T00:00:00Z",
    });

    var got = (try getByKey(&db, gpa, "p1", "evidence_audit")).?;
    defer got.deinit(gpa);
    try std.testing.expectEqualStrings("/tmp/ea.md", got.markdown_path);
    try std.testing.expectEqualStrings("claude-sonnet-4-6", got.model);
    try std.testing.expectEqualStrings("[]", got.warnings_json);
}

test "upsert overwrites and warnings can be updated" {
    var db = try Db.open(":memory:");
    defer db.close();
    const gpa = std.testing.allocator;
    try test_helpers.insertProject(&db, "p1");

    const base = PromptOutput{
        .project_id = "p1",
        .prompt_name = "evidence_audit",
        .markdown_path = "/v1.md",
        .model = "gemini-2.5-flash",
        .latency_s = 5.0,
        .warnings_json = "[]",
        .created_at = "2026-05-28T00:00:00Z",
    };
    try upsert(&db, gpa, base);

    var updated = base;
    updated.markdown_path = "/v2.md";
    updated.warnings_json = "[\"empty_output\"]";
    try upsert(&db, gpa, updated);

    var got = (try getByKey(&db, gpa, "p1", "evidence_audit")).?;
    defer got.deinit(gpa);
    try std.testing.expectEqualStrings("/v2.md", got.markdown_path);
    try std.testing.expectEqualStrings("[\"empty_output\"]", got.warnings_json);
}

test "deleting a project cascades to prompt_outputs" {
    var db = try Db.open(":memory:");
    defer db.close();
    const gpa = std.testing.allocator;
    try test_helpers.insertProject(&db, "p1");

    try upsert(&db, gpa, .{
        .project_id = "p1",
        .prompt_name = "evidence_audit",
        .markdown_path = "/x.md",
        .model = "claude-sonnet-4-6",
        .latency_s = 1.0,
        .warnings_json = "[]",
        .created_at = "2026-05-28T00:00:00Z",
    });

    try db.conn.exec("DELETE FROM projects WHERE id=?", .{"p1"});

    try std.testing.expect((try getByKey(&db, gpa, "p1", "evidence_audit")) == null);
}
```

- [ ] **Step 2: Re-export from `src/root.zig`**

```zig
pub const prompt_outputs = @import("db/prompt_outputs.zig");
```

- [ ] **Step 3: Run tests**

```bash
cd ~/projects/lambe-haath/logos
zig build test
```

Expected: 3 new tests pass.

- [ ] **Step 4: Commit**

```bash
git add src/db/prompt_outputs.zig src/root.zig
git commit -m "db/prompt_outputs: upsert+get+list with FK cascade tests"
```

---

## Task 6: Create `db/job_logs.zig`

**Target repo:** `~/projects/lambe-haath/logos/`

**Files:**
- Create: `src/db/job_logs.zig`
- Modify: `src/root.zig`

- [ ] **Step 1: Create `src/db/job_logs.zig`**

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const Db = @import("db.zig").Db;
const errors = @import("errors.zig");
const test_helpers = @import("test_helpers.zig");

pub const Level = enum {
    debug,
    info,
    warning,
    @"error",

    pub fn toText(self: Level) []const u8 {
        return switch (self) {
            .debug => "debug",
            .info => "info",
            .warning => "warning",
            .@"error" => "error",
        };
    }

    pub fn fromText(s: []const u8) ?Level {
        if (std.mem.eql(u8, s, "debug")) return .debug;
        if (std.mem.eql(u8, s, "info")) return .info;
        if (std.mem.eql(u8, s, "warning")) return .warning;
        if (std.mem.eql(u8, s, "error")) return .@"error";
        return null;
    }
};

pub const JobLog = struct {
    id: i64,
    job_id: []const u8,
    ts: []const u8,
    level: Level,
    logger: []const u8,
    message: []const u8,

    pub fn deinit(self: *JobLog, gpa: Allocator) void {
        gpa.free(self.job_id);
        gpa.free(self.ts);
        gpa.free(self.logger);
        gpa.free(self.message);
    }
};

pub fn deinitList(list: []JobLog, gpa: Allocator) void {
    for (list) |*l| l.deinit(gpa);
    gpa.free(list);
}

pub fn insert(
    db: *Db,
    job_id: []const u8,
    ts: []const u8,
    level: Level,
    logger: []const u8,
    message: []const u8,
) !void {
    db.conn.exec(
        \\INSERT INTO job_logs (job_id, ts, level, logger, message)
        \\VALUES (?, ?, ?, ?, ?)
    , .{
        job_id,
        ts,
        level.toText(),
        logger,
        message,
    }) catch |err| return errors.mapConstraintErr(err);
}

pub fn listByJob(db: *Db, gpa: Allocator, job_id: []const u8) ![]JobLog {
    var list: std.ArrayList(JobLog) = .empty;
    errdefer {
        for (list.items) |*l| l.deinit(gpa);
        list.deinit(gpa);
    }
    var rows = try db.conn.rows(
        \\SELECT id, job_id, ts, level, logger, message
        \\FROM job_logs WHERE job_id = ? ORDER BY id ASC
    , .{job_id});
    defer rows.deinit();
    while (rows.next()) |row| {
        const jid = try gpa.dupe(u8, row.text(1));
        errdefer gpa.free(jid);
        const ts = try gpa.dupe(u8, row.text(2));
        errdefer gpa.free(ts);
        const level = Level.fromText(row.text(3)) orelse return error.InvalidLogLevel;
        const logger = try gpa.dupe(u8, row.text(4));
        errdefer gpa.free(logger);
        const message = try gpa.dupe(u8, row.text(5));
        errdefer gpa.free(message);

        try list.append(gpa, .{
            .id = row.int(0),
            .job_id = jid,
            .ts = ts,
            .level = level,
            .logger = logger,
            .message = message,
        });
    }
    return try list.toOwnedSlice(gpa);
}

test "insert + listByJob preserves insertion order" {
    var db = try Db.open(":memory:");
    defer db.close();
    const gpa = std.testing.allocator;
    try test_helpers.insertProject(&db, "p1");
    try test_helpers.insertJob(&db, "j1", "p1", "ocr");

    try insert(&db, "j1", "2026-05-28T00:00:01Z", .info, "ocr_agent", "Processing slice");
    try insert(&db, "j1", "2026-05-28T00:00:02Z", .info, "ocr_agent", "Uploaded to Gemini");
    try insert(&db, "j1", "2026-05-28T00:00:03Z", .warning, "ocr_agent", "Slow response");

    var logs = try listByJob(&db, gpa, "j1");
    defer deinitList(logs, gpa);

    try std.testing.expectEqual(@as(usize, 3), logs.len);
    try std.testing.expectEqualStrings("Processing slice", logs[0].message);
    try std.testing.expectEqual(Level.warning, logs[2].level);
}

test "deleting a job cascades to job_logs" {
    var db = try Db.open(":memory:");
    defer db.close();
    const gpa = std.testing.allocator;
    try test_helpers.insertProject(&db, "p1");
    try test_helpers.insertJob(&db, "j1", "p1", "ocr");

    try insert(&db, "j1", "2026-05-28T00:00:01Z", .info, "ocr_agent", "hello");
    try db.conn.exec("DELETE FROM jobs WHERE id=?", .{"j1"});

    const logs = try listByJob(&db, gpa, "j1");
    defer deinitList(logs, gpa);
    try std.testing.expectEqual(@as(usize, 0), logs.len);
}

test "rejects invalid level via CHECK constraint" {
    var db = try Db.open(":memory:");
    defer db.close();
    try test_helpers.insertProject(&db, "p1");
    try test_helpers.insertJob(&db, "j1", "p1", "ocr");

    const result = db.conn.exec(
        \\INSERT INTO job_logs (job_id, ts, level, logger, message)
        \\VALUES (?, ?, ?, ?, ?)
    , .{ "j1", "2026-05-28T00:00:01Z", "critical", "x", "y" });

    try std.testing.expectError(error.ConstraintCheck, result);
}
```

- [ ] **Step 2: Add `insertJob` to `src/db/test_helpers.zig`**

```zig
pub fn insertJob(db: *Db, id: []const u8, project_id: []const u8, job_type: []const u8) !void {
    try db.conn.exec(
        \\INSERT INTO jobs (id, project_id, type, status, payload, created_at, updated_at)
        \\VALUES (?, ?, ?, 'queued', '{}', '2026-05-28T00:00:00Z', '2026-05-28T00:00:00Z')
    , .{ id, project_id, job_type });
}
```

- [ ] **Step 3: Re-export from `src/root.zig`**

```zig
pub const job_logs = @import("db/job_logs.zig");
```

- [ ] **Step 4: Run tests**

```bash
cd ~/projects/lambe-haath/logos
zig build test
```

Expected: 3 new tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/db/job_logs.zig src/db/test_helpers.zig src/root.zig
git commit -m "db/job_logs: insert+list per-job with FK cascade + CHECK on level"
```

---

## Task 7: Create `agents/pricing.zig`

**Target repo:** `~/projects/lambe-haath/logos/`

**Files:**
- Create: `src/agents/pricing.zig`
- Modify: `src/root.zig`

- [ ] **Step 1: Create the file (no I/O, pure constants + lookup)**

```zig
const std = @import("std");

/// Per-million-token rates in USD. Append rows when introducing a new model;
/// never modify an existing row (historical jobs reference these rates via
/// stored *_cost_usd columns).
pub const ModelRate = struct {
    model: []const u8,
    input_per_million_usd: f64,
    output_per_million_usd: f64,
};

pub const PRICING: []const ModelRate = &.{
    .{ .model = "gemini-2.5-flash",  .input_per_million_usd = 0.30, .output_per_million_usd = 2.50 },
    .{ .model = "gemini-2.5-pro",    .input_per_million_usd = 1.25, .output_per_million_usd = 10.00 },
    .{ .model = "claude-sonnet-4-6", .input_per_million_usd = 3.00, .output_per_million_usd = 15.00 },
};

pub fn lookup(model: []const u8) ?ModelRate {
    for (PRICING) |row| {
        if (std.mem.eql(u8, row.model, model)) return row;
    }
    return null;
}

/// Compute (input_cost_usd, output_cost_usd) for the given model and token counts.
/// Returns null if the model isn't in the pricing table; callers should leave the
/// corresponding DB columns NULL ("uncosted").
pub const CostUsd = struct { input: f64, output: f64 };

pub fn cost(model: []const u8, input_tokens: i64, output_tokens: i64) ?CostUsd {
    const rate = lookup(model) orelse return null;
    const in_f: f64 = @floatFromInt(input_tokens);
    const out_f: f64 = @floatFromInt(output_tokens);
    return .{
        .input = in_f * rate.input_per_million_usd / 1_000_000.0,
        .output = out_f * rate.output_per_million_usd / 1_000_000.0,
    };
}

test "lookup returns known models" {
    const r = lookup("gemini-2.5-flash") orelse return error.NotFound;
    try std.testing.expectApproxEqAbs(@as(f64, 0.30), r.input_per_million_usd, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f64, 2.50), r.output_per_million_usd, 0.0001);
}

test "lookup returns null for unknown models" {
    try std.testing.expect(lookup("nope-model") == null);
}

test "cost computation for known model" {
    const c = cost("gemini-2.5-flash", 46_154, 136_477) orelse return error.NotFound;
    // 46154 * 0.30 / 1e6 = 0.01384620
    try std.testing.expectApproxEqAbs(@as(f64, 0.01384620), c.input, 1e-6);
    // 136477 * 2.50 / 1e6 = 0.34119250
    try std.testing.expectApproxEqAbs(@as(f64, 0.34119250), c.output, 1e-6);
}

test "cost returns null for uncosted model" {
    try std.testing.expect(cost("unknown-llm", 1000, 5000) == null);
}
```

- [ ] **Step 2: Re-export from `src/root.zig`**

```zig
pub const pricing = @import("agents/pricing.zig");
```

(If `src/agents/` doesn't exist as a directory yet, `mkdir src/agents` is implied — `zig build` will compile any file referenced from `root.zig`.)

- [ ] **Step 3: Run tests**

```bash
cd ~/projects/lambe-haath/logos
zig build test
```

Expected: 4 new tests pass.

- [ ] **Step 4: Commit**

```bash
git add src/agents/pricing.zig src/root.zig
git commit -m "agents/pricing: append-only model rate table + cost computation"
```

---

## Task 8: Create `agents/jsonrpc.zig` — message types + decoder

**Target repo:** `~/projects/lambe-haath/logos/`

**Files:**
- Create: `src/agents/jsonrpc.zig`
- Modify: `src/root.zig`

The codec is pure: no I/O. It parses one line of newline-delimited JSON-RPC 2.0 into a tagged union, and serializes a tagged union back into a single line.

- [ ] **Step 1: Create `src/agents/jsonrpc.zig`**

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;

/// JSON-RPC 2.0 message types over newline-delimited stdio.
/// All `params` / `result` / `error.data` values are stored as raw JSON strings
/// (the caller parses them based on the method name).
pub const Message = union(enum) {
    request: Request,
    response: Response,
    notification: Notification,

    pub fn deinit(self: *Message, gpa: Allocator) void {
        switch (self.*) {
            .request => |*r| r.deinit(gpa),
            .response => |*r| r.deinit(gpa),
            .notification => |*n| n.deinit(gpa),
        }
    }
};

pub const Request = struct {
    id: i64,                    // we use integer ids exclusively; string ids rejected
    method: []const u8,
    params_json: ?[]const u8,   // raw JSON for params object/array; null if absent

    pub fn deinit(self: *Request, gpa: Allocator) void {
        gpa.free(self.method);
        if (self.params_json) |p| gpa.free(p);
    }
};

pub const Response = struct {
    id: i64,
    body: ResponseBody,

    pub fn deinit(self: *Response, gpa: Allocator) void {
        switch (self.body) {
            .result => |*r| gpa.free(r.*),
            .err => |*e| e.deinit(gpa),
        }
    }
};

pub const ResponseBody = union(enum) {
    result: []const u8,      // raw JSON for the result value
    err: ErrorObject,
};

pub const ErrorObject = struct {
    code: i64,
    message: []const u8,
    data_json: ?[]const u8,  // raw JSON for `data`; null if absent

    pub fn deinit(self: *ErrorObject, gpa: Allocator) void {
        gpa.free(self.message);
        if (self.data_json) |d| gpa.free(d);
    }
};

pub const Notification = struct {
    method: []const u8,
    params_json: ?[]const u8,

    pub fn deinit(self: *Notification, gpa: Allocator) void {
        gpa.free(self.method);
        if (self.params_json) |p| gpa.free(p);
    }
};

pub const DecodeError = error{
    InvalidJson,
    MissingJsonrpcField,
    UnsupportedJsonrpcVersion,
    InvalidMessageShape,    // doesn't match request/response/notification
    InvalidIdType,          // we accept integer ids only
    BothResultAndError,
    NeitherResultNorError,
};

/// Decode one line of newline-delimited JSON into a Message.
/// `line` is the full line content including but tolerant of a trailing '\n'.
/// On success, caller owns the returned Message (call deinit).
pub fn decodeLine(gpa: Allocator, line: []const u8) DecodeError!Message {
    // Trim trailing newline if present (defensive; the reader should strip it).
    var trimmed = line;
    while (trimmed.len > 0 and (trimmed[trimmed.len - 1] == '\n' or trimmed[trimmed.len - 1] == '\r')) {
        trimmed = trimmed[0 .. trimmed.len - 1];
    }
    if (trimmed.len == 0) return DecodeError.InvalidJson;

    var parsed = json.parseFromSlice(json.Value, gpa, trimmed, .{}) catch return DecodeError.InvalidJson;
    defer parsed.deinit();

    if (parsed.value != .object) return DecodeError.InvalidMessageShape;
    const obj = parsed.value.object;

    // Check jsonrpc version
    const jr = obj.get("jsonrpc") orelse return DecodeError.MissingJsonrpcField;
    if (jr != .string or !std.mem.eql(u8, jr.string, "2.0")) return DecodeError.UnsupportedJsonrpcVersion;

    const has_id = obj.contains("id");
    const has_method = obj.contains("method");
    const has_result = obj.contains("result");
    const has_error = obj.contains("error");

    // Determine shape
    if (has_method and has_id) {
        // Request
        const id = try extractIntId(obj.get("id").?);
        const method_val = obj.get("method").?;
        if (method_val != .string) return DecodeError.InvalidMessageShape;
        const method = try gpa.dupe(u8, method_val.string);
        errdefer gpa.free(method);
        const params = if (obj.get("params")) |p| try stringifyAlloc(gpa, p) else null;

        return Message{ .request = .{
            .id = id,
            .method = method,
            .params_json = params,
        } };
    } else if (has_method and !has_id) {
        // Notification
        const method_val = obj.get("method").?;
        if (method_val != .string) return DecodeError.InvalidMessageShape;
        const method = try gpa.dupe(u8, method_val.string);
        errdefer gpa.free(method);
        const params = if (obj.get("params")) |p| try stringifyAlloc(gpa, p) else null;

        return Message{ .notification = .{
            .method = method,
            .params_json = params,
        } };
    } else if (has_id and (has_result or has_error)) {
        // Response
        const id = try extractIntId(obj.get("id").?);
        if (has_result and has_error) return DecodeError.BothResultAndError;

        if (has_result) {
            const result_json = try stringifyAlloc(gpa, obj.get("result").?);
            return Message{ .response = .{
                .id = id,
                .body = .{ .result = result_json },
            } };
        } else {
            const err_val = obj.get("error").?;
            if (err_val != .object) return DecodeError.InvalidMessageShape;
            const code_val = err_val.object.get("code") orelse return DecodeError.InvalidMessageShape;
            if (code_val != .integer) return DecodeError.InvalidMessageShape;
            const msg_val = err_val.object.get("message") orelse return DecodeError.InvalidMessageShape;
            if (msg_val != .string) return DecodeError.InvalidMessageShape;
            const msg = try gpa.dupe(u8, msg_val.string);
            errdefer gpa.free(msg);
            const data_json = if (err_val.object.get("data")) |d| try stringifyAlloc(gpa, d) else null;

            return Message{ .response = .{
                .id = id,
                .body = .{ .err = .{
                    .code = code_val.integer,
                    .message = msg,
                    .data_json = data_json,
                } },
            } };
        }
    } else if (has_id and !has_result and !has_error) {
        return DecodeError.NeitherResultNorError;
    } else {
        return DecodeError.InvalidMessageShape;
    }
}

fn extractIntId(v: json.Value) DecodeError!i64 {
    return switch (v) {
        .integer => |i| i,
        else => DecodeError.InvalidIdType,
    };
}

fn stringifyAlloc(gpa: Allocator, v: json.Value) DecodeError![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    json.stringify(v, .{}, buf.writer(gpa)) catch return DecodeError.InvalidJson;
    return try buf.toOwnedSlice(gpa);
}

// --- encode --- //

/// Encode a Message to a newline-terminated line of JSON.
/// Caller owns the returned []u8 (free with gpa.free).
pub fn encode(gpa: Allocator, msg: Message) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    const w = buf.writer(gpa);

    switch (msg) {
        .request => |r| {
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":", .{r.id});
            try writeJsonString(w, r.method);
            if (r.params_json) |p| {
                try w.writeAll(",\"params\":");
                try w.writeAll(p);
            }
            try w.writeAll("}\n");
        },
        .response => |r| {
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},", .{r.id});
            switch (r.body) {
                .result => |res| {
                    try w.writeAll("\"result\":");
                    try w.writeAll(res);
                },
                .err => |e| {
                    try w.print("\"error\":{{\"code\":{d},\"message\":", .{e.code});
                    try writeJsonString(w, e.message);
                    if (e.data_json) |d| {
                        try w.writeAll(",\"data\":");
                        try w.writeAll(d);
                    }
                    try w.writeAll("}");
                },
            }
            try w.writeAll("}\n");
        },
        .notification => |n| {
            try w.writeAll("{\"jsonrpc\":\"2.0\",\"method\":");
            try writeJsonString(w, n.method);
            if (n.params_json) |p| {
                try w.writeAll(",\"params\":");
                try w.writeAll(p);
            }
            try w.writeAll("}\n");
        },
    }
    return try buf.toOwnedSlice(gpa);
}

fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeAll("\"");
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0...8, 11, 12, 14...31 => try w.print("\\u{x:0>4}", .{c}),
            else => try w.writeByte(c),
        }
    }
    try w.writeAll("\"");
}

// --- tests --- //

test "decode initialize request" {
    const gpa = std.testing.allocator;
    const line = "{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"lambe-haath/1\"}}";
    var msg = try decodeLine(gpa, line);
    defer msg.deinit(gpa);

    try std.testing.expect(msg == .request);
    try std.testing.expectEqual(@as(i64, 0), msg.request.id);
    try std.testing.expectEqualStrings("initialize", msg.request.method);
    try std.testing.expect(msg.request.params_json != null);
}

test "decode response with result" {
    const gpa = std.testing.allocator;
    const line = "{\"jsonrpc\":\"2.0\",\"id\":17,\"result\":{\"markdown_path\":\"/x.md\",\"pages\":5}}";
    var msg = try decodeLine(gpa, line);
    defer msg.deinit(gpa);

    try std.testing.expect(msg == .response);
    try std.testing.expectEqual(@as(i64, 17), msg.response.id);
    try std.testing.expect(msg.response.body == .result);
}

test "decode response with error + data" {
    const gpa = std.testing.allocator;
    const line = "{\"jsonrpc\":\"2.0\",\"id\":42,\"error\":{\"code\":-32099,\"message\":\"canceled\",\"data\":{\"reason\":\"user\"}}}";
    var msg = try decodeLine(gpa, line);
    defer msg.deinit(gpa);

    try std.testing.expect(msg == .response);
    try std.testing.expect(msg.response.body == .err);
    try std.testing.expectEqual(@as(i64, -32099), msg.response.body.err.code);
    try std.testing.expectEqualStrings("canceled", msg.response.body.err.message);
    try std.testing.expect(msg.response.body.err.data_json != null);
}

test "decode notification (no id)" {
    const gpa = std.testing.allocator;
    const line = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{\"progress\":0.5}}";
    var msg = try decodeLine(gpa, line);
    defer msg.deinit(gpa);

    try std.testing.expect(msg == .notification);
    try std.testing.expectEqualStrings("notifications/progress", msg.notification.method);
}

test "reject missing jsonrpc field" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(
        DecodeError.MissingJsonrpcField,
        decodeLine(gpa, "{\"id\":1,\"method\":\"x\"}"),
    );
}

test "reject wrong jsonrpc version" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(
        DecodeError.UnsupportedJsonrpcVersion,
        decodeLine(gpa, "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"x\"}"),
    );
}

test "reject malformed JSON" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(
        DecodeError.InvalidJson,
        decodeLine(gpa, "this is not json"),
    );
}

test "reject empty line" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(
        DecodeError.InvalidJson,
        decodeLine(gpa, ""),
    );
}

test "encode request round-trip" {
    const gpa = std.testing.allocator;
    const msg = Message{ .request = .{
        .id = 1,
        .method = "test",
        .params_json = "{\"foo\":42}",
    } };
    const line = try encode(gpa, msg);
    defer gpa.free(line);

    var decoded = try decodeLine(gpa, line);
    defer decoded.deinit(gpa);
    try std.testing.expect(decoded == .request);
    try std.testing.expectEqual(@as(i64, 1), decoded.request.id);
    try std.testing.expectEqualStrings("test", decoded.request.method);
}

test "encode notification round-trip" {
    const gpa = std.testing.allocator;
    const msg = Message{ .notification = .{
        .method = "notifications/progress",
        .params_json = "{\"progress\":0.5}",
    } };
    const line = try encode(gpa, msg);
    defer gpa.free(line);

    var decoded = try decodeLine(gpa, line);
    defer decoded.deinit(gpa);
    try std.testing.expect(decoded == .notification);
}

test "encode escapes string special chars" {
    const gpa = std.testing.allocator;
    const msg = Message{ .notification = .{
        .method = "log",
        .params_json = "{\"message\":\"line1\\nline2\\twith \\\"quotes\\\"\"}",
    } };
    const line = try encode(gpa, msg);
    defer gpa.free(line);
    // The encoded line must itself contain exactly one trailing '\n' as the line terminator,
    // not embedded raw newlines.
    var newline_count: usize = 0;
    for (line) |c| if (c == '\n') {
        newline_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), newline_count);
    try std.testing.expectEqual(@as(u8, '\n'), line[line.len - 1]);
}
```

- [ ] **Step 2: Re-export from `src/root.zig`**

```zig
pub const jsonrpc = @import("agents/jsonrpc.zig");
```

- [ ] **Step 3: Run tests**

```bash
cd ~/projects/lambe-haath/logos
zig build test
```

Expected: 10 new tests pass.

- [ ] **Step 4: Commit**

```bash
git add src/agents/jsonrpc.zig src/root.zig
git commit -m "agents/jsonrpc: Message types + encode + decodeLine codec with 10 tests"
```

---

## Task 9: Bootstrap Python test workspace

**Target repo:** `~/projects/chargesheets/pdf-extraction-experiments/`

**Files:**
- Create: `tests/__init__.py` (empty)
- Create: `tests/conftest.py`
- Modify: `pyproject.toml` (add `pytest` to dev deps, register `protocol` marker)

- [ ] **Step 1: Create `tests/__init__.py`**

```bash
cd ~/projects/chargesheets/pdf-extraction-experiments
touch tests/__init__.py
```

- [ ] **Step 2: Create `tests/conftest.py`**

```python
"""Shared pytest fixtures for lambe-haath agent + protocol tests."""

import os
import sys
from pathlib import Path

# Make `tests/` importable as a package so test files can `from tests.mock_agent ...`
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
```

- [ ] **Step 3: Modify `pyproject.toml`**

Append to the existing file (or create the `[tool.pytest.ini_options]` and dev-deps sections if missing):

```toml
[dependency-groups]
dev = [
    "pytest>=8.0",
]

[tool.pytest.ini_options]
testpaths = ["tests"]
markers = [
    "protocol: protocol-conformance tests (drive an agent binary through the lambe-haath/1 lifecycle)",
    "unit: pure unit tests (no I/O, no subprocesses)",
]
```

- [ ] **Step 4: Sync dev deps**

You will need to run this — it's a setup command:

```bash
cd ~/projects/chargesheets/pdf-extraction-experiments
uv sync --dev
```

Then verify pytest is on PATH inside the venv:

```bash
.venv/bin/pytest --version
```

Expected: `pytest 8.x.y`.

- [ ] **Step 5: Commit**

```bash
git add tests/__init__.py tests/conftest.py pyproject.toml uv.lock
git commit -m "test: bootstrap pytest workspace with protocol and unit markers"
```

---

## Task 10: Create `tests/mock_agent.py`

**Target repo:** `~/projects/chargesheets/pdf-extraction-experiments/`

**Files:**
- Create: `tests/mock_agent.py`

The mock agent is a standalone executable Python script that speaks the `lambe-haath/1` protocol. Behavior controlled by env vars (`MOCK_*`) so tests can simulate every state-machine edge.

- [ ] **Step 1: Create `tests/mock_agent.py`**

```python
#!/usr/bin/env python3
"""
Mock agent for the lambe-haath/1 JSON-RPC protocol.

Reads newline-delimited JSON-RPC requests from stdin, writes responses + notifications
to stdout. Behavior is controlled by environment variables so tests can simulate every
edge of the agent state machine.

Env vars:
    MOCK_CAPABILITIES    JSON string returned in initialize response's `capabilities`.
                         Default: {"methods": ["mock.echo"], "progress": true, "cancellation": true}
    MOCK_LATENCY_S       float; sleep this many seconds before responding to each method call.
    MOCK_PROGRESS_TICKS  int; emit N notifications/progress events between request and response.
    MOCK_FAIL_AFTER_N    int; after handling N method calls, call os._exit(1) to simulate crash.
                         Special: MOCK_FAIL_AFTER_N=0 means crash on the *first* call.
    MOCK_HANG_AFTER_N    int; after handling N method calls, stop reading stdin (simulates wedge).
    MOCK_PARSE_GARBAGE_AFTER_N  int; after handling N calls, emit a non-JSON line on stdout
                                 (tests host codec robustness).

This script has *no third-party deps* — stdlib only. That keeps it portable and
makes it useful as a polyglot test fixture for future Go/Rust/Zig agents.
"""

from __future__ import annotations

import json
import os
import sys
import time


def emit(obj: dict) -> None:
    """Write a single JSON-RPC message as one newline-terminated line to stdout."""
    sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def emit_garbage() -> None:
    sys.stdout.write("this is not json at all\n")
    sys.stdout.flush()


def get_int_env(name: str) -> int | None:
    v = os.environ.get(name)
    if v is None:
        return None
    try:
        return int(v)
    except ValueError:
        return None


def main() -> None:
    method_calls_handled = 0
    fail_after = get_int_env("MOCK_FAIL_AFTER_N")
    hang_after = get_int_env("MOCK_HANG_AFTER_N")
    garbage_after = get_int_env("MOCK_PARSE_GARBAGE_AFTER_N")
    latency_s = float(os.environ.get("MOCK_LATENCY_S", "0") or "0")
    progress_ticks = int(os.environ.get("MOCK_PROGRESS_TICKS", "0") or "0")
    capabilities = json.loads(
        os.environ.get(
            "MOCK_CAPABILITIES",
            '{"methods":["mock.echo"],"progress":true,"cancellation":true}',
        )
    )

    initialized = False

    for raw_line in sys.stdin:
        line = raw_line.rstrip("\n").rstrip("\r")
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            # Malformed input from host. Per protocol, we ignore (host bug).
            continue

        method = msg.get("method")
        msg_id = msg.get("id")
        is_notification = "id" not in msg

        if is_notification:
            # Host -> agent notifications. We handle 'notifications/initialized'
            # and 'notifications/cancelled'. Otherwise ignore.
            if method == "notifications/initialized":
                initialized = True
            # Cancellation is a no-op for the mock; tests assert observable effects elsewhere.
            continue

        if method == "initialize":
            emit({
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": {
                    "protocolVersion": "lambe-haath/1",
                    "agentInfo": {"name": "mock_agent", "version": "0.1.0"},
                    "capabilities": capabilities,
                },
            })
            continue

        if method == "shutdown":
            emit({"jsonrpc": "2.0", "id": msg_id, "result": None})
            # Host will send notifications/exit next; we exit then.
            continue

        # Any other method call: run our mock behavior
        method_calls_handled += 1

        if fail_after is not None and method_calls_handled > fail_after:
            # Simulate crash. Note: fail_after=0 means "crash on first method call".
            os._exit(1)

        if hang_after is not None and method_calls_handled > hang_after:
            # Stop reading stdin to simulate a wedged process.
            while True:
                time.sleep(60)

        if garbage_after is not None and method_calls_handled > garbage_after:
            emit_garbage()
            continue

        # Emit progress ticks if requested.
        params = msg.get("params", {}) or {}
        progress_token = (params.get("_meta") or {}).get("progressToken")
        if progress_token and progress_ticks > 0:
            for i in range(progress_ticks):
                emit({
                    "jsonrpc": "2.0",
                    "method": "notifications/progress",
                    "params": {
                        "progressToken": progress_token,
                        "progress": (i + 1) / progress_ticks,
                        "message": f"mock tick {i+1}/{progress_ticks}",
                    },
                })

        if latency_s > 0:
            time.sleep(latency_s)

        # Echo the params back as the result. This is the mock's "work product".
        emit({
            "jsonrpc": "2.0",
            "id": msg_id,
            "result": {"echo": params, "call_index": method_calls_handled},
        })


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x tests/mock_agent.py
```

- [ ] **Step 3: Smoke-test manually**

```bash
cd ~/projects/chargesheets/pdf-extraction-experiments
echo '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}' | python3 tests/mock_agent.py
```

Expected output (one line):

```json
{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":"lambe-haath/1","agentInfo":{"name":"mock_agent","version":"0.1.0"},"capabilities":{"methods":["mock.echo"],"progress":true,"cancellation":true}}}
```

- [ ] **Step 4: Commit**

```bash
git add tests/mock_agent.py
git commit -m "test: add tests/mock_agent.py (polyglot protocol stub with MOCK_* env-var levers)"
```

---

## Task 11: Create `tests/conformance_harness.py`

**Target repo:** `~/projects/chargesheets/pdf-extraction-experiments/`

**Files:**
- Create: `tests/conformance_harness.py`

The harness is a small library that drives any agent binary through the `lambe-haath/1` lifecycle. Tests import it; future agent authors use it to validate their implementations.

- [ ] **Step 1: Create `tests/conformance_harness.py`**

```python
"""
Conformance harness for the lambe-haath/1 protocol.

Drives any agent binary through:
    1. initialize  -> initialize-result
    2. notifications/initialized
    3. one or more method calls -> responses (and notifications)
    4. shutdown -> shutdown-result
    5. notifications/exit
    6. agent exits cleanly

Used by:
    - tests/test_conformance.py  (validates mock_agent.py)
    - future plans: test the real ocr_agent and prompt_agent the same way

This module has no third-party deps. Implementers in any language can read it
to understand what a passing agent looks like in practice.
"""

from __future__ import annotations

import json
import subprocess
import threading
from queue import Queue, Empty
from typing import Any


class ProtocolError(RuntimeError):
    """Raised when an agent violates the lambe-haath/1 protocol."""


class Harness:
    """Driver around a single subprocess that speaks lambe-haath/1 over stdio.

    Usage:
        with Harness(["python3", "tests/mock_agent.py"]) as h:
            caps = h.initialize()
            result, notifs = h.call("mock.echo", {"hello": 1})
            h.shutdown()
    """

    def __init__(
        self,
        argv: list[str],
        env: dict[str, str] | None = None,
        read_timeout_s: float = 10.0,
    ):
        self._argv = argv
        self._env = env
        self._read_timeout_s = read_timeout_s
        self._proc: subprocess.Popen | None = None
        self._stdout_lines: Queue[str] = Queue()
        self._reader_thread: threading.Thread | None = None
        self._next_id = 1
        # Notifications queued up between calls; drained by .call().
        self._buffered_notifs: list[dict] = []

    # -- context manager --

    def __enter__(self) -> "Harness":
        self._proc = subprocess.Popen(
            self._argv,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,  # line-buffered
            env=self._env,
        )
        self._reader_thread = threading.Thread(target=self._read_stdout, daemon=True)
        self._reader_thread.start()
        return self

    def __exit__(self, *exc) -> None:
        if self._proc is None:
            return
        try:
            if self._proc.poll() is None:
                self._proc.kill()
        finally:
            self._proc.wait(timeout=5)

    # -- protocol --

    def initialize(self) -> dict:
        """Send initialize, return the capabilities dict from the response."""
        resp = self._request("initialize", {
            "protocolVersion": "lambe-haath/1",
            "hostInfo": {"name": "conformance_harness", "version": "0.1.0"},
            "capabilities": {"progress": True, "cancellation": True},
        })
        if "result" not in resp:
            raise ProtocolError(f"initialize did not return result: {resp}")
        result = resp["result"]
        if result.get("protocolVersion") != "lambe-haath/1":
            raise ProtocolError(f"agent protocolVersion mismatch: {result.get('protocolVersion')}")
        if "capabilities" not in result:
            raise ProtocolError("initialize result missing capabilities")
        # Send the initialized notification.
        self._send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        return result["capabilities"]

    def call(
        self,
        method: str,
        params: dict | None = None,
        progress_token: str | None = None,
    ) -> tuple[dict, list[dict]]:
        """Send a method call. Returns (response_message, [notifications received during the call])."""
        if params is None:
            params = {}
        if progress_token is not None:
            params = {**params, "_meta": {"progressToken": progress_token}}
        resp = self._request(method, params)
        notifs = self._buffered_notifs
        self._buffered_notifs = []
        return resp, notifs

    def notify(self, method: str, params: dict | None = None) -> None:
        """Send a notification to the agent (e.g., notifications/cancelled)."""
        msg = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            msg["params"] = params
        self._send(msg)

    def shutdown(self) -> None:
        """Send shutdown + exit notification + wait for the process to exit."""
        try:
            self._request("shutdown", {})
        except ProtocolError:
            pass  # agent may not implement shutdown; that's OK
        self._send({"jsonrpc": "2.0", "method": "notifications/exit"})
        # Close stdin so the agent's read loop hits EOF.
        try:
            self._proc.stdin.close()
        except Exception:
            pass

    # -- internals --

    def _next_request_id(self) -> int:
        rid = self._next_id
        self._next_id += 1
        return rid

    def _send(self, obj: dict) -> None:
        line = json.dumps(obj, separators=(",", ":")) + "\n"
        assert self._proc is not None and self._proc.stdin is not None
        self._proc.stdin.write(line)
        self._proc.stdin.flush()

    def _request(self, method: str, params: dict) -> dict:
        rid = self._next_request_id()
        self._send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        # Read until we get a response with this id; buffer any notifications.
        while True:
            msg = self._read_one()
            if "id" in msg and msg["id"] == rid:
                return msg
            elif "method" in msg and "id" not in msg:
                self._buffered_notifs.append(msg)
            else:
                # Unexpected; could be a stale response. Continue scanning.
                continue

    def _read_one(self) -> dict:
        try:
            line = self._stdout_lines.get(timeout=self._read_timeout_s)
        except Empty:
            raise ProtocolError(f"agent timed out (>{self._read_timeout_s}s) waiting for response")
        try:
            return json.loads(line)
        except json.JSONDecodeError as e:
            raise ProtocolError(f"agent emitted non-JSON line: {line!r} ({e})")

    def _read_stdout(self) -> None:
        assert self._proc is not None and self._proc.stdout is not None
        for raw in self._proc.stdout:
            line = raw.rstrip("\n")
            if not line:
                continue
            self._stdout_lines.put(line)
```

- [ ] **Step 2: Commit**

```bash
git add tests/conformance_harness.py
git commit -m "test: add tests/conformance_harness.py (drives any agent through lambe-haath/1)"
```

---

## Task 12: Mock-agent unit tests

**Target repo:** `~/projects/chargesheets/pdf-extraction-experiments/`

**Files:**
- Create: `tests/test_mock_agent.py`

- [ ] **Step 1: Create `tests/test_mock_agent.py`**

```python
"""Tests for tests/mock_agent.py — the polyglot protocol stub itself."""

from __future__ import annotations

import os
import sys
import pytest

from tests.conformance_harness import Harness, ProtocolError

MOCK_AGENT = [sys.executable, "tests/mock_agent.py"]


@pytest.mark.protocol
def test_initialize_returns_default_capabilities() -> None:
    with Harness(MOCK_AGENT) as h:
        caps = h.initialize()
        assert caps["methods"] == ["mock.echo"]
        assert caps["progress"] is True
        assert caps["cancellation"] is True
        h.shutdown()


@pytest.mark.protocol
def test_method_call_echoes_params() -> None:
    with Harness(MOCK_AGENT) as h:
        h.initialize()
        resp, notifs = h.call("mock.echo", {"hello": "world", "n": 42})
        assert resp["result"]["echo"] == {"hello": "world", "n": 42}
        assert resp["result"]["call_index"] == 1
        assert notifs == []
        h.shutdown()


@pytest.mark.protocol
def test_progress_notifications_emit_when_progress_token_passed() -> None:
    with Harness(MOCK_AGENT, env={**os.environ, "MOCK_PROGRESS_TICKS": "3"}) as h:
        h.initialize()
        resp, notifs = h.call("mock.echo", {"hi": 1}, progress_token="tok1")
        assert "result" in resp
        assert len(notifs) == 3
        for i, n in enumerate(notifs):
            assert n["method"] == "notifications/progress"
            assert n["params"]["progressToken"] == "tok1"
            assert n["params"]["progress"] == pytest.approx((i + 1) / 3)
        h.shutdown()


@pytest.mark.protocol
def test_capabilities_override_via_env() -> None:
    custom_caps = '{"methods":["ocr.extract","prompt.run"],"progress":true,"cancellation":false}'
    with Harness(MOCK_AGENT, env={**os.environ, "MOCK_CAPABILITIES": custom_caps}) as h:
        caps = h.initialize()
        assert caps["methods"] == ["ocr.extract", "prompt.run"]
        assert caps["cancellation"] is False
        h.shutdown()


@pytest.mark.protocol
def test_crash_on_first_call_via_fail_after() -> None:
    with Harness(MOCK_AGENT, env={**os.environ, "MOCK_FAIL_AFTER_N": "0"}) as h:
        h.initialize()
        with pytest.raises(ProtocolError):
            # The call will start; agent crashes; harness times out waiting for response.
            h.call("mock.echo", {"x": 1})


@pytest.mark.protocol
def test_crash_after_two_calls() -> None:
    with Harness(MOCK_AGENT, env={**os.environ, "MOCK_FAIL_AFTER_N": "2"}) as h:
        h.initialize()
        r1, _ = h.call("mock.echo", {"i": 1})
        assert "result" in r1
        r2, _ = h.call("mock.echo", {"i": 2})
        assert "result" in r2
        with pytest.raises(ProtocolError):
            h.call("mock.echo", {"i": 3})


@pytest.mark.protocol
def test_garbage_output_after_n_calls() -> None:
    with Harness(MOCK_AGENT, env={**os.environ, "MOCK_PARSE_GARBAGE_AFTER_N": "1"}) as h:
        h.initialize()
        # First call: clean response.
        r1, _ = h.call("mock.echo", {})
        assert "result" in r1
        # Second call: agent emits garbage; harness raises ProtocolError on JSON parse.
        with pytest.raises(ProtocolError):
            h.call("mock.echo", {})
```

- [ ] **Step 2: Run tests**

```bash
cd ~/projects/chargesheets/pdf-extraction-experiments
.venv/bin/pytest tests/test_mock_agent.py -v
```

Expected: 7 tests pass.

- [ ] **Step 3: Commit**

```bash
git add tests/test_mock_agent.py
git commit -m "test: pytest suite for mock_agent (initialize, progress, crash, garbage paths)"
```

---

## Task 13: End-to-end conformance test

**Target repo:** `~/projects/chargesheets/pdf-extraction-experiments/`

**Files:**
- Create: `tests/test_conformance.py`

This is the test that validates the conformance harness itself by running a full happy-path lifecycle through it against the mock agent. Future agents (real OCR, real prompt) will get parallel tests in their respective plans.

- [ ] **Step 1: Create `tests/test_conformance.py`**

```python
"""End-to-end conformance: harness + mock agent run through a full lifecycle.

Future plans will add parallel tests for the real ocr_agent and prompt_agent
binaries; they will all use the same Harness class.
"""

from __future__ import annotations

import sys
import pytest

from tests.conformance_harness import Harness

MOCK_AGENT = [sys.executable, "tests/mock_agent.py"]


@pytest.mark.protocol
def test_full_lifecycle_happy_path() -> None:
    """initialize -> initialized -> N method calls -> shutdown -> exit -> agent exits 0."""
    with Harness(MOCK_AGENT) as h:
        caps = h.initialize()
        assert "methods" in caps

        for i in range(1, 6):
            resp, notifs = h.call("mock.echo", {"iteration": i})
            assert resp["result"]["echo"]["iteration"] == i
            assert resp["result"]["call_index"] == i

        h.shutdown()
        # The harness closes stdin; mock_agent's `for raw_line in sys.stdin` loop hits EOF and exits.
        exit_code = h._proc.wait(timeout=5)
        assert exit_code == 0


@pytest.mark.protocol
def test_warm_path_reuses_one_process() -> None:
    """Five calls against the same agent process incur exactly one spawn."""
    with Harness(MOCK_AGENT) as h:
        h.initialize()
        for _ in range(5):
            resp, _ = h.call("mock.echo", {})
            assert "result" in resp
        # If we got here, the same process handled all 5. Spawn count is implicitly 1.
        h.shutdown()


@pytest.mark.protocol
def test_two_concurrent_harnesses_are_independent() -> None:
    """Two parallel mock_agent processes don't share state."""
    with Harness(MOCK_AGENT) as h1, Harness(MOCK_AGENT) as h2:
        h1.initialize()
        h2.initialize()
        r1, _ = h1.call("mock.echo", {"agent": 1})
        r2, _ = h2.call("mock.echo", {"agent": 2})
        # Each agent counts calls independently.
        assert r1["result"]["call_index"] == 1
        assert r2["result"]["call_index"] == 1
        h1.shutdown()
        h2.shutdown()
```

- [ ] **Step 2: Run the full Python suite**

```bash
cd ~/projects/chargesheets/pdf-extraction-experiments
.venv/bin/pytest -m protocol -v
```

Expected: 10 tests pass total (7 from `test_mock_agent.py` + 3 from `test_conformance.py`).

- [ ] **Step 3: Commit**

```bash
git add tests/test_conformance.py
git commit -m "test: end-to-end conformance lifecycle + multi-process independence"
```

---

## Task 14: Final verification — Zig + Python all green

**Target repos:** both

- [ ] **Step 1: Zig side green**

```bash
cd ~/projects/lambe-haath/logos
zig build test
```

Expected: all pre-existing tests pass plus the new tests added in Tasks 2-8 (33+ new tests across migrations, slices, extractions, prompt_outputs, job_logs, pricing, jsonrpc).

- [ ] **Step 2: Python side green**

```bash
cd ~/projects/chargesheets/pdf-extraction-experiments
.venv/bin/pytest -v
```

Expected: 10 protocol tests pass.

- [ ] **Step 3: Verify the spec's exit criteria for Plan A**

Check that we have shipped (and committed) all of:

- [ ] `~/projects/lambe-haath/logos/src/db/v2.sql`
- [ ] `~/projects/lambe-haath/logos/src/db/migrations.zig` with `applyV2`
- [ ] `slices.zig` with `kind` / `kind_key` + filename parser
- [ ] `extractions.zig`, `prompt_outputs.zig`, `job_logs.zig`
- [ ] `agents/pricing.zig`
- [ ] `agents/jsonrpc.zig` (encode + decode)
- [ ] `tests/mock_agent.py`
- [ ] `tests/conformance_harness.py`
- [ ] `tests/test_mock_agent.py`
- [ ] `tests/test_conformance.py`

All green. No TBDs. All new modules under test.

- [ ] **Step 4: Tag the milestone (optional)**

```bash
cd ~/projects/lambe-haath/logos
git tag -a plan-a-foundation -m "Plan A complete: schema v2 + jsonrpc codec + mock agent"

cd ~/projects/chargesheets/pdf-extraction-experiments
git tag -a plan-a-foundation -m "Plan A complete: mock_agent + conformance harness"
```

---

## What's next (Plan B preview, not in this plan)

Once Plan A is committed and `plan-a-foundation` is tagged, Plan B picks up:

- `src/agents/config.zig` — parse `agents.json` from data_dir (with the `model` field per the spec update)
- `src/agents/worker.zig` — worker state machine
- `src/agents/supervisor.zig` — pool manager
- `src/agents/dispatcher.zig` — dispatch loop
- `src/api/handlers_ocr.zig` / `handlers_prompts.zig` — HTTP enqueue endpoints
- Integration tests using `tests/mock_agent.py` from Plan A

Plan B's exit criterion: logos can accept an OCR-job HTTP request and run it end-to-end against the mock agent, with the result landing in `extractions` and `job_logs`. No real Gemini/Anthropic agent yet — that's Plans C and D.
