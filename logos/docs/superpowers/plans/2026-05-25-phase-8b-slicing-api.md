# Phase 8b: Slicing API — Jobs + Slices over HTTP

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the five remaining endpoints the chargesheet-ui calls — POST /jobs/slice, GET /jobs/:job_id, GET /slices, DELETE/GET /slices/:filename — so the UI can actually slice PDFs end-to-end via logos.

**Architecture:** POST /jobs/slice does slicing **synchronously inside the handler** (matching the mock-daemon exactly): parse JSON body → validate → for each requested slice, open the chargesheet via mupdf-zig and write the output to `<data_dir>/<project_id>/slices/<filename>.pdf` → insert a Job row with `status=completed` (or `failed` if all slices failed) → return `{job_id, status: "queued"}` with HTTP 202. The GET endpoints read from DB + filesystem. The router gains a `child` path parameter so `/jobs/:job_id` and `/slices/:filename` can both extract two IDs.

**Tech Stack:** Same as 8a — `std.http.Server`, `std.json`, mupdf-zig, existing logos `db.*` modules.

**Scope (this plan):**

| Endpoint | Method | Purpose |
|---|---|---|
| `/api/v1/projects/:id/jobs/slice` | POST | validate JSON body + sync-execute slices + return job |
| `/api/v1/projects/:id/jobs/:job_id` | GET | poll job status (returns completed/failed for sync jobs) |
| `/api/v1/projects/:id/slices` | GET | list slices for a project |
| `/api/v1/projects/:id/slices/:filename` | GET | download a slice PDF |
| `/api/v1/projects/:id/slices/:filename` | DELETE | remove a slice |

