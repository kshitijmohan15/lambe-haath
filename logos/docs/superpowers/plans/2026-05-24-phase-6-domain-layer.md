# Phase 6: Domain Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provide typed Zig CRUD functions over `projects`, `slices`, and `jobs` on top of the existing zqlite-based SQLite layer, with a unified `DbError` set and full unit-test coverage using `:memory:` databases.

**Architecture:** Introduce a thin `Db` struct that owns a `zqlite.Conn` and exposes domain-specific modules (`projects`, `slices`, `jobs`). Each module defines its row struct (with owned strings + `deinit`) and CRUD functions that translate zqlite constraint errors into a stable `DbError` set. A shared `test_helpers` module gives every test a fresh in-memory DB with migrations applied. `main.zig` is rewritten to construct the `Db` wrapper instead of opening a raw `zqlite.Conn`.

**Tech Stack:** Zig 0.16+, `zqlite.zig` (already vendored as a dependency), SQLite in-memory mode for tests.

---

## File Structure

- **Create** `src/db/db.zig` — `Db` struct wrapping `zqlite.Conn`; `open`/`close`; PRAGMA setup; root for `test { _ = @import(...); }` test discovery.
- **Create** `src/db/errors.zig` — `DbError` error set + `mapConstraintErr` helper that translates `error.ConstraintUnique`/`ConstraintForeignKey`/`ConstraintCheck`/`ConstraintNotNull` into stable domain errors.
- **Create** `src/db/test_helpers.zig` — `openTestDb(gpa) !Db` that opens `:memory:`, sets foreign keys ON, runs migrations.
- **Create** `src/db/projects.zig` — `Project` struct + `insert`, `getById`, `listAll`, `delete`, `touchLastOpened`, `existsByName`.
- **Create** `src/db/slices.zig` — `Slice` struct + `insert`, `listByProject`, `getByKey`, `delete`.
- **Create** `src/db/jobs.zig` — `Job` struct + `insert`, `getById`, `listByProject`, `listByStatus`, `updateProgress`, `markCompleted`, `markFailed`, `claimNextQueued`.
- **Modify** `src/main.zig` — replace direct `zqlite.open` with `Db.open`; route migrations through the wrapper.
- **Modify** `src/db/migrations.zig` — no signature change; we keep calling `migrations.run(conn)` with the raw `zqlite.Conn` inside `Db`.

Conventions enforced throughout:
- All strings stored on a struct are **owned** by the struct. Every struct has a `deinit(self: *Self, gpa: Allocator) void` that frees its strings. Slices returned from `listAll`/`listByProject`/`listByStatus` have a `deinitList` companion.
- Timestamps are ISO-8601 UTC strings (e.g. `2026-05-24T12:34:56Z`) generated via a tiny `nowIso8601(gpa)` helper inside `db.zig`. Functions that need a fresh timestamp (`touchLastOpened`, `updateProgress`) call this helper.
- Every CRUD function takes `db: *Db` as its first arg. Read functions that return owned data also take `gpa: Allocator`; write functions that don't allocate don't.

---

### Task 1: Db wrapper + test helpers + DbError set

**Files:**
- Create: `src/db/db.zig`
- Create: `src/db/errors.zig`
- Create: `src/db/test_helpers.zig`
- Modify: `src/main.zig` (update import path; no behavior change yet)

- [ ] **Step 1: Create `src/db/errors.zig`**

```zig
const std = @import("std");

pub const DbError = error{
    NotFound,
    UniqueViolation,
    ForeignKeyViolation,
    CheckViolation,
    NotNullViolation,
};

/// Translate a zqlite constraint error into a DbError. Non-constraint errors
/// pass through unchanged.
pub fn mapConstraintErr(err: anyerror) anyerror {
    return switch (err) {
        error.ConstraintUnique => error.UniqueViolation,
        error.ConstraintForeignKey => error.ForeignKeyViolation,
        error.ConstraintCheck => error.CheckViolation,
        error.ConstraintNotNull => error.NotNullViolation,
        error.ConstraintPrimaryKey => error.UniqueViolation,
        else => err,
    };
}
```

- [ ] **Step 2: Create `src/db/db.zig`**

```zig
const std = @import("std");
const zqlite = @import("zqlite");
const migrations = @import("migrations.zig");

pub const Db = struct {
    conn: zqlite.Conn,

    pub fn open(path: [*:0]const u8) !Db {
        const conn = try zqlite.open(
            path,
            zqlite.OpenFlags.Create | zqlite.OpenFlags.ReadWrite | zqlite.OpenFlags.EXResCode,
        );
        errdefer conn.close();

        try conn.execNoArgs(
            \\PRAGMA journal_mode = WAL;
            \\PRAGMA foreign_keys = ON;
            \\PRAGMA synchronous = NORMAL;
            \\PRAGMA busy_timeout = 5000;
        );
        try migrations.run(conn);
        return .{ .conn = conn };
    }

    pub fn close(self: *Db) void {
        self.conn.close();
    }
};

/// Allocate and return an ISO-8601 UTC timestamp string of the current time.
/// Caller owns the returned slice.
pub fn nowIso8601(gpa: std.mem.Allocator) ![]u8 {
    const ts_secs = std.time.timestamp();
    const epoch_secs: std.time.epoch.EpochSeconds = .{ .secs = @intCast(ts_secs) };
    const epoch_day = epoch_secs.getEpochDay();
    const day_secs = epoch_secs.getDaySeconds();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.allocPrint(
        gpa,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        .{
            @as(u16, year_day.year),
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_secs.getHoursIntoDay(),
            day_secs.getMinutesIntoHour(),
            day_secs.getSecondsIntoMinute(),
        },
    );
}

test {
    _ = @import("test_helpers.zig");
    _ = @import("projects.zig");
    _ = @import("slices.zig");
    _ = @import("jobs.zig");
}

test "nowIso8601 returns a 20-char Z-suffixed string" {
    const gpa = std.testing.allocator;
    const ts = try nowIso8601(gpa);
    defer gpa.free(ts);
    try std.testing.expectEqual(@as(usize, 20), ts.len);
    try std.testing.expectEqual(@as(u8, 'Z'), ts[19]);
    try std.testing.expectEqual(@as(u8, 'T'), ts[10]);
}
```

- [ ] **Step 3: Create `src/db/test_helpers.zig`**

```zig
const std = @import("std");
const Db = @import("db.zig").Db;

/// Open a fresh in-memory database with foreign keys enabled and the
/// latest schema applied. Caller is responsible for `db.close()`.
pub fn openTestDb() !Db {
    return Db.open(":memory:");
}

test "openTestDb yields a database with foreign_keys ON" {
    var db = try openTestDb();
    defer db.close();

    const row = try db.conn.row("PRAGMA foreign_keys", .{});
    try std.testing.expect(row != null);
    defer row.?.deinit();
    try std.testing.expectEqual(@as(i64, 1), row.?.int(0));
}

test "openTestDb applies schema v1" {
    var db = try openTestDb();
    defer db.close();

    const row = try db.conn.row("SELECT MAX(version) FROM schema_version", .{});
    try std.testing.expect(row != null);
    defer row.?.deinit();
    try std.testing.expectEqual(@as(i64, 1), row.?.int(0));
}
```

- [ ] **Step 4: Hook db tests into the build**

Edit `src/main.zig` to add a `test` block at the bottom (after `extern "c" fn getpid()`) so the exe test runner pulls in db tests:

```zig
test {
    _ = @import("db/db.zig");
    _ = @import("db/errors.zig");
}
```

- [ ] **Step 5: Run tests to verify the harness works**

Run: `zig build test`
Expected: PASS — 3 tests (`nowIso8601 returns…`, `openTestDb yields…`, `openTestDb applies schema v1`), zero leaks.

- [ ] **Step 6: Commit**

```bash
git add src/db/db.zig src/db/errors.zig src/db/test_helpers.zig src/main.zig
git commit -m "feat(db): add Db wrapper, DbError set, and in-memory test helper"
```

---

### Task 2: Projects — struct, insert, getById

**Files:**
- Create: `src/db/projects.zig`

- [ ] **Step 1: Write the failing test for `insert` + `getById` (happy path)**

Create `src/db/projects.zig` with this skeleton + tests at the bottom:

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const Db = @import("db.zig").Db;
const errors = @import("errors.zig");
const test_helpers = @import("test_helpers.zig");

pub const Project = struct {
    id: []const u8,
    name: []const u8,
    description: ?[]const u8,
    created_at: []const u8,
    last_opened_at: []const u8,
    chargesheet_filename: []const u8,
    chargesheet_page_count: u32,
    chargesheet_size_bytes: u64,

    pub fn deinit(self: *Project, gpa: Allocator) void {
        gpa.free(self.id);
        gpa.free(self.name);
        if (self.description) |d| gpa.free(d);
        gpa.free(self.created_at);
        gpa.free(self.last_opened_at);
        gpa.free(self.chargesheet_filename);
    }
};

pub fn deinitList(list: []Project, gpa: Allocator) void {
    for (list) |*p| p.deinit(gpa);
    gpa.free(list);
}

// implementations go here