**Patterns established in 8a that we reuse:**
- Handler returns `Error!Result`; `respond*Error` switches map errors to status + code.
- `writeJsonString` for JSON-safe escaping.
- `std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(N))` for file downloads.
- `extractBoundary` + multipart for uploads — NOT used in 8b (slice POST is JSON, not multipart).
- One mupdf.Context per request (Phase 8c may optimize).
- Filesystem layout: `data_dir/<project_id>/slices/<filename>` (slices dir already created by Task 3 of 8a's `createProjectTree`).

**The UI JSON contract** (from `chargesheet-ui/src/lib/api/schemas.ts`):

```typescript
// POST /jobs/slice request body
{ slices: Array<{ start_page: int, end_page: int, filename: string }> }

// POST /jobs/slice response (202 Accepted)
{ job_id: string, status: "queued" }   // Always literal "queued" — JobCreatedResponseSchema

// GET /jobs/:job_id response
{
  job_id: string,
  status: "queued"|"running"|"completed"|"failed",
  progress: number,  // 0..1
  results: Array<{
    filename: string,
    status: "completed"|"failed",
    page_range: [int, int],
    size_bytes: int,    // 0 if failed
    error: string|null,
  }>,
  error: string|null,
}

// GET /slices response
{
  slices: Array<{
    filename: string,
    page_range: [int, int],
    size_bytes: int,
    created_at: string,
  }>
}
```

**Error codes from the mock** (mirror exactly):
- `400 INVALID_REQUEST` — body parse failure, missing fields, wrong types
- `400 INVALID_RANGE` — start/end out of bounds or `start > end`
- `400 INVALID_FILENAME` — contains `/` `\`, equal to `.` or `..`, length 0 or > 255
- `400 DUPLICATE_FILENAMES` — two slices in the same request have the same filename
- `404 NOT_FOUND` — project or job or slice missing
- `409` not used here (uniqueness handled at slices PK level; conflicts surface as INTERNAL_ERROR per-slice via results array)

---

## File Structure

```
src/
├── api/
│   ├── router.zig          # MODIFIED: add 5 new routes + `child` path param
│   ├── handlers.zig        # MODIFIED: add 5 new handlers
│   ├── server.zig          # MODIFIED: 5 new respond* functions
│   └── json.zig            # MODIFIED: writeJob, writeJobCreated, writeSliceListing
├── ids.zig                 # MODIFIED: add generateJobId
└── storage/
    └── project_dir.zig     # MODIFIED: slicePath, sliceListing helpers
```

Conventions enforced:
- New responses use 16 KiB fixed buffer (matches 8a); if responses outgrow it, Phase 8c switches to allocator-backed writers (already noted as 8a tech debt).
- Filename validation centralized in `project_dir.isSafeFilename` (single source of truth).
- Job results JSON is stored as TEXT in the `results` column (per `v1.sql`); the GET handler returns it inline without re-serializing.

---

### Task 1: Router extension + `child` path param

Add 5 new routes. Router gains a `child: ?[]const u8` field for the second path segment.

**Files:**
- Modify: `src/api/router.zig`

- [ ] **Step 1: Replace `Match` and `Route` + extend `match`**

```zig
const std = @import("std");
const testing = std.testing;

pub const Method = enum { GET, POST, DELETE, OPTIONS };

pub const Route = enum {
    health,
    projects_list,
    projects_create,
    projects_get,
    projects_delete,
    projects_chargesheet,
    projects_jobs_slice,
    projects_jobs_get,
    projects_slices_list,
    projects_slices_get,
    projects_slices_delete,
    not_found,
    cors_preflight,
};

pub const Match = struct {
    route: Route,
    /// First path parameter (e.g. project id).
    id: ?[]const u8 = null,
    /// Second path parameter (e.g. job_id or filename).
    child: ?[]const u8 = null,
};

pub fn match(method: Method, path: []const u8) Match {
    if (method == .OPTIONS and std.mem.startsWith(u8, path, "/api/")) {
        return .{ .route = .cors_preflight };
    }
    if (method == .GET and std.mem.eql(u8, path, "/api/v1/health")) return .{ .route = .health };
    if (method == .GET and std.mem.eql(u8, path, "/api/v1/projects")) return .{ .route = .projects_list };
    if (method == .POST and std.mem.eql(u8, path, "/api/v1/projects")) return .{ .route = .projects_create };

    const prefix = "/api/v1/projects/";
    if (!std.mem.startsWith(u8, path, prefix)) return .{ .route = .not_found };

    const rest = path[prefix.len..];
    const first_slash = std.mem.indexOfScalar(u8, rest, '/');
    if (first_slash == null) {
        if (method == .GET) return .{ .route = .projects_get, .id = rest };
        if (method == .DELETE) return .{ .route = .projects_delete, .id = rest };
        return .{ .route = .not_found };
    }

    const id = rest[0..first_slash.?];
    const after_id = rest[first_slash.? + 1 ..];

    // /api/v1/projects/:id/chargesheet
    if (method == .GET and std.mem.eql(u8, after_id, "chargesheet")) {
        return .{ .route = .projects_chargesheet, .id = id };
    }

    // /api/v1/projects/:id/jobs/...
    if (std.mem.startsWith(u8, after_id, "jobs/")) {
        const job_part = after_id["jobs/".len..];
        if (method == .POST and std.mem.eql(u8, job_part, "slice")) {
            return .{ .route = .projects_jobs_slice, .id = id };
        }
        // /api/v1/projects/:id/jobs/:job_id
        if (method == .GET and std.mem.indexOfScalar(u8, job_part, '/') == null and job_part.len > 0) {
            return .{ .route = .projects_jobs_get, .id = id, .child = job_part };
        }
    }

    // /api/v1/projects/:id/slices/...
    if (std.mem.eql(u8, after_id, "slices") and method == .GET) {
        return .{ .route = .projects_slices_list, .id = id };
    }
    if (std.mem.startsWith(u8, after_id, "slices/")) {
        const filename = after_id["slices/".len..];
        if (filename.len > 0 and std.mem.indexOfScalar(u8, filename, '/') == null) {
            if (method == .GET) return .{ .route = .projects_slices_get, .id = id, .child = filename };
            if (method == .DELETE) return .{ .route = .projects_slices_delete, .id = id, .child = filename };
        }
    }

    return .{ .route = .not_found };
}
```

- [ ] **Step 2: Add tests for the 5 new routes**

Append to `src/api/router.zig`:

```zig
test "match POST /api/v1/projects/:id/jobs/slice" {
    const m = match(.POST, "/api/v1/projects/proj_abc/jobs/slice");
    try testing.expectEqual(Route.projects_jobs_slice, m.route);
    try testing.expectEqualStrings("proj_abc", m.id.?);
    try testing.expect(m.child == null);
}

test "match GET /api/v1/projects/:id/jobs/:job_id" {
    const m = match(.GET, "/api/v1/projects/proj_abc/jobs/job_xyz");
    try testing.expectEqual(Route.projects_jobs_get, m.route);
    try testing.expectEqualStrings("proj_abc", m.id.?);
    try testing.expectEqualStrings("job_xyz", m.child.?);
}

test "match GET /api/v1/projects/:id/slices" {
    const m = match(.GET, "/api/v1/projects/proj_abc/slices");
    try testing.expectEqual(Route.projects_slices_list, m.route);
    try testing.expectEqualStrings("proj_abc", m.id.?);
    try testing.expect(m.child == null);
}

test "match GET /api/v1/projects/:id/slices/:filename" {
    const m = match(.GET, "/api/v1/projects/proj_abc/slices/intro.pdf");
    try testing.expectEqual(Route.projects_slices_get, m.route);
    try testing.expectEqualStrings("proj_abc", m.id.?);
    try testing.expectEqualStrings("intro.pdf", m.child.?);
}

test "match DELETE /api/v1/projects/:id/slices/:filename" {
    const m = match(.DELETE, "/api/v1/projects/proj_abc/slices/intro.pdf");
    try testing.expectEqual(Route.projects_slices_delete, m.route);
    try testing.expectEqualStrings("proj_abc", m.id.?);
    try testing.expectEqualStrings("intro.pdf", m.child.?);
}

test "match rejects nested filename slashes" {
    const m = match(.GET, "/api/v1/projects/proj_abc/slices/sub/dir.pdf");
    try testing.expectEqual(Route.not_found, m.route);
}
```

- [ ] **Step 3: Update `server.zig`'s switch to handle new routes**

Find the existing switch in `serveRequest`. Add arms for each new route. **For now, route them all to `respondNotFound`** — handlers come in subsequent tasks. This keeps Task 1 small and reviewable.

```zig
return switch (m.route) {
    .health => respondHealth(gpa, request, opts.version),
    .cors_preflight => respondCors(request),
    .projects_list => respondProjectsList(gpa, db, request),
    .projects_create => respondProjectsCreate(io, gpa, db, request, opts),
    .projects_get => respondProjectsGet(gpa, db, request, m.id orelse return respondNotFound(gpa, request)),
    .projects_delete => respondProjectsDelete(io, gpa, db, request, opts, m.id orelse return respondNotFound(gpa, request)),
    .projects_chargesheet => respondProjectsChargesheet(io, gpa, db, request, opts, m.id orelse return respondNotFound(gpa, request)),
    // NEW (Task 1) — placeholders, real handlers added in Tasks 4-6:
    .projects_jobs_slice,
    .projects_jobs_get,
    .projects_slices_list,
    .projects_slices_get,
    .projects_slices_delete,
    .not_found => respondNotFound(gpa, request),
};
```

- [ ] **Step 4: Run tests**

```bash
zig build test --summary all
```

Expected: 68/68 (62 prior + 6 router tests).

- [ ] **Step 5: Commit**

```bash
git add src/api/router.zig src/api/server.zig
git commit -m "feat(api): add 5 routes for jobs and slices (handlers in subsequent tasks)"
```

---

### Task 2: JSON serializers + filename validation

Add `writeJob`, `writeJobCreated`, `writeSliceListing` to `json.zig`, plus `isSafeFilename` to `project_dir.zig`. Also add `generateJobId` to `ids.zig`.

**Files:**
- Modify: `src/api/json.zig`
- Modify: `src/storage/project_dir.zig`
- Modify: `src/ids.zig`

- [ ] **Step 1: Add `isSafeFilename` to `src/storage/project_dir.zig`**

Append:

```zig
/// Return true if `name` is safe to use as a slice filename — no path separators,
/// not `.` or `..`, length 1..255. Mirrors the mock-daemon's `isSafeFilename`.
pub fn isSafeFilename(name: []const u8) bool {
    if (name.len == 0 or name.len > 255) return false;
    if (std.mem.indexOfScalar(u8, name, '/') != null) return false;
    if (std.mem.indexOfScalar(u8, name, '\\') != null) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    return true;
}

/// Compute the slice path. Caller frees.
pub fn slicePath(gpa: std.mem.Allocator, data_dir: []const u8, project_id: []const u8, filename: []const u8) ![]u8 {
    return std.fs.path.join(gpa, &.{ data_dir, project_id, "slices", filename });
}

/// Remove a single slice file. Returns error.FileNotFound if absent.
pub fn removeSlice(io: std.Io, gpa: std.mem.Allocator, data_dir: []const u8, project_id: []const u8, filename: []const u8) !void {
    const path = try slicePath(gpa, data_dir, project_id, filename);
    defer gpa.free(path);
    try std.Io.Dir.cwd().deleteFile(io, path);
}

test "isSafeFilename rejects path traversal" {
    try std.testing.expect(!isSafeFilename(""));
    try std.testing.expect(!isSafeFilename("."));
    try std.testing.expect(!isSafeFilename(".."));
    try std.testing.expect(!isSafeFilename("a/b"));
    try std.testing.expect(!isSafeFilename("a\\b"));
    try std.testing.expect(isSafeFilename("foo.pdf"));
    try std.testing.expect(isSafeFilename("intro-pages-1-3.pdf"));
}

test "isSafeFilename enforces length bounds" {
    try std.testing.expect(!isSafeFilename(""));
    // 255 chars allowed
    var buf: [255]u8 = undefined;
    @memset(&buf, 'a');
    try std.testing.expect(isSafeFilename(&buf));
    // 256 rejected
    var buf2: [256]u8 = undefined;
    @memset(&buf2, 'a');
    try std.testing.expect(!isSafeFilename(&buf2));
}
```

- [ ] **Step 2: Add `generateJobId` to `src/ids.zig`**

The current `generateProjectId(io, gpa)` allocates 41 bytes with prefix `proj_`. We extract a shared helper:

Replace the existing file body with:

```zig
const std = @import("std");

/// Generate `<prefix>_<uuid-v4-with-dashes>`. Allocates `prefix.len + 1 + 36 = 41` bytes
/// when prefix is "proj" or "job" (both 3-char + underscore + 36-char UUID = 40, oops).
/// Actually `<prefix>_` + 36-char UUID. For 4-char prefixes ("proj", "job") allocates 41 / 40 bytes.
/// Caller owns the returned slice.
fn generateIdWithPrefix(io: std.Io, gpa: std.mem.Allocator, prefix: []const u8) ![]u8 {
    var bytes: [16]u8 = undefined;
    io.random(&bytes);
    bytes[6] = (bytes[6] & 0x0F) | 0x40;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;

    const total_len = prefix.len + 1 + 36;
    const buf = try gpa.alloc(u8, total_len);
    errdefer gpa.free(buf);

    _ = try std.fmt.bufPrint(buf,
        "{s}_{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{ prefix,
           bytes[0], bytes[1], bytes[2], bytes[3],
           bytes[4], bytes[5], bytes[6], bytes[7],
           bytes[8], bytes[9], bytes[10], bytes[11],
           bytes[12], bytes[13], bytes[14], bytes[15] });
    return buf;
}

pub fn generateProjectId(io: std.Io, gpa: std.mem.Allocator) ![]u8 {
    return generateIdWithPrefix(io, gpa, "proj");
}

pub fn generateJobId(io: std.Io, gpa: std.mem.Allocator) ![]u8 {
    return generateIdWithPrefix(io, gpa, "job");
}

test "generateProjectId returns a 41-char proj_<uuid>" {
    const gpa = std.testing.allocator;
    const id = try generateProjectId(std.testing.io, gpa);
    defer gpa.free(id);
    try std.testing.expectEqual(@as(usize, 41), id.len);
    try std.testing.expectEqualStrings("proj_", id[0..5]);
    try std.testing.expectEqual(@as(u8, '-'), id[13]);
    try std.testing.expectEqual(@as(u8, '-'), id[18]);
    try std.testing.expectEqual(@as(u8, '-'), id[23]);
    try std.testing.expectEqual(@as(u8, '-'), id[28]);
}

test "generateJobId returns a 40-char job_<uuid>" {
    const gpa = std.testing.allocator;
    const id = try generateJobId(std.testing.io, gpa);
    defer gpa.free(id);
    try std.testing.expectEqual(@as(usize, 40), id.len);
    try std.testing.expectEqualStrings("job_", id[0..4]);
}

test "two ids are different" {
    const gpa = std.testing.allocator;
    const a = try generateProjectId(std.testing.io, gpa);
    defer gpa.free(a);
    const b = try generateProjectId(std.testing.io, gpa);
    defer gpa.free(b);
    try std.testing.expect(!std.mem.eql(u8, a, b));
}
```

Note: dash positions in the existing test were at 13/18/23/28 for `proj_` (5-char prefix). For `job_` (4-char prefix) the dashes would be at 12/17/22/27. The new "generateJobId returns 40-char" test just checks the length + prefix; if you want to also check dash positions, adapt — but length + prefix is sufficient.

- [ ] **Step 3: Add JSON serializers to `src/api/json.zig`**

Append (the existing file has `writeHealth`, `writeError`, `writeJsonString`, `writeProject`, `writeProjectArrayOpen/Close`):

```zig
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

/// Write GET /slices response: { slices: [...] }.
pub fn writeSliceListingArrayOpen(w: *std.Io.Writer) !void {
    try w.writeAll("{\"slices\":[");
}

pub fn writeSliceListingArrayClose(w: *std.Io.Writer) !void {
    try w.writeAll("]}");
}

/// Write GET /jobs/:id response. `results_json` is the raw JSON string stored
/// in the `jobs.results` column (already serialized at write-time); we splice
/// it in unescaped. `error_msg` is the `jobs.error` column (nullable).
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
```

- [ ] **Step 4: Run tests**

```bash
zig build test --summary all
```

Expected: 78/78 (68 + 2 isSafeFilename + 1 job_id + 4 new json tests = 75 expected). Actually count more carefully:
- Prior: 68
- isSafeFilename: 2
- generateJobId: 1 (the new "40-char job_" test)
- Existing tests in ids.zig: was 2 (proj-format + uniqueness); restructured `generateProjectId` still has the same 2 tests, so net new = 1.
- json: 4 new (writeJobCreated, writeJob null results, writeJob with embedded, writeSliceListingItem)

68 + 2 + 1 + 4 = **75/75**.

If the count differs, recount existing tests in each file before/after.

- [ ] **Step 5: Commit**

```bash
git add src/api/json.zig src/storage/project_dir.zig src/ids.zig
git commit -m "feat: JSON serializers + filename validation + generateJobId for slicing API"
```

---

### Task 3: POST /api/v1/projects/:id/jobs/slice (the big one)

Parse JSON request body → validate every requested slice → for each, open chargesheet via mupdf-zig and slice → insert one Job row with all results → return `{job_id, status:"queued"}` with HTTP 202.

**Files:**
- Modify: `src/api/handlers.zig` (add `handleProjectsJobsSlice`)
- Modify: `src/api/server.zig` (add `respondProjectsJobsSlice` + route arm)

- [ ] **Step 1: Add JSON request-body parsing**

Zig 0.16 has `std.json` with parsing helpers. The exact API:
- `std.json.parseFromSlice(T, gpa, body, .{}) !std.json.Parsed(T)` — strict parse to a Zig type.
- Or `std.json.parseFromSliceLeaky(...)` — same but no `deinit`.

Define the request shape in `src/api/handlers.zig`:

```zig
const SliceRequestItem = struct {
    start_page: i64,  // Wider type so we can validate negatives, then bounds-check.
    end_page: i64,
    filename: []const u8,
};