test "insert + getById round-trips a project" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();

    const fixture: Project = .{
        .id = "p1",
        .name = "Case 42",
        .description = "Mock case",
        .created_at = "2026-05-24T10:00:00Z",
        .last_opened_at = "2026-05-24T10:00:00Z",
        .chargesheet_filename = "case42.pdf",
        .chargesheet_page_count = 12,
        .chargesheet_size_bytes = 4096,
    };

    try insert(&db, gpa, fixture);

    var got = (try getById(&db, gpa, "p1")) orelse return error.TestUnexpectedNull;
    defer got.deinit(gpa);

    try std.testing.expectEqualStrings("p1", got.id);
    try std.testing.expectEqualStrings("Case 42", got.name);
    try std.testing.expectEqualStrings("Mock case", got.description.?);
    try std.testing.expectEqualStrings("case42.pdf", got.chargesheet_filename);
    try std.testing.expectEqual(@as(u32, 12), got.chargesheet_page_count);
    try std.testing.expectEqual(@as(u64, 4096), got.chargesheet_size_bytes);
}
```

- [ ] **Step 2: Hook projects tests into the build**

Edit `src/main.zig`'s test block:

```zig
test {
    _ = @import("db/db.zig");
    _ = @import("db/errors.zig");
    _ = @import("db/projects.zig");
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL — compile error, `insert` and `getById` not defined.

- [ ] **Step 4: Implement `insert`**

Add to `src/db/projects.zig` above the test:

```zig
pub fn insert(db: *Db, gpa: Allocator, project: Project) !void {
    _ = gpa;
    db.conn.exec(
        \\INSERT INTO projects
        \\  (id, name, description, created_at, last_opened_at,
        \\   chargesheet_filename, chargesheet_page_count, chargesheet_size_bytes)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ,
        .{
            project.id,
            project.name,
            project.description,
            project.created_at,
            project.last_opened_at,
            project.chargesheet_filename,
            @as(i64, @intCast(project.chargesheet_page_count)),
            @as(i64, @intCast(project.chargesheet_size_bytes)),
        },
    ) catch |err| return errors.mapConstraintErr(err);
}
```

- [ ] **Step 5: Implement `getById`**

Append above the test:

```zig
pub fn getById(db: *Db, gpa: Allocator, id: []const u8) !?Project {
    const row = (try db.conn.row(
        \\SELECT id, name, description, created_at, last_opened_at,
        \\       chargesheet_filename, chargesheet_page_count, chargesheet_size_bytes
        \\FROM projects WHERE id = ?
    ,
        .{id},
    )) orelse return null;
    defer row.deinit();

    const description: ?[]const u8 = if (row.nullableText(2)) |s| try gpa.dupe(u8, s) else null;
    errdefer if (description) |d| gpa.free(d);

    const id_owned = try gpa.dupe(u8, row.text(0));
    errdefer gpa.free(id_owned);
    const name_owned = try gpa.dupe(u8, row.text(1));
    errdefer gpa.free(name_owned);
    const created_owned = try gpa.dupe(u8, row.text(3));
    errdefer gpa.free(created_owned);
    const opened_owned = try gpa.dupe(u8, row.text(4));
    errdefer gpa.free(opened_owned);
    const filename_owned = try gpa.dupe(u8, row.text(5));
    errdefer gpa.free(filename_owned);

    return .{
        .id = id_owned,
        .name = name_owned,
        .description = description,
        .created_at = created_owned,
        .last_opened_at = opened_owned,
        .chargesheet_filename = filename_owned,
        .chargesheet_page_count = @intCast(row.int(6)),
        .chargesheet_size_bytes = @intCast(row.int(7)),
    };
}
```

- [ ] **Step 6: Run test to verify happy path passes**

Run: `zig build test`
Expected: PASS — all previous tests + new "insert + getById round-trips a project". No leaks.

- [ ] **Step 7: Add a failing test for `getById` returning null on missing row**

Append to the test block:

```zig
test "getById returns null when project does not exist" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();

    const got = try getById(&db, gpa, "nope");
    try std.testing.expect(got == null);
}
```

Run: `zig build test`
Expected: PASS (implementation already handles this).

- [ ] **Step 8: Add a failing test for unique-name violation**

Append:

```zig
test "insert with duplicate name returns UniqueViolation" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();

    const a: Project = .{
        .id = "a", .name = "Same", .description = null,
        .created_at = "2026-05-24T10:00:00Z", .last_opened_at = "2026-05-24T10:00:00Z",
        .chargesheet_filename = "a.pdf", .chargesheet_page_count = 1, .chargesheet_size_bytes = 1,
    };
    const b: Project = .{
        .id = "b", .name = "Same", .description = null,
        .created_at = "2026-05-24T10:00:01Z", .last_opened_at = "2026-05-24T10:00:01Z",
        .chargesheet_filename = "b.pdf", .chargesheet_page_count = 1, .chargesheet_size_bytes = 1,
    };
    try insert(&db, gpa, a);
    try std.testing.expectError(error.UniqueViolation, insert(&db, gpa, b));
}
```

- [ ] **Step 9: Run tests to verify**

Run: `zig build test`
Expected: PASS — 3 new project tests pass; constraint error mapped correctly.

- [ ] **Step 10: Add a failing test for `chargesheet_page_count` CHECK constraint**

```zig
test "insert with zero page count returns CheckViolation" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();

    const bad: Project = .{
        .id = "x", .name = "Bad", .description = null,
        .created_at = "2026-05-24T10:00:00Z", .last_opened_at = "2026-05-24T10:00:00Z",
        .chargesheet_filename = "x.pdf", .chargesheet_page_count = 0, .chargesheet_size_bytes = 1,
    };
    try std.testing.expectError(error.CheckViolation, insert(&db, gpa, bad));
}
```

Run: `zig build test`
Expected: PASS.

- [ ] **Step 11: Commit**

```bash
git add src/db/projects.zig src/main.zig
git commit -m "feat(db): add Project struct with insert and getById"
```

---

### Task 3: Projects — listAll, delete, touchLastOpened, existsByName

**Files:**
- Modify: `src/db/projects.zig`

- [ ] **Step 1: Write failing test for `listAll` ordering**

Append to test block in `src/db/projects.zig`:

```zig
test "listAll returns projects ordered by last_opened_at DESC" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();

    try insert(&db, gpa, .{
        .id = "p1", .name = "First", .description = null,
        .created_at = "2026-05-24T10:00:00Z", .last_opened_at = "2026-05-24T10:00:00Z",
        .chargesheet_filename = "1.pdf", .chargesheet_page_count = 1, .chargesheet_size_bytes = 1,
    });
    try insert(&db, gpa, .{
        .id = "p2", .name = "Second", .description = null,
        .created_at = "2026-05-24T11:00:00Z", .last_opened_at = "2026-05-24T11:00:00Z",
        .chargesheet_filename = "2.pdf", .chargesheet_page_count = 1, .chargesheet_size_bytes = 1,
    });

    var list = try listAll(&db, gpa);
    defer deinitList(list, gpa);

    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("p2", list[0].id);
    try std.testing.expectEqualStrings("p1", list[1].id);
}
```

Run: `zig build test`
Expected: FAIL — `listAll` not defined.

- [ ] **Step 2: Implement `listAll`**

Append above tests:

```zig
pub fn listAll(db: *Db, gpa: Allocator) ![]Project {
    var list = std.ArrayList(Project){};
    errdefer {
        for (list.items) |*p| p.deinit(gpa);
        list.deinit(gpa);
    }

    var rows = try db.conn.rows(
        \\SELECT id, name, description, created_at, last_opened_at,
        \\       chargesheet_filename, chargesheet_page_count, chargesheet_size_bytes
        \\FROM projects ORDER BY last_opened_at DESC
    , .{});
    defer rows.deinit();

    while (rows.next()) |row| {
        const description: ?[]const u8 = if (row.nullableText(2)) |s| try gpa.dupe(u8, s) else null;
        errdefer if (description) |d| gpa.free(d);

        const project: Project = .{
            .id = try gpa.dupe(u8, row.text(0)),
            .name = try gpa.dupe(u8, row.text(1)),
            .description = description,
            .created_at = try gpa.dupe(u8, row.text(3)),
            .last_opened_at = try gpa.dupe(u8, row.text(4)),
            .chargesheet_filename = try gpa.dupe(u8, row.text(5)),
            .chargesheet_page_count = @intCast(row.int(6)),
            .chargesheet_size_bytes = @intCast(row.int(7)),
        };
        try list.append(gpa, project);
    }
    try rows.errorIfAny();

    return list.toOwnedSlice(gpa);
}
```

Note: Verify `rows.next()`, `rows.errorIfAny`, and `Rows` API surface against `zig-pkg/zqlite-.../src/conn.zig` before relying on them; adjust to match the vendored zqlite version if signatures differ (e.g. some versions use `while (try rows.next()) |row|`).

- [ ] **Step 3: Run and confirm**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 4: Write failing test for `delete`**

```zig
test "delete removes a project" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();

    try insert(&db, gpa, .{
        .id = "p1", .name = "X", .description = null,
        .created_at = "t", .last_opened_at = "t",
        .chargesheet_filename = "f", .chargesheet_page_count = 1, .chargesheet_size_bytes = 1,
    });
    try delete(&db, "p1");
    const got = try getById(&db, gpa, "p1");
    try std.testing.expect(got == null);
}

test "delete on missing id returns NotFound" {
    var db = try test_helpers.openTestDb();
    defer db.close();
    try std.testing.expectError(error.NotFound, delete(&db, "ghost"));
}
```

Run: `zig build test`
Expected: FAIL — `delete` not defined.

- [ ] **Step 5: Implement `delete`**

```zig
pub fn delete(db: *Db, id: []const u8) !void {
    try db.conn.exec("DELETE FROM projects WHERE id = ?", .{id});
    if (db.conn.changes() == 0) return error.NotFound;
}
```

Run: `zig build test`
Expected: PASS.

- [ ] **Step 6: Write failing test for `touchLastOpened`**

```zig
test "touchLastOpened updates the timestamp" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();

    try insert(&db, gpa, .{
        .id = "p1", .name = "X", .description = null,
        .created_at = "2026-05-24T10:00:00Z",
        .last_opened_at = "2026-05-24T10:00:00Z",
        .chargesheet_filename = "f", .chargesheet_page_count = 1, .chargesheet_size_bytes = 1,
    });

    try touchLastOpened(&db, "p1");

    var got = (try getById(&db, gpa, "p1")) orelse return error.TestUnexpectedNull;
    defer got.deinit(gpa);
    try std.testing.expect(!std.mem.eql(u8, got.last_opened_at, "2026-05-24T10:00:00Z"));
    try std.testing.expectEqual(@as(usize, 20), got.last_opened_at.len);
    try std.testing.expectEqual(@as(u8, 'Z'), got.last_opened_at[19]);
}

test "touchLastOpened on missing id returns NotFound" {
    var db = try test_helpers.openTestDb();
    defer db.close();
    try std.testing.expectError(error.NotFound, touchLastOpened(&db, "ghost"));
}
```

Run: `zig build test`
Expected: FAIL.

- [ ] **Step 7: Implement `touchLastOpened`**

```zig
pub fn touchLastOpened(db: *Db, id: []const u8) !void {
    const db_mod = @import("db.zig");
    // Use a scratch allocator for the timestamp; SQLite copies bound text.
    var buf: [32]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const ts = try db_mod.nowIso8601(fba.allocator());
    try db.conn.exec("UPDATE projects SET last_opened_at = ? WHERE id = ?", .{ ts, id });
    if (db.conn.changes() == 0) return error.NotFound;
}
```

Run: `zig build test`
Expected: PASS.

- [ ] **Step 8: Write failing test for `existsByName`**

```zig
test "existsByName returns true/false correctly" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();

    try std.testing.expect(!try existsByName(&db, "Anything"));

    try insert(&db, gpa, .{
        .id = "p1", .name = "Anything", .description = null,
        .created_at = "t", .last_opened_at = "t",
        .chargesheet_filename = "f", .chargesheet_page_count = 1, .chargesheet_size_bytes = 1,
    });

    try std.testing.expect(try existsByName(&db, "Anything"));
    try std.testing.expect(!try existsByName(&db, "anything")); // case-sensitive
}
```

Run: `zig build test`
Expected: FAIL.

- [ ] **Step 9: Implement `existsByName`**

```zig
pub fn existsByName(db: *Db, name: []const u8) !bool {
    const row = (try db.conn.row(
        "SELECT 1 FROM projects WHERE name = ? LIMIT 1",
        .{name},
    )) orelse return false;
    defer row.deinit();
    return true;
}
```

Run: `zig build test`
Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add src/db/projects.zig
git commit -m "feat(db): add listAll/delete/touchLastOpened/existsByName for projects"
```

---

### Task 4: Slices — struct + CRUD

**Files:**
- Create: `src/db/slices.zig`
- Modify: `src/main.zig` (add `_ = @import("db/slices.zig");` inside the existing test block)

- [ ] **Step 1: Create `src/db/slices.zig` skeleton + first failing test**

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const Db = @import("db.zig").Db;
const errors = @import("errors.zig");
const test_helpers = @import("test_helpers.zig");
const projects = @import("projects.zig");

pub const Slice = struct {
    project_id: []const u8,
    filename: []const u8,
    start_page: u32,
    end_page: u32,
    size_bytes: u64,
    created_at: []const u8,

    pub fn deinit(self: *Slice, gpa: Allocator) void {
        gpa.free(self.project_id);
        gpa.free(self.filename);
        gpa.free(self.created_at);
    }
};

pub fn deinitList(list: []Slice, gpa: Allocator) void {
    for (list) |*s| s.deinit(gpa);
    gpa.free(list);
}

// implementations go here

fn seedProject(db: *Db, gpa: Allocator, id: []const u8) !void {
    try projects.insert(db, gpa, .{
        .id = id, .name = id, .description = null,
        .created_at = "2026-05-24T10:00:00Z", .last_opened_at = "2026-05-24T10:00:00Z",
        .chargesheet_filename = "src.pdf", .chargesheet_page_count = 100, .chargesheet_size_bytes = 1024,
    });
}

test "insert + getByKey round-trips a slice" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();
    try seedProject(&db, gpa, "p1");

    try insert(&db, gpa, .{
        .project_id = "p1", .filename = "pages-1-3.pdf",
        .start_page = 1, .end_page = 3, .size_bytes = 2048,
        .created_at = "2026-05-24T11:00:00Z",
    });

    var got = (try getByKey(&db, gpa, "p1", "pages-1-3.pdf")) orelse return error.TestUnexpectedNull;
    defer got.deinit(gpa);

    try std.testing.expectEqualStrings("p1", got.project_id);
    try std.testing.expectEqualStrings("pages-1-3.pdf", got.filename);
    try std.testing.expectEqual(@as(u32, 1), got.start_page);
    try std.testing.expectEqual(@as(u32, 3), got.end_page);
    try std.testing.expectEqual(@as(u64, 2048), got.size_bytes);
}
```

- [ ] **Step 2: Hook into main test block**

Edit `src/main.zig`'s test block:

```zig
test {
    _ = @import("db/db.zig");
    _ = @import("db/errors.zig");
    _ = @import("db/projects.zig");
    _ = @import("db/slices.zig");
}
```

Run: `zig build test`
Expected: FAIL — `insert`/`getByKey` not defined.

- [ ] **Step 3: Implement `insert` and `getByKey`**

```zig
pub fn insert(db: *Db, gpa: Allocator, slice: Slice) !void {
    _ = gpa;
    db.conn.exec(
        \\INSERT INTO slices
        \\  (project_id, filename, start_page, end_page, size_bytes, created_at)
        \\VALUES (?, ?, ?, ?, ?, ?)
    , .{
        slice.project_id, slice.filename,
        @as(i64, @intCast(slice.start_page)), @as(i64, @intCast(slice.end_page)),
        @as(i64, @intCast(slice.size_bytes)), slice.created_at,
    }) catch |err| return errors.mapConstraintErr(err);
}

pub fn getByKey(db: *Db, gpa: Allocator, project_id: []const u8, filename: []const u8) !?Slice {
    const row = (try db.conn.row(
        \\SELECT project_id, filename, start_page, end_page, size_bytes, created_at
        \\FROM slices WHERE project_id = ? AND filename = ?
    , .{ project_id, filename })) orelse return null;
    defer row.deinit();

    const pid = try gpa.dupe(u8, row.text(0));
    errdefer gpa.free(pid);
    const fname = try gpa.dupe(u8, row.text(1));
    errdefer gpa.free(fname);
    const created = try gpa.dupe(u8, row.text(5));

    return .{
        .project_id = pid,
        .filename = fname,
        .start_page = @intCast(row.int(2)),
        .end_page = @intCast(row.int(3)),
        .size_bytes = @intCast(row.int(4)),
        .created_at = created,
    };
}
```

Run: `zig build test`
Expected: PASS.

- [ ] **Step 4: Write failing test for foreign key + composite primary key**

```zig
test "insert with unknown project_id returns ForeignKeyViolation" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();

    try std.testing.expectError(error.ForeignKeyViolation, insert(&db, gpa, .{
        .project_id = "ghost", .filename = "x.pdf",
        .start_page = 1, .end_page = 2, .size_bytes = 1,
        .created_at = "t",
    }));
}

test "insert with duplicate (project_id, filename) returns UniqueViolation" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();
    try seedProject(&db, gpa, "p1");

    try insert(&db, gpa, .{
        .project_id = "p1", .filename = "a.pdf",
        .start_page = 1, .end_page = 2, .size_bytes = 1, .created_at = "t",
    });
    try std.testing.expectError(error.UniqueViolation, insert(&db, gpa, .{
        .project_id = "p1", .filename = "a.pdf",
        .start_page = 3, .end_page = 4, .size_bytes = 1, .created_at = "t",
    }));
}

test "insert with end_page < start_page returns CheckViolation" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();
    try seedProject(&db, gpa, "p1");

    try std.testing.expectError(error.CheckViolation, insert(&db, gpa, .{
        .project_id = "p1", .filename = "bad.pdf",
        .start_page = 5, .end_page = 3, .size_bytes = 1, .created_at = "t",
    }));
}
```

Run: `zig build test`
Expected: PASS (mapping already done in Task 1).

- [ ] **Step 5: Write failing test for `listByProject`**

```zig
test "listByProject returns slices for a project in created_at order" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();
    try seedProject(&db, gpa, "p1");
    try seedProject(&db, gpa, "p2");

    try insert(&db, gpa, .{
        .project_id = "p1", .filename = "a.pdf",
        .start_page = 1, .end_page = 2, .size_bytes = 1, .created_at = "2026-05-24T10:00:00Z",
    });
    try insert(&db, gpa, .{
        .project_id = "p1", .filename = "b.pdf",
        .start_page = 3, .end_page = 4, .size_bytes = 1, .created_at = "2026-05-24T11:00:00Z",
    });
    try insert(&db, gpa, .{
        .project_id = "p2", .filename = "c.pdf",
        .start_page = 1, .end_page = 1, .size_bytes = 1, .created_at = "2026-05-24T12:00:00Z",
    });

    var list = try listByProject(&db, gpa, "p1");
    defer deinitList(list, gpa);

    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("a.pdf", list[0].filename);
    try std.testing.expectEqualStrings("b.pdf", list[1].filename);
}
```

Run: `zig build test`
Expected: FAIL — `listByProject` undefined.

- [ ] **Step 6: Implement `listByProject`**

```zig
pub fn listByProject(db: *Db, gpa: Allocator, project_id: []const u8) ![]Slice {
    var list = std.ArrayList(Slice){};
    errdefer {
        for (list.items) |*s| s.deinit(gpa);
        list.deinit(gpa);
    }

    var rows = try db.conn.rows(
        \\SELECT project_id, filename, start_page, end_page, size_bytes, created_at
        \\FROM slices WHERE project_id = ? ORDER BY created_at ASC
    , .{project_id});
    defer rows.deinit();

    while (rows.next()) |row| {
        const slice: Slice = .{
            .project_id = try gpa.dupe(u8, row.text(0)),
            .filename = try gpa.dupe(u8, row.text(1)),
            .start_page = @intCast(row.int(2)),
            .end_page = @intCast(row.int(3)),
            .size_bytes = @intCast(row.int(4)),
            .created_at = try gpa.dupe(u8, row.text(5)),
        };
        try list.append(gpa, slice);
    }
    try rows.errorIfAny();

    return list.toOwnedSlice(gpa);
}
```

Run: `zig build test`
Expected: PASS.

- [ ] **Step 7: Write failing test for `delete` and cascade-on-project-delete**

```zig
test "delete removes a single slice" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();
    try seedProject(&db, gpa, "p1");

    try insert(&db, gpa, .{
        .project_id = "p1", .filename = "a.pdf",
        .start_page = 1, .end_page = 2, .size_bytes = 1, .created_at = "t",
    });
    try delete(&db, "p1", "a.pdf");
    try std.testing.expect(try getByKey(&db, gpa, "p1", "a.pdf") == null);
}

test "delete on missing slice returns NotFound" {
    var db = try test_helpers.openTestDb();
    defer db.close();
    try std.testing.expectError(error.NotFound, delete(&db, "p1", "ghost.pdf"));
}

test "deleting a project cascades to its slices" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();
    try seedProject(&db, gpa, "p1");
    try insert(&db, gpa, .{
        .project_id = "p1", .filename = "a.pdf",
        .start_page = 1, .end_page = 2, .size_bytes = 1, .created_at = "t",
    });

    try projects.delete(&db, "p1");
    var list = try listByProject(&db, gpa, "p1");
    defer deinitList(list, gpa);
    try std.testing.expectEqual(@as(usize, 0), list.len);
}
```

Run: `zig build test`
Expected: FAIL — `delete` undefined.

- [ ] **Step 8: Implement `delete`**

```zig
pub fn delete(db: *Db, project_id: []const u8, filename: []const u8) !void {
    try db.conn.exec("DELETE FROM slices WHERE project_id = ? AND filename = ?", .{ project_id, filename });
    if (db.conn.changes() == 0) return error.NotFound;
}
```

Run: `zig build test`
Expected: PASS — all slice tests green, cascade test green.

- [ ] **Step 9: Commit**

```bash
git add src/db/slices.zig src/main.zig
git commit -m "feat(db): add Slice struct with full CRUD and cascade behavior"
```

---

### Task 5: Jobs — struct + basic CRUD (insert, getById, listByProject, listByStatus, updates)

**Files:**
- Create: `src/db/jobs.zig`
- Modify: `src/main.zig` (add `_ = @import("db/jobs.zig");`)

- [ ] **Step 1: Create skeleton + first failing test**

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const Db = @import("db.zig").Db;
const db_mod = @import("db.zig");
const errors = @import("errors.zig");
const test_helpers = @import("test_helpers.zig");
const projects = @import("projects.zig");

pub const JobType = enum {
    slice,

    pub fn toText(self: JobType) []const u8 {
        return switch (self) { .slice => "slice" };
    }
    pub fn fromText(s: []const u8) !JobType {
        if (std.mem.eql(u8, s, "slice")) return .slice;
        return error.InvalidJobType;
    }
};

pub const JobStatus = enum {
    queued, running, completed, failed,

    pub fn toText(self: JobStatus) []const u8 {
        return switch (self) {
            .queued => "queued",
            .running => "running",
            .completed => "completed",
            .failed => "failed",
        };
    }
    pub fn fromText(s: []const u8) !JobStatus {
        if (std.mem.eql(u8, s, "queued")) return .queued;
        if (std.mem.eql(u8, s, "running")) return .running;
        if (std.mem.eql(u8, s, "completed")) return .completed;
        if (std.mem.eql(u8, s, "failed")) return .failed;
        return error.InvalidJobStatus;
    }
};

pub const Job = struct {
    id: []const u8,
    project_id: []const u8,
    type: JobType,
    status: JobStatus,
    progress: f64,
    payload: []const u8,
    results: ?[]const u8,
    error_msg: ?[]const u8,
    created_at: []const u8,
    updated_at: []const u8,

    pub fn deinit(self: *Job, gpa: Allocator) void {
        gpa.free(self.id);
        gpa.free(self.project_id);
        gpa.free(self.payload);
        if (self.results) |r| gpa.free(r);
        if (self.error_msg) |e| gpa.free(e);
        gpa.free(self.created_at);
        gpa.free(self.updated_at);
    }
};

pub fn deinitList(list: []Job, gpa: Allocator) void {
    for (list) |*j| j.deinit(gpa);
    gpa.free(list);
}

// implementations go here

fn seedProject(db: *Db, gpa: Allocator, id: []const u8) !void {
    try projects.insert(db, gpa, .{
        .id = id, .name = id, .description = null,
        .created_at = "2026-05-24T10:00:00Z", .last_opened_at = "2026-05-24T10:00:00Z",
        .chargesheet_filename = "src.pdf", .chargesheet_page_count = 100, .chargesheet_size_bytes = 1024,
    });
}

test "insert + getById round-trips a job" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();
    try seedProject(&db, gpa, "p1");

    try insert(&db, gpa, .{
        .id = "j1", .project_id = "p1", .type = .slice, .status = .queued,
        .progress = 0.0, .payload = "{\"start\":1,\"end\":3}",
        .results = null, .error_msg = null,
        .created_at = "2026-05-24T10:00:00Z", .updated_at = "2026-05-24T10:00:00Z",
    });

    var got = (try getById(&db, gpa, "j1")) orelse return error.TestUnexpectedNull;
    defer got.deinit(gpa);

    try std.testing.expectEqualStrings("j1", got.id);
    try std.testing.expectEqual(JobType.slice, got.type);
    try std.testing.expectEqual(JobStatus.queued, got.status);
    try std.testing.expectEqualStrings("{\"start\":1,\"end\":3}", got.payload);
    try std.testing.expect(got.results == null);
    try std.testing.expect(got.error_msg == null);
}
```

- [ ] **Step 2: Hook into main test block**

Edit `src/main.zig`:

```zig
test {
    _ = @import("db/db.zig");
    _ = @import("db/errors.zig");
    _ = @import("db/projects.zig");
    _ = @import("db/slices.zig");
    _ = @import("db/jobs.zig");
}
```

Run: `zig build test`
Expected: FAIL — `insert`/`getById` undefined.

- [ ] **Step 3: Implement `insert` and `getById`**

```zig
pub fn insert(db: *Db, gpa: Allocator, job: Job) !void {
    _ = gpa;
    db.conn.exec(
        \\INSERT INTO jobs
        \\  (id, project_id, type, status, progress, payload, results, error,
        \\   created_at, updated_at)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    , .{
        job.id, job.project_id, job.type.toText(), job.status.toText(),
        job.progress, job.payload, job.results, job.error_msg,
        job.created_at, job.updated_at,
    }) catch |err| return errors.mapConstraintErr(err);
}