const SliceRequestBody = struct {
    slices: []SliceRequestItem,
};
```

- [ ] **Step 2: Add `handleProjectsJobsSlice` to `handlers.zig`**

```zig
const json_helper = std.json;
const jobs_mod = @import("../db/jobs.zig");
const slices_mod = @import("../db/slices.zig");

pub const SliceJobError = error{
    InvalidRequest,
    InvalidRange,
    InvalidFilename,
    DuplicateFilenames,
    ProjectNotFound,
    OutOfMemory,
    DbError,
    PdfError,
    IoError,
};

pub const SliceJobResult = struct {
    /// Owned by caller — must `gpa.free(job_id)`.
    job_id: []u8,
};

pub fn handleProjectsJobsSlice(
    io: std.Io,
    gpa: std.mem.Allocator,
    db: *Db,
    data_dir: []const u8,
    project_id: []const u8,
    body: []const u8,
) SliceJobError!SliceJobResult {
    // 1. Look up project to know its page count.
    var maybe_project = projects_mod.getById(db, gpa, project_id) catch return error.DbError;
    if (maybe_project == null) return error.ProjectNotFound;
    var project = maybe_project.?;
    defer project.deinit(gpa);
    const project_page_count = project.chargesheet_page_count;
    const src_path = project_dir.chargesheetPath(gpa, data_dir, project_id) catch return error.OutOfMemory;
    defer gpa.free(src_path);
    const src_path_z = gpa.dupeZ(u8, src_path) catch return error.OutOfMemory;
    defer gpa.free(src_path_z);

    // 2. Parse JSON body.
    const parsed = json_helper.parseFromSlice(SliceRequestBody, gpa, body, .{}) catch return error.InvalidRequest;
    defer parsed.deinit();
    const requested = parsed.value.slices;
    if (requested.len == 0) return error.InvalidRequest;

    // 3. Validate every slice. Two passes: per-item, then uniqueness.
    for (requested) |item| {
        if (item.start_page < 1 or item.end_page < item.start_page or item.end_page > project_page_count) {
            return error.InvalidRange;
        }
        if (!project_dir.isSafeFilename(item.filename)) return error.InvalidFilename;
    }
    // Uniqueness within request: O(n^2) but n is tiny.
    for (requested, 0..) |a, i| {
        for (requested[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.filename, b.filename)) return error.DuplicateFilenames;
        }
    }

    // 4. Set up MuPDF.
    var mupdf_ctx = mupdf.Context.init() catch return error.PdfError;
    defer mupdf_ctx.deinit();

    // 5. Execute each slice. Accumulate results JSON in an ArrayList.
    var results: std.ArrayList(u8) = .empty;
    defer results.deinit(gpa);
    try results.append(gpa, '[');

    var any_succeeded = false;
    var any_failed = false;

    for (requested, 0..) |item, i| {
        if (i > 0) try results.append(gpa, ',');

        // Always open a fresh Document — slice() mutates the in-memory doc.
        var doc_result: ?mupdf.Document = mupdf.Document.open(&mupdf_ctx, src_path_z) catch null;
        if (doc_result == null) {
            try appendFailedSliceResult(gpa, &results, item, "failed to reopen chargesheet");
            any_failed = true;
            continue;
        }
        var doc = doc_result.?;
        defer doc.deinit();

        const out_path = project_dir.slicePath(gpa, data_dir, project_id, item.filename) catch {
            try appendFailedSliceResult(gpa, &results, item, "out of memory");
            any_failed = true;
            continue;
        };
        defer gpa.free(out_path);

        const out_path_z = gpa.dupeZ(u8, out_path) catch {
            try appendFailedSliceResult(gpa, &results, item, "out of memory");
            any_failed = true;
            continue;
        };
        defer gpa.free(out_path_z);

        const size_bytes = doc.slice(out_path_z, @intCast(item.start_page), @intCast(item.end_page)) catch |err| {
            const msg = switch (err) {
                error.InvalidPageRange => "page range out of bounds",
                error.PdfBackendError => "mupdf error during slice",
                error.OutOfMemory => "out of memory",
                else => "slice failed",
            };
            try appendFailedSliceResult(gpa, &results, item, msg);
            any_failed = true;
            continue;
        };

        // Record DB slice row (best-effort — failure here doesn't roll back the file).
        const now = db_mod.nowIso8601(gpa) catch {
            try appendFailedSliceResult(gpa, &results, item, "timestamp alloc failed");
            any_failed = true;
            continue;
        };
        defer gpa.free(now);

        slices_mod.insert(db, gpa, .{
            .project_id = project_id,
            .filename = item.filename,
            .start_page = @intCast(item.start_page),
            .end_page = @intCast(item.end_page),
            .size_bytes = size_bytes,
            .created_at = now,
        }) catch |err| {
            // If insert fails due to a duplicate (already existed), the file is also
            // already on disk and we still consider this slice complete in the response.
            // For any other DB error, mark as failed.
            if (err != error.UniqueViolation) {
                try appendFailedSliceResult(gpa, &results, item, "db insert failed");
                any_failed = true;
                continue;
            }
        };

        try appendSuccessSliceResult(gpa, &results, item, size_bytes);
        any_succeeded = true;
    }
    try results.append(gpa, ']');

    // 6. Insert Job row recording the outcome.
    const job_id = ids.generateJobId(io, gpa) catch return error.OutOfMemory;
    errdefer gpa.free(job_id);

    const status: []const u8 = if (any_succeeded) "completed" else "failed";
    const error_msg: ?[]const u8 = if (!any_succeeded) "All slices failed" else null;
    const now_owned = db_mod.nowIso8601(gpa) catch return error.OutOfMemory;
    defer gpa.free(now_owned);

    const job_row: jobs_mod.Job = .{
        .id = job_id,
        .project_id = project_id,
        .type = .slice,
        .status = if (any_succeeded) .completed else .failed,
        .progress = 1.0,
        .payload = body, // store the request body verbatim
        .results = results.items,
        .error_msg = error_msg,
        .created_at = now_owned,
        .updated_at = now_owned,
    };

    jobs_mod.insert(db, gpa, job_row) catch return error.DbError;

    _ = any_failed; // status logic handled above

    return .{ .job_id = job_id };
}