fn rowToJob(row: anytype, gpa: Allocator) !Job {
    const results: ?[]const u8 = if (row.nullableText(6)) |s| try gpa.dupe(u8, s) else null;
    errdefer if (results) |r| gpa.free(r);
    const error_msg: ?[]const u8 = if (row.nullableText(7)) |s| try gpa.dupe(u8, s) else null;
    errdefer if (error_msg) |e| gpa.free(e);

    const id = try gpa.dupe(u8, row.text(0));
    errdefer gpa.free(id);
    const project_id = try gpa.dupe(u8, row.text(1));
    errdefer gpa.free(project_id);
    const payload = try gpa.dupe(u8, row.text(5));
    errdefer gpa.free(payload);
    const created_at = try gpa.dupe(u8, row.text(8));
    errdefer gpa.free(created_at);
    const updated_at = try gpa.dupe(u8, row.text(9));

    return .{
        .id = id,
        .project_id = project_id,
        .type = try JobType.fromText(row.text(2)),
        .status = try JobStatus.fromText(row.text(3)),
        .progress = row.float(4),
        .payload = payload,
        .results = results,
        .error_msg = error_msg,
        .created_at = created_at,
        .updated_at = updated_at,
    };
}

pub fn getById(db: *Db, gpa: Allocator, id: []const u8) !?Job {
    const row = (try db.conn.row(
        \\SELECT id, project_id, type, status, progress, payload, results, error,
        \\       created_at, updated_at
        \\FROM jobs WHERE id = ?
    , .{id})) orelse return null;
    defer row.deinit();
    return try rowToJob(row, gpa);
}
```

Run: `zig build test`
Expected: PASS.

- [ ] **Step 4: Write failing test for `listByProject` and `listByStatus`**

```zig
test "listByProject and listByStatus filter correctly" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();
    try seedProject(&db, gpa, "p1");
    try seedProject(&db, gpa, "p2");

    try insert(&db, gpa, .{
        .id = "j1", .project_id = "p1", .type = .slice, .status = .queued,
        .progress = 0.0, .payload = "{}", .results = null, .error_msg = null,
        .created_at = "2026-05-24T10:00:00Z", .updated_at = "2026-05-24T10:00:00Z",
    });
    try insert(&db, gpa, .{
        .id = "j2", .project_id = "p1", .type = .slice, .status = .completed,
        .progress = 1.0, .payload = "{}", .results = "ok", .error_msg = null,
        .created_at = "2026-05-24T10:00:01Z", .updated_at = "2026-05-24T10:00:01Z",
    });
    try insert(&db, gpa, .{
        .id = "j3", .project_id = "p2", .type = .slice, .status = .queued,
        .progress = 0.0, .payload = "{}", .results = null, .error_msg = null,
        .created_at = "2026-05-24T10:00:02Z", .updated_at = "2026-05-24T10:00:02Z",
    });

    var by_proj = try listByProject(&db, gpa, "p1");
    defer deinitList(by_proj, gpa);
    try std.testing.expectEqual(@as(usize, 2), by_proj.len);

    var by_status = try listByStatus(&db, gpa, .queued);
    defer deinitList(by_status, gpa);
    try std.testing.expectEqual(@as(usize, 2), by_status.len);
}
```

Run: `zig build test`
Expected: FAIL.

- [ ] **Step 5: Implement `listByProject` and `listByStatus`**

```zig
fn collectRows(db: *Db, gpa: Allocator, sql: []const u8, args: anytype) ![]Job {
    var list = std.ArrayList(Job){};
    errdefer {
        for (list.items) |*j| j.deinit(gpa);
        list.deinit(gpa);
    }
    var rows = try db.conn.rows(sql, args);
    defer rows.deinit();
    while (rows.next()) |row| {
        var job = try rowToJob(row, gpa);
        errdefer job.deinit(gpa);
        try list.append(gpa, job);
    }
    try rows.errorIfAny();
    return list.toOwnedSlice(gpa);
}

pub fn listByProject(db: *Db, gpa: Allocator, project_id: []const u8) ![]Job {
    return collectRows(db, gpa,
        \\SELECT id, project_id, type, status, progress, payload, results, error,
        \\       created_at, updated_at
        \\FROM jobs WHERE project_id = ? ORDER BY created_at ASC
    , .{project_id});
}

pub fn listByStatus(db: *Db, gpa: Allocator, status: JobStatus) ![]Job {
    return collectRows(db, gpa,
        \\SELECT id, project_id, type, status, progress, payload, results, error,
        \\       created_at, updated_at
        \\FROM jobs WHERE status = ? ORDER BY created_at ASC
    , .{status.toText()});
}
```

Run: `zig build test`
Expected: PASS.

- [ ] **Step 6: Write failing test for `updateProgress`, `markCompleted`, `markFailed`**

```zig
test "updateProgress writes progress and refreshes updated_at" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();
    try seedProject(&db, gpa, "p1");
    try insert(&db, gpa, .{
        .id = "j1", .project_id = "p1", .type = .slice, .status = .running,
        .progress = 0.0, .payload = "{}", .results = null, .error_msg = null,
        .created_at = "2026-05-24T10:00:00Z", .updated_at = "2026-05-24T10:00:00Z",
    });

    try updateProgress(&db, "j1", 0.5);

    var got = (try getById(&db, gpa, "j1")) orelse return error.TestUnexpectedNull;
    defer got.deinit(gpa);
    try std.testing.expectEqual(@as(f64, 0.5), got.progress);
    try std.testing.expect(!std.mem.eql(u8, got.updated_at, "2026-05-24T10:00:00Z"));
}