fn appendSuccessSliceResult(gpa: std.mem.Allocator, results: *std.ArrayList(u8), item: SliceRequestItem, size_bytes: u64) !void {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.writeAll("{\"filename\":");
    try json_mod.writeJsonString(&w, item.filename);
    try w.print(",\"status\":\"completed\",\"page_range\":[{d},{d}],\"size_bytes\":{d},\"error\":null}}", .{ item.start_page, item.end_page, size_bytes });
    try results.appendSlice(gpa, w.buffered());
}

fn appendFailedSliceResult(gpa: std.mem.Allocator, results: *std.ArrayList(u8), item: SliceRequestItem, error_msg: []const u8) !void {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.writeAll("{\"filename\":");
    try json_mod.writeJsonString(&w, item.filename);
    try w.print(",\"status\":\"failed\",\"page_range\":[{d},{d}],\"size_bytes\":0,\"error\":", .{ item.start_page, item.end_page });
    try json_mod.writeJsonString(&w, error_msg);
    try w.writeAll("}");
    try results.appendSlice(gpa, w.buffered());
}
```

NOTE: this is a lot of code. The implementer's job is to type it out, hit compile errors, adapt to actual 0.16 APIs. Key risks:
- `std.json.parseFromSlice` may have different signature/options.
- `std.ArrayList(u8) = .empty;` — established pattern.
- `parsed.deinit()` vs free — check `std.json.Parsed`.
- `jobs_mod.insert` field names — verify against `src/db/jobs.zig`.

- [ ] **Step 3: Add `respondProjectsJobsSlice` to `src/api/server.zig`**

```zig
fn respondProjectsJobsSlice(
    io: std.Io,
    gpa: std.mem.Allocator,
    db: *Db,
    request: *http.Server.Request,
    opts: ServeOptions,
    project_id: []const u8,
) !void {
    // Read body.
    var read_buf: [4096]u8 = undefined;
    const body_reader = request.readerExpectNone(&read_buf);
    const body = body_reader.allocRemaining(gpa, .limited(10 * 1024 * 1024)) catch return respondError(request, .bad_request, "INVALID_REQUEST", "Body too large or unreadable");
    defer gpa.free(body);

    var result = handlers.handleProjectsJobsSlice(io, gpa, db, opts.data_dir, project_id, body) catch |err| {
        return respondSliceJobError(request, err);
    };
    defer gpa.free(result.job_id);

    var resp_buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&resp_buf);
    try json.writeJobCreated(&w, result.job_id);
    const resp_body = w.buffered();

    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    } ++ cors_headers;

    try request.respond(resp_body, .{
        .status = .accepted,  // 202
        .extra_headers = &headers,
    });
}

fn respondSliceJobError(request: *http.Server.Request, err: handlers.SliceJobError) !void {
    const status: std.http.Status = switch (err) {
        error.InvalidRequest, error.InvalidRange, error.InvalidFilename, error.DuplicateFilenames => .bad_request,
        error.ProjectNotFound => .not_found,
        error.OutOfMemory, error.DbError, error.PdfError, error.IoError => .internal_server_error,
    };
    const code: []const u8 = switch (err) {
        error.InvalidRequest => "INVALID_REQUEST",
        error.InvalidRange => "INVALID_RANGE",
        error.InvalidFilename => "INVALID_FILENAME",
        error.DuplicateFilenames => "DUPLICATE_FILENAMES",
        error.ProjectNotFound => "NOT_FOUND",
        else => "INTERNAL_ERROR",
    };
    const message: []const u8 = switch (err) {
        error.InvalidRequest => "Invalid request body",
        error.InvalidRange => "Page range out of bounds",
        error.InvalidFilename => "Filename is invalid",
        error.DuplicateFilenames => "Duplicate filenames in the same request",
        error.ProjectNotFound => "Project not found",
        else => "Internal error",
    };
    try respondError(request, status, code, message);
}
```

Update the dispatch:

```zig
.projects_jobs_slice => respondProjectsJobsSlice(io, gpa, db, request, opts, m.id orelse return respondNotFound(gpa, request)),
```

- [ ] **Step 4: Build + curl-test**

```bash
zig build
CHARGESHEET_DATA_DIR=/tmp/logos-task3-smoke rm -rf /tmp/logos-task3-smoke
CHARGESHEET_DATA_DIR=/tmp/logos-task3-smoke ./zig-out/bin/logos -p 7777 &
PID=$!
sleep 1