test "markCompleted sets status, progress=1, results, updated_at" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();
    try seedProject(&db, gpa, "p1");
    try insert(&db, gpa, .{
        .id = "j1", .project_id = "p1", .type = .slice, .status = .running,
        .progress = 0.5, .payload = "{}", .results = null, .error_msg = null,
        .created_at = "2026-05-24T10:00:00Z", .updated_at = "2026-05-24T10:00:00Z",
    });

    try markCompleted(&db, "j1", "{\"output\":\"ok\"}");

    var got = (try getById(&db, gpa, "j1")) orelse return error.TestUnexpectedNull;
    defer got.deinit(gpa);
    try std.testing.expectEqual(JobStatus.completed, got.status);
    try std.testing.expectEqual(@as(f64, 1.0), got.progress);
    try std.testing.expectEqualStrings("{\"output\":\"ok\"}", got.results.?);
}

test "markFailed sets status, error message, updated_at" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();
    try seedProject(&db, gpa, "p1");
    try insert(&db, gpa, .{
        .id = "j1", .project_id = "p1", .type = .slice, .status = .running,
        .progress = 0.5, .payload = "{}", .results = null, .error_msg = null,
        .created_at = "2026-05-24T10:00:00Z", .updated_at = "2026-05-24T10:00:00Z",
    });

    try markFailed(&db, "j1", "bad input");

    var got = (try getById(&db, gpa, "j1")) orelse return error.TestUnexpectedNull;
    defer got.deinit(gpa);
    try std.testing.expectEqual(JobStatus.failed, got.status);
    try std.testing.expectEqualStrings("bad input", got.error_msg.?);
}

test "updateProgress on missing id returns NotFound" {
    var db = try test_helpers.openTestDb();
    defer db.close();
    try std.testing.expectError(error.NotFound, updateProgress(&db, "ghost", 0.5));
}
```

Run: `zig build test`
Expected: FAIL.

- [ ] **Step 7: Implement update functions**

```zig
fn freshTimestamp() ![32]u8 {
    var buf: [32]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const ts = try db_mod.nowIso8601(fba.allocator());
    var out: [32]u8 = .{0} ** 32;
    @memcpy(out[0..ts.len], ts);
    return out;
}

pub fn updateProgress(db: *Db, id: []const u8, progress: f64) !void {
    var buf: [32]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const ts = try db_mod.nowIso8601(fba.allocator());
    try db.conn.exec(
        "UPDATE jobs SET progress = ?, updated_at = ? WHERE id = ?",
        .{ progress, ts, id },
    );
    if (db.conn.changes() == 0) return error.NotFound;
}

pub fn markCompleted(db: *Db, id: []const u8, results: []const u8) !void {
    var buf: [32]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const ts = try db_mod.nowIso8601(fba.allocator());
    try db.conn.exec(
        \\UPDATE jobs
        \\SET status = 'completed', progress = 1.0, results = ?, updated_at = ?
        \\WHERE id = ?
    , .{ results, ts, id });
    if (db.conn.changes() == 0) return error.NotFound;
}