# Create a project
ID=$(curl -s -X POST http://localhost:7777/api/v1/projects \
  -F "name=SliceTest" \
  -F "chargesheet=@/Users/user/projects/mupdf-zig/tests/fixtures/sample-10pages.pdf" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
echo "Created: $ID"

echo "=== Slice pages 1-3 + 4-7 ==="
JOB=$(curl -s -i -X POST http://localhost:7777/api/v1/projects/$ID/jobs/slice \
  -H "Content-Type: application/json" \
  -d '{"slices":[{"start_page":1,"end_page":3,"filename":"intro.pdf"},{"start_page":4,"end_page":7,"filename":"body.pdf"}]}')
echo "$JOB"

echo "=== Verify slice files on disk ==="
ls -la /tmp/logos-task3-smoke/$ID/slices/
# Expect: intro.pdf, body.pdf

echo "=== Invalid range (end > page_count) ==="
curl -s -i -X POST http://localhost:7777/api/v1/projects/$ID/jobs/slice \
  -H "Content-Type: application/json" \
  -d '{"slices":[{"start_page":1,"end_page":99,"filename":"oops.pdf"}]}' | head -3

echo "=== Invalid filename (path traversal) ==="
curl -s -i -X POST http://localhost:7777/api/v1/projects/$ID/jobs/slice \
  -H "Content-Type: application/json" \
  -d '{"slices":[{"start_page":1,"end_page":3,"filename":"../etc/passwd"}]}' | head -3

echo "=== Duplicate filenames ==="
curl -s -i -X POST http://localhost:7777/api/v1/projects/$ID/jobs/slice \
  -H "Content-Type: application/json" \
  -d '{"slices":[{"start_page":1,"end_page":3,"filename":"a.pdf"},{"start_page":4,"end_page":7,"filename":"a.pdf"}]}' | head -3

echo "=== Missing project ==="
curl -s -i -X POST http://localhost:7777/api/v1/projects/proj_ghost/jobs/slice \
  -H "Content-Type: application/json" \
  -d '{"slices":[{"start_page":1,"end_page":3,"filename":"x.pdf"}]}' | head -3

kill $PID; wait $PID 2>/dev/null
```

Expected:
- Happy path: 202 Accepted, body `{"job_id":"job_...","status":"queued"}`. Two PDFs on disk.
- Invalid range: 400, `INVALID_RANGE`.
- Invalid filename: 400, `INVALID_FILENAME`.
- Duplicates: 400, `DUPLICATE_FILENAMES`.
- Missing project: 404, `NOT_FOUND`.

- [ ] **Step 5: Run unit tests**

```bash
zig build test --summary all
```

Expected: 75/75 (no new tests this task — handler tested via curl).

- [ ] **Step 6: Commit**

```bash
git add src/api/
git commit -m "feat(api): POST /api/v1/projects/:id/jobs/slice with synchronous execution"
```

---

### Task 4: GET /api/v1/projects/:id/jobs/:job_id

Read job from DB, serialize to JSON. The `results` column is already JSON; splice it in via `writeJob`.

**Files:**
- Modify: `src/api/handlers.zig` (add `handleProjectsJobsGet`)
- Modify: `src/api/server.zig` (add `respondProjectsJobsGet` + route arm)

- [ ] **Step 1: Add `handleProjectsJobsGet`**

```zig
pub const GetJobError = error{
    NotFound,
    DbError,
    OutOfMemory,
};

pub fn handleProjectsJobsGet(
    gpa: std.mem.Allocator,
    db: *Db,
    project_id: []const u8,
    job_id: []const u8,
) GetJobError!jobs_mod.Job {
    // First check the project exists (the mock 404s if missing).
    var maybe_project = projects_mod.getById(db, gpa, project_id) catch return error.DbError;
    if (maybe_project == null) return error.NotFound;
    maybe_project.?.deinit(gpa);

    var maybe_job = jobs_mod.getById(db, gpa, job_id) catch return error.DbError;
    if (maybe_job == null) return error.NotFound;
    var job = maybe_job.?;
    // The mock also checks the job belongs to this project; we mirror that.
    if (!std.mem.eql(u8, job.project_id, project_id)) {
        job.deinit(gpa);
        return error.NotFound;
    }
    return job;
}
```

- [ ] **Step 2: Add `respondProjectsJobsGet`**

```zig
fn respondProjectsJobsGet(
    gpa: std.mem.Allocator,
    db: *Db,
    request: *http.Server.Request,
    project_id: []const u8,
    job_id: []const u8,
) !void {
    var job = handlers.handleProjectsJobsGet(gpa, db, project_id, job_id) catch |err| {
        return switch (err) {
            error.NotFound => respondError(request, .not_found, "NOT_FOUND", "Job not found"),
            else => respondError(request, .internal_server_error, "INTERNAL_ERROR", "Internal error"),
        };
    };
    defer job.deinit(gpa);

    var buf: [16 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try json.writeJob(
        &w,
        job.id,
        @tagName(job.status),  // converts enum to its string name (matches "queued"/"running"/"completed"/"failed")
        job.progress,
        job.results,
        job.error_msg,
    );
    const body = w.buffered();

    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    } ++ cors_headers;

    try request.respond(body, .{
        .status = .ok,
        .extra_headers = &headers,
    });
}
```

NOTE: `@tagName(job.status)` returns the field name of the enum value. The DB enum is `JobStatus { queued, running, completed, failed }` so `@tagName(.completed)` returns `"completed"`. Verify against `src/db/jobs.zig` that the enum names exactly match the UI's expected strings.

Update dispatch:

```zig
.projects_jobs_get => respondProjectsJobsGet(gpa, db, request, m.id orelse return respondNotFound(gpa, request), m.child orelse return respondNotFound(gpa, request)),
```

- [ ] **Step 3: Curl-test**

```bash
zig build
CHARGESHEET_DATA_DIR=/tmp/logos-task4-smoke rm -rf /tmp/logos-task4-smoke
CHARGESHEET_DATA_DIR=/tmp/logos-task4-smoke ./zig-out/bin/logos -p 7777 &
PID=$!
sleep 1

# Create + slice
ID=$(curl -s -X POST http://localhost:7777/api/v1/projects \
  -F "name=JobPoll" \
  -F "chargesheet=@/Users/user/projects/mupdf-zig/tests/fixtures/sample-10pages.pdf" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
JOB_ID=$(curl -s -X POST http://localhost:7777/api/v1/projects/$ID/jobs/slice \
  -H "Content-Type: application/json" \
  -d '{"slices":[{"start_page":1,"end_page":3,"filename":"intro.pdf"}]}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['job_id'])")
echo "Job: $JOB_ID"

echo "=== Poll the job ==="
curl -s http://localhost:7777/api/v1/projects/$ID/jobs/$JOB_ID | python3 -m json.tool

echo "=== Non-existent job ==="
curl -s -i http://localhost:7777/api/v1/projects/$ID/jobs/job_ghost | head -3

echo "=== Wrong project for existing job ==="
curl -s -i http://localhost:7777/api/v1/projects/proj_ghost/jobs/$JOB_ID | head -3

kill $PID; wait $PID 2>/dev/null
```

Expected:
- Poll: 200, JSON with `status:"completed"`, `progress:1`, results array with one item showing the intro.pdf result.
- Non-existent job: 404.
- Wrong project: 404.

- [ ] **Step 4: Commit**

```bash
git add src/api/
git commit -m "feat(api): GET /api/v1/projects/:id/jobs/:job_id"
```

---

### Task 5: Slice list + download + delete endpoints

Three small endpoints in one task since they share patterns from Phase 8a.

**Files:**
- Modify: `src/api/handlers.zig` (3 new handlers)
- Modify: `src/api/server.zig` (3 new respond functions + dispatch arms)

- [ ] **Step 1: Add `handleProjectsSlicesList`**

```zig
pub const ListSlicesError = error{ NotFound, DbError, OutOfMemory };

pub fn handleProjectsSlicesList(
    gpa: std.mem.Allocator,
    db: *Db,
    project_id: []const u8,
) ListSlicesError![]slices_mod.Slice {
    var maybe = projects_mod.getById(db, gpa, project_id) catch return error.DbError;
    if (maybe == null) return error.NotFound;
    maybe.?.deinit(gpa);

    return slices_mod.listByProject(db, gpa, project_id) catch return error.DbError;
}
```

- [ ] **Step 2: Add `handleProjectsSlicesGet`**

Reuses the same `ChargesheetReadResult` pattern from 8a Task 7. Just reads a different file.

```zig
pub const GetSliceError = error{ NotFound, IoError, OutOfMemory, DbError, InvalidFilename };

pub fn handleProjectsSlicesGet(
    io: std.Io,
    gpa: std.mem.Allocator,
    db: *Db,
    data_dir: []const u8,
    project_id: []const u8,
    filename: []const u8,
) GetSliceError!ChargesheetReadResult {
    if (!project_dir.isSafeFilename(filename)) return error.InvalidFilename;

    var maybe = projects_mod.getById(db, gpa, project_id) catch return error.DbError;
    if (maybe == null) return error.NotFound;
    maybe.?.deinit(gpa);

    const path = project_dir.slicePath(gpa, data_dir, project_id, filename) catch return error.OutOfMemory;
    defer gpa.free(path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(100 * 1024 * 1024)) catch |err| {
        return switch (err) {
            error.FileNotFound => error.NotFound,
            error.OutOfMemory => error.OutOfMemory,
            else => error.IoError,
        };
    };
    errdefer gpa.free(bytes);

    const filename_owned = gpa.dupe(u8, filename) catch return error.OutOfMemory;
    return .{ .filename = filename_owned, .bytes = bytes };
}
```

- [ ] **Step 3: Add `handleProjectsSlicesDelete`**

```zig
pub const DeleteSliceError = error{ NotFound, DbError, IoError, InvalidFilename };

pub fn handleProjectsSlicesDelete(
    io: std.Io,
    gpa: std.mem.Allocator,
    db: *Db,
    data_dir: []const u8,
    project_id: []const u8,
    filename: []const u8,
) DeleteSliceError!void {
    if (!project_dir.isSafeFilename(filename)) return error.InvalidFilename;

    // Remove DB row first. If absent, 404.
    slices_mod.delete(db, project_id, filename) catch |err| {
        return switch (err) {
            error.NotFound => error.NotFound,
            else => error.DbError,
        };
    };

    // Remove file. Don't fail the request if the file is already missing.
    project_dir.removeSlice(io, gpa, data_dir, project_id, filename) catch |err| {
        if (err != error.FileNotFound) return error.IoError;
    };
}
```

- [ ] **Step 4: Add the 3 responders in `server.zig`**

```zig
fn respondProjectsSlicesList(
    gpa: std.mem.Allocator,
    db: *Db,
    request: *http.Server.Request,
    project_id: []const u8,
) !void {
    var list = handlers.handleProjectsSlicesList(gpa, db, project_id) catch |err| {
        return switch (err) {
            error.NotFound => respondError(request, .not_found, "NOT_FOUND", "Project not found"),
            else => respondError(request, .internal_server_error, "INTERNAL_ERROR", "Internal error"),
        };
    };
    defer slices_mod_in_server.deinitList(list, gpa);

    var buf: [16 * 1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try json.writeSliceListingArrayOpen(&w);
    for (list, 0..) |s, i| {
        if (i > 0) try w.writeAll(",");
        try json.writeSliceListingItem(&w, s.filename, s.start_page, s.end_page, s.size_bytes, s.created_at);
    }
    try json.writeSliceListingArrayClose(&w);
    const body = w.buffered();

    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/json" },
    } ++ cors_headers;
    try request.respond(body, .{ .status = .ok, .extra_headers = &headers });
}

fn respondProjectsSlicesGet(
    io: std.Io,
    gpa: std.mem.Allocator,
    db: *Db,
    request: *http.Server.Request,
    opts: ServeOptions,
    project_id: []const u8,
    filename: []const u8,
) !void {
    const result = handlers.handleProjectsSlicesGet(io, gpa, db, opts.data_dir, project_id, filename) catch |err| {
        const status: std.http.Status = switch (err) {
            error.NotFound => .not_found,
            error.InvalidFilename => .bad_request,
            else => .internal_server_error,
        };
        const code: []const u8 = switch (err) {
            error.NotFound => "NOT_FOUND",
            error.InvalidFilename => "INVALID_FILENAME",
            else => "INTERNAL_ERROR",
        };
        return respondError(request, status, code, "Slice not available");
    };
    defer result.deinit(gpa);

    // Sanitize filename for Content-Disposition the same way 8a Task 7 did.
    var cd_buf: [512]u8 = undefined;
    var cd_w = std.Io.Writer.fixed(&cd_buf);
    try cd_w.writeAll("inline; filename=\"");
    for (result.filename) |c| {
        if (c == '"' or c == '\\' or c < 0x20) try cd_w.writeByte('_') else try cd_w.writeByte(c);
    }
    try cd_w.writeAll("\"");
    const cd_value = cd_w.buffered();

    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "application/pdf" },
        .{ .name = "Content-Disposition", .value = cd_value },
    } ++ cors_headers;

    try request.respond(result.bytes, .{ .status = .ok, .extra_headers = &headers });
}

fn respondProjectsSlicesDelete(
    io: std.Io,
    gpa: std.mem.Allocator,
    db: *Db,
    request: *http.Server.Request,
    opts: ServeOptions,
    project_id: []const u8,
    filename: []const u8,
) !void {
    handlers.handleProjectsSlicesDelete(io, gpa, db, opts.data_dir, project_id, filename) catch |err| {
        const status: std.http.Status = switch (err) {
            error.NotFound => .not_found,
            error.InvalidFilename => .bad_request,
            else => .internal_server_error,
        };
        const code: []const u8 = switch (err) {
            error.NotFound => "NOT_FOUND",
            error.InvalidFilename => "INVALID_FILENAME",
            else => "INTERNAL_ERROR",
        };
        return respondError(request, status, code, "Slice not deleted");
    };
    try request.respond("", .{ .status = .no_content, .extra_headers = &cors_headers });
}
```

The `slices_mod_in_server.deinitList` reference: add at the top of `server.zig`:

```zig
const slices_mod_in_server = @import("../db/slices.zig");
```

(Or alias differently; the name's there to avoid shadowing other imports.)

Update dispatch:

```zig
.projects_slices_list => respondProjectsSlicesList(gpa, db, request, m.id orelse return respondNotFound(gpa, request)),
.projects_slices_get => respondProjectsSlicesGet(io, gpa, db, request, opts, m.id orelse return respondNotFound(gpa, request), m.child orelse return respondNotFound(gpa, request)),
.projects_slices_delete => respondProjectsSlicesDelete(io, gpa, db, request, opts, m.id orelse return respondNotFound(gpa, request), m.child orelse return respondNotFound(gpa, request)),
```

- [ ] **Step 5: Curl-test all 3 endpoints**

```bash
zig build
CHARGESHEET_DATA_DIR=/tmp/logos-task5-smoke rm -rf /tmp/logos-task5-smoke
CHARGESHEET_DATA_DIR=/tmp/logos-task5-smoke ./zig-out/bin/logos -p 7777 &
PID=$!
sleep 1

# Setup: project + 2 slices.
ID=$(curl -s -X POST http://localhost:7777/api/v1/projects \
  -F "name=SlicesEndpoint" \
  -F "chargesheet=@/Users/user/projects/mupdf-zig/tests/fixtures/sample-10pages.pdf" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
curl -s -X POST http://localhost:7777/api/v1/projects/$ID/jobs/slice \
  -H "Content-Type: application/json" \
  -d '{"slices":[{"start_page":1,"end_page":3,"filename":"intro.pdf"},{"start_page":4,"end_page":7,"filename":"body.pdf"}]}' > /dev/null

echo "=== List slices ==="
curl -s http://localhost:7777/api/v1/projects/$ID/slices | python3 -m json.tool

echo "=== Download intro.pdf ==="
curl -s -o /tmp/intro.pdf http://localhost:7777/api/v1/projects/$ID/slices/intro.pdf
file /tmp/intro.pdf
# Expect: PDF, 3 pages

echo "=== Delete body.pdf ==="
curl -s -i -X DELETE http://localhost:7777/api/v1/projects/$ID/slices/body.pdf | head -1

echo "=== List again (one slice gone) ==="
curl -s http://localhost:7777/api/v1/projects/$ID/slices | python3 -m json.tool

echo "=== Delete non-existent ==="
curl -s -i -X DELETE http://localhost:7777/api/v1/projects/$ID/slices/gone.pdf | head -1

echo "=== Path-traversal filename rejected ==="
curl -s -i http://localhost:7777/api/v1/projects/$ID/slices/..%2Fetc%2Fpasswd | head -1

kill $PID; wait $PID 2>/dev/null
```

Expected:
- List: 2 slices, intro.pdf + body.pdf.
- Download: 3-page PDF.
- Delete body: 204.
- List again: 1 slice (intro.pdf).
- Delete non-existent: 404.
- Path traversal: depends — the router rejects `/` in the path, so it'd be 404 not 400. That's fine, the URL-decoded form `..%2F...` is detected by the router OR by `isSafeFilename`. Acceptable.

- [ ] **Step 6: Commit**

```bash
git add src/api/
git commit -m "feat(api): slice list, download, and delete endpoints"
```

---

### Task 6: End-to-end UI smoke test

Same shape as Phase 8a Task 8. Run logos + the UI, click through the slicing flow, confirm everything works.

- [ ] **Step 1: Start logos**

```bash
cd /Users/user/projects/lambe-haath/logos
zig build
CHARGESHEET_DATA_DIR=/tmp/logos-8b-ui-smoke rm -rf /tmp/logos-8b-ui-smoke
CHARGESHEET_DATA_DIR=/tmp/logos-8b-ui-smoke ./zig-out/bin/logos -p 7777 &
echo "logos pid: $!"
```

- [ ] **Step 2: Start the UI**

In a separate shell:

```bash
cd /Users/user/projects/lambe-haath/chargesheet-ui
yarn dev
```

- [ ] **Step 3: Click through the slice flow**

In the browser at `http://localhost:5173/`:
1. Create a project (upload `sample-10pages.pdf`).
2. Open the project.
3. Define one or two slices (e.g. pages 1-3 as "intro.pdf", pages 4-10 as "body.pdf").
4. Submit. UI should show the job moving to completed (since we sync-execute, this happens fast).
5. Slices list should populate with both files.
6. Click a slice — UI's pdfjs renders the downloaded slice.
7. Delete a slice. It disappears.
8. Delete the project. Everything is gone (DB + filesystem).

If any step shows an error toast, debug via the browser's Network tab.

- [ ] **Step 4: Document the result**

Report back which flows work and which don't. No code commit unless you noted any UI issue + fixed it.

---

## Acceptance Criteria

- All 5 new endpoints return responses matching the UI's Zod schemas.
- POST /jobs/slice synchronously slices via mupdf-zig, writes files to `data_dir/<id>/slices/<filename>.pdf`, inserts a Job row, returns `{job_id, status:"queued"}` with 202.
- GET /jobs/:job_id returns the actual stored status (`completed` or `failed`).
- GET /slices lists current slices from the DB.
- GET /slices/:filename serves the file byte-for-byte.
- DELETE /slices/:filename removes both DB row and file.
- All ~75 unit tests still pass.
- UI smoke test (Task 6) creates + slices + downloads + deletes successfully.
- Path traversal rejected (`/`, `\`, `.`, `..`).
- Duplicate filenames in the same request rejected.

---

## Self-Review

**1. Spec coverage:** Each of the 5 endpoints has its own task or sub-step (Task 3 = slice; Task 4 = poll job; Task 5 = list/get/delete). The router extension is Task 1; the JSON helpers + filename validation are Task 2.

**2. Placeholder scan:** Code blocks in every step. Where Zig 0.16 APIs are uncertain (`std.json.parseFromSlice` signature), implementer is directed to verify against stdlib. No "TBD" or "similar to."

**3. Type consistency:**
- `Match` extended with `child: ?[]const u8` — used consistently from Task 1 onward.
- `SliceRequestBody`/`SliceRequestItem` declared in Task 3, not reused elsewhere.
- `Job` struct from `src/db/jobs.zig` used unchanged.
- `Slice` struct from `src/db/slices.zig` used unchanged.
- Error sets each get their own name (`SliceJobError`, `GetJobError`, `ListSlicesError`, `GetSliceError`, `DeleteSliceError`); no name collisions.

**4. Risk classification (Gate 4):** Bounded. Each slice op is in-process, sync, and contained. Failure path leaves a job row with `status=failed` — observable via the GET /jobs endpoint. Worst case: partial slice files on disk after a crash mid-execution; cleanup is best-effort.

**5. Epistemological humility (Gate 5):**
- Synchronous slicing inside HTTP handler blocks the accept loop for the duration. With single-threaded accept (Phase 8a), other requests wait. For large PDFs (100+ pages, 50MB+) this becomes a UX issue. Phase 8c can move slicing to a worker thread once we have multiple users.
- Each slice opens a fresh MuPDF Document because `slice()` mutates the in-memory doc. Could be optimized once Phase 8c sorts out per-job contexts.
- Job's `results` column stores raw JSON. If schemas drift, old rows decode wrong. We never schema-version them. Acceptable until we ship.
- `slices_mod.insert` already handles `UniqueViolation` so re-slicing the same filename works (file gets overwritten by `pdf_save_document`, DB row stays). Behavior matches the mock — `updatedSlices.findIndex` upserts.