pub fn markFailed(db: *Db, id: []const u8, error_msg: []const u8) !void {
    var buf: [32]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const ts = try db_mod.nowIso8601(fba.allocator());
    try db.conn.exec(
        \\UPDATE jobs SET status = 'failed', error = ?, updated_at = ?
        \\WHERE id = ?
    , .{ error_msg, ts, id });
    if (db.conn.changes() == 0) return error.NotFound;
}
```

Run: `zig build test`
Expected: PASS.

- [ ] **Step 8: Write failing test for foreign-key cascade on jobs**

```zig
test "deleting a project cascades to its jobs" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();
    try seedProject(&db, gpa, "p1");
    try insert(&db, gpa, .{
        .id = "j1", .project_id = "p1", .type = .slice, .status = .queued,
        .progress = 0.0, .payload = "{}", .results = null, .error_msg = null,
        .created_at = "t", .updated_at = "t",
    });

    try projects.delete(&db, "p1");
    var list = try listByProject(&db, gpa, "p1");
    defer deinitList(list, gpa);
    try std.testing.expectEqual(@as(usize, 0), list.len);
}
```

Run: `zig build test`
Expected: PASS (cascade is from schema, not new code).

- [ ] **Step 9: Commit**

```bash
git add src/db/jobs.zig src/main.zig
git commit -m "feat(db): add Job struct with insert/get/list/update operations"
```

---

### Task 6: Jobs — `claimNextQueued`

**Files:**
- Modify: `src/db/jobs.zig`

- [ ] **Step 1: Write failing test for FIFO claim**

Append to test block in `src/db/jobs.zig`:

```zig
test "claimNextQueued returns oldest queued job and marks it running" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();
    try seedProject(&db, gpa, "p1");

    try insert(&db, gpa, .{
        .id = "j2", .project_id = "p1", .type = .slice, .status = .queued,
        .progress = 0.0, .payload = "{}", .results = null, .error_msg = null,
        .created_at = "2026-05-24T10:00:01Z", .updated_at = "2026-05-24T10:00:01Z",
    });
    try insert(&db, gpa, .{
        .id = "j1", .project_id = "p1", .type = .slice, .status = .queued,
        .progress = 0.0, .payload = "{}", .results = null, .error_msg = null,
        .created_at = "2026-05-24T10:00:00Z", .updated_at = "2026-05-24T10:00:00Z",
    });
    try insert(&db, gpa, .{
        .id = "j3", .project_id = "p1", .type = .slice, .status = .completed,
        .progress = 1.0, .payload = "{}", .results = "x", .error_msg = null,
        .created_at = "2026-05-24T09:00:00Z", .updated_at = "2026-05-24T09:00:00Z",
    });

    var claimed1 = (try claimNextQueued(&db, gpa)) orelse return error.TestUnexpectedNull;
    defer claimed1.deinit(gpa);
    try std.testing.expectEqualStrings("j1", claimed1.id);
    try std.testing.expectEqual(JobStatus.running, claimed1.status);

    var claimed2 = (try claimNextQueued(&db, gpa)) orelse return error.TestUnexpectedNull;
    defer claimed2.deinit(gpa);
    try std.testing.expectEqualStrings("j2", claimed2.id);

    const claimed3 = try claimNextQueued(&db, gpa);
    try std.testing.expect(claimed3 == null);
}
```

Run: `zig build test`
Expected: FAIL — `claimNextQueued` undefined.

- [ ] **Step 2: Implement `claimNextQueued`**

```zig
pub fn claimNextQueued(db: *Db, gpa: Allocator) !?Job {
    var buf: [32]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const ts = try db_mod.nowIso8601(fba.allocator());

    const row = (try db.conn.row(
        \\UPDATE jobs
        \\SET status = 'running', updated_at = ?
        \\WHERE id = (
        \\  SELECT id FROM jobs WHERE status = 'queued'
        \\  ORDER BY created_at ASC LIMIT 1
        \\)
        \\RETURNING id, project_id, type, status, progress, payload, results, error,
        \\          created_at, updated_at
    , .{ts})) orelse return null;
    defer row.deinit();
    return try rowToJob(row, gpa);
}
```

Run: `zig build test`
Expected: PASS.

- [ ] **Step 3: Write a falsifiability test — claim must be atomic (no double-claim)**

```zig
test "claimNextQueued does not return the same job twice" {
    const gpa = std.testing.allocator;
    var db = try test_helpers.openTestDb();
    defer db.close();
    try seedProject(&db, gpa, "p1");
    try insert(&db, gpa, .{
        .id = "only", .project_id = "p1", .type = .slice, .status = .queued,
        .progress = 0.0, .payload = "{}", .results = null, .error_msg = null,
        .created_at = "t", .updated_at = "t",
    });

    var first = (try claimNextQueued(&db, gpa)) orelse return error.TestUnexpectedNull;
    defer first.deinit(gpa);
    try std.testing.expectEqualStrings("only", first.id);

    const second = try claimNextQueued(&db, gpa);
    try std.testing.expect(second == null);
}
```

Run: `zig build test`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/db/jobs.zig
git commit -m "feat(db): add atomic claimNextQueued for job worker"
```

---

### Task 7: Wire `Db` into `main.zig` and verify daemon still works

**Files:**
- Modify: `src/main.zig`

- [ ] **Step 1: Replace the inline zqlite setup with `Db`**

Edit `src/main.zig`. Replace lines 101-117 (the `db_path` construction through `migrations.run(conn)` block) with:

```zig
    const db_path = try std.fs.path.joinZ(gpa, &.{ config.data_dir, "data.db" });
    defer gpa.free(db_path);

    var db = try @import("db/db.zig").Db.open(db_path);
    defer db.close();
```

Remove the now-unused `zqlite` import at the top of `main.zig` if nothing else references it. Keep the `migrations` import removal as well if it's only used here.

- [ ] **Step 2: Run build to confirm compilation**

Run: `zig build`
Expected: clean build, executable produced at `zig-out/bin/logos`.

- [ ] **Step 3: Run the full test suite**

Run: `zig build test`
Expected: PASS — every test from Tasks 1–6 plus any pre-existing tests.

- [ ] **Step 4: Smoke-test the daemon end-to-end**

Run: `echo "" | zig-out/bin/logos -p 7778`
Expected:
- stdout: `daemon running: pid=<n> port=7778 data_dir=...`
- exits cleanly when stdin closes
- a `data.db` file appears under the data dir with the v1 schema

- [ ] **Step 5: Commit**

```bash
git add src/main.zig
git commit -m "refactor(main): construct Db wrapper instead of raw zqlite.Conn"
```

---

## Acceptance Criteria (from spec)

- `zig build test` passes with all unit tests green.
- All CRUD operations work and respect constraints:
  - Project unique-name violation maps to `error.UniqueViolation` (Task 2).
  - Slice composite-key duplicate maps to `error.UniqueViolation` (Task 4).
  - Slice with unknown `project_id` maps to `error.ForeignKeyViolation` (Task 4).
  - Page-count `CHECK` violations map to `error.CheckViolation` (Task 2, Task 4).
- Foreign-key cascades work: deleting a project removes its slices and jobs (Task 4 Step 7, Task 5 Step 8).
- `claimNextQueued` atomically claims the oldest queued job and marks it `running` (Task 6).

## Self-Review Notes

- **Spec coverage:**
  - `Project` struct + all six CRUD methods — Tasks 2 & 3 ✓
  - `Slice` CRUD — Task 4 ✓
  - `Job` CRUD + `claimNextQueued` — Tasks 5 & 6 ✓
  - `DbError` set covering NotFound, UniqueViolation, ForeignKeyViolation, CheckViolation — Task 1 ✓ (NotNullViolation added defensively; the spec's "etc." invites it)
  - In-memory test DB — Task 1 ✓
  - Unique constraint test — Task 2 Step 8 ✓
  - Foreign key cascade test — Task 4 Step 7 and Task 5 Step 8 ✓
- **Type consistency check:** every CRUD helper takes `db: *Db` first; read helpers add `gpa: Allocator`; write helpers omit it; struct names (`Project`, `Slice`, `Job`) and method names (`insert`, `getById`, `listAll`, etc.) match the spec verbatim. `Job.error` is renamed to `error_msg` in Zig because `error` is a reserved keyword — column name in SQL stays `error`.
- **zqlite API caveat:** the `rows.next()`/`rows.errorIfAny()` calls in Tasks 3, 4, 5 assume the vendored `zqlite.zig` exposes those names. If the version pinned in `build.zig.zon` uses `try rows.next()` returning `?Row` or a different cursor protocol, adapt the loop accordingly when implementing — the SQL itself doesn't change.
- **Risk classification (Gate 4):** Bounded. Failures stay inside the SQLite connection. No multi-process state, no network I/O. Test allocator catches leaks. Schema changes are gated by migrations, which are out of scope here.
- **Epistemological humility (Gate 5):** the tests use `:memory:` databases so any WAL- or concurrency-specific behavior in production won't surface here. The atomic-claim test covers single-connection correctness only; multi-connection race conditions need a separate integration test once a worker thread exists (Phase 8+ territory).
