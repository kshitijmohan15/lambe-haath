# Daemon Serves UI From Disk — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The `logos` daemon serves the SvelteKit SPA from a `ui/` directory on disk (default `<exe_dir>/ui`, override `CHARGESHEET_UI_DIR`) alongside `/api/v1/*`, with SPA fallback to `index.html` and a path-traversal guard. No embedding, no build changes, daemon build stays node-free.

**Architecture:** A pure-ish `src/api/static.zig` resolves a request path to a file under `ui_dir` (MIME by extension, `..`-traversal guard, SPA fallback), unit-tested against a `std.testing.tmpDir` fixture. `config.zig` resolves `ui_dir` at startup. `server.zig` routes unmatched GET non-`/api` paths through `static.resolve` and reads the file from disk (the existing `readFileAlloc` pattern). `build.zig` is untouched.

**Tech Stack:** Zig 0.16 (`std.fs`/`std.Io.Dir`, `std.testing.tmpDir`, `std.fs.path`), the existing logos HTTP server. Spec: `docs/superpowers/specs/2026-05-27-daemon-serves-ui-design.md`.

**Branch:** `feat/daemon-serves-ui` (spec + this plan committed there; this revises the earlier embed-based versions).

---

## File Structure

```
logos/
├── src/
│   ├── config.zig          # MODIFIED: add ui_dir (CHARGESHEET_UI_DIR or <exe_dir>/ui)
│   ├── api/
│   │   ├── static.zig      # NEW: resolve(io,gpa,ui_dir,is_get,path) + mime + traversal guard + tests
│   │   └── server.zig      # MODIFIED: ServeOptions.ui_dir; dispatch not_found→static; respondFile/respondUiPlaceholder
│   └── main.zig            # MODIFIED: pass config.ui_dir into serve(); add static to test discovery
```

`build.zig` and `build.zig.zon` are **unchanged**. Boundaries: `static.zig` owns path→file resolution (testable against a temp dir); `config.zig` owns dir resolution; `server.zig` owns HTTP read+respond. Conventions: existing logos patterns (`std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(...))` from the chargesheet handler; `request.respond(body, .{...})`; `cors_headers`; exhaustive switches; `std.testing.tmpDir` from `project_dir.zig` tests).

---

### Task 1: `config.ui_dir` + `static.zig` (resolve/mime/traversal) + server dispatch

The whole feature except verifying with the real built UI. Node-free, TDD on the resolver.

**Files:**
- Modify: `src/config.zig`
- Create: `src/api/static.zig`
- Modify: `src/api/server.zig`
- Modify: `src/main.zig`

- [ ] **Step 1: Add `ui_dir` to `AppConfig` in `src/config.zig`**

Read the current `config.zig` first (it has `data_dir`, `load(gpa, env)`, `deinit`). Add a `ui_dir` field resolved from `CHARGESHEET_UI_DIR` or `<exe_dir>/ui`:

```zig
pub const AppConfig = struct {
    data_dir: []u8,
    ui_dir: []u8,

    pub fn load(gpa: std.mem.Allocator, env: *const std.process.Environ.Map) !AppConfig {
        const data_dir = try paths.getAppDataDir(gpa, env);
        errdefer gpa.free(data_dir);
        const ui_dir = try resolveUiDir(gpa, env);
        return .{ .data_dir = data_dir, .ui_dir = ui_dir };
    }

    pub fn deinit(self: *AppConfig, gpa: std.mem.Allocator) void {
        gpa.free(self.data_dir);
        gpa.free(self.ui_dir);
    }
};

/// CHARGESHEET_UI_DIR if set, else the directory containing the running
/// executable + "/ui". Caller owns the returned slice.
fn resolveUiDir(gpa: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    if (env.get("CHARGESHEET_UI_DIR")) |v| {
        if (v.len > 0) return gpa.dupe(u8, v);
    }
    const exe_dir = try std.fs.selfExeDirPathAlloc(gpa);
    defer gpa.free(exe_dir);
    return std.fs.path.join(gpa, &.{ exe_dir, "ui" });
}
```

NOTE: `std.fs.selfExeDirPathAlloc(gpa)` is the historical API; in Zig 0.16 the exe-dir helper may live under `std.fs` or require `std.Io`. Verify against the stdlib (`grep -rn "selfExeDir" ~/.zvm/0.16.0/lib/std`) and use the correct 0.16 call; the contract is "absolute path of the directory containing the running binary." The `env` type (`*const std.process.Environ.Map`) must match what `load` already takes — keep it identical to the existing signature.

- [ ] **Step 2: Write `src/api/static.zig` with tests FIRST**

```zig
//! Serve the web UI's static files from a directory on disk, with MIME by
//! extension, SPA fallback to index.html, and a path-traversal guard.
const std = @import("std");

pub const Served = union(enum) {
    /// Serve this file: read abs_path, respond 200 with `mime`. Caller frees abs_path.
    file: struct { abs_path: []u8, mime: []const u8 },
    /// No UI present (ui_dir missing / no index.html) — serve the dev placeholder.
    placeholder,
    /// Not a static concern (/api/* or non-GET) — caller decides (404 / API).
    not_handled,
};

pub fn mimeForPath(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    if (std.mem.eql(u8, ext, ".html")) return "text/html";
    if (std.mem.eql(u8, ext, ".js")) return "text/javascript";
    if (std.mem.eql(u8, ext, ".css")) return "text/css";
    if (std.mem.eql(u8, ext, ".json")) return "application/json";
    if (std.mem.eql(u8, ext, ".svg")) return "image/svg+xml";
    if (std.mem.eql(u8, ext, ".png")) return "image/png";
    if (std.mem.eql(u8, ext, ".ico")) return "image/x-icon";
    if (std.mem.eql(u8, ext, ".woff2")) return "font/woff2";
    if (std.mem.eql(u8, ext, ".webmanifest")) return "application/manifest+json";
    if (std.mem.eql(u8, ext, ".txt")) return "text/plain";
    return "application/octet-stream";
}

/// A URL path is safe iff none of its '/'-separated components is "", ".", or
/// "..", and it contains no '\' or NUL. Leading '/' is expected and ignored.
fn isSafeUrlPath(path: []const u8) bool {
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return false;
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return false;
    }
    return true;
}

/// Does `<dir>/<rel>` exist as a regular file?
fn fileExists(io: std.Io, dir: []const u8, rel: []const u8, gpa: std.mem.Allocator) !?[]u8 {
    const abs = try std.fs.path.join(gpa, &.{ dir, rel });
    errdefer gpa.free(abs);
    const f = std.Io.Dir.cwd().openFile(io, abs, .{ .mode = .read_only }) catch {
        gpa.free(abs);
        return null;
    };
    f.close(io);
    return abs; // caller owns
}

/// Resolve a request to a static file under `ui_dir`, with SPA fallback.
pub fn resolve(
    io: std.Io,
    gpa: std.mem.Allocator,
    ui_dir: []const u8,
    method_is_get: bool,
    path: []const u8,
) !Served {
    if (!method_is_get) return .not_handled;
    if (std.mem.startsWith(u8, path, "/api/")) return .not_handled;

    // ui_dir present?
    var d = std.Io.Dir.cwd().openDir(io, ui_dir, .{}) catch return .placeholder;
    d.close(io);

    // Try the exact (safe) file.
    if (isSafeUrlPath(path)) {
        const rel = if (std.mem.eql(u8, path, "/")) "index.html" else std.mem.trimLeft(u8, path, "/");
        if (try fileExists(io, ui_dir, rel, gpa)) |abs| {
            return .{ .file = .{ .abs_path = abs, .mime = mimeForPath(rel) } };
        }
    }

    // SPA fallback (also covers unsafe paths → never serves outside ui_dir).
    if (try fileExists(io, ui_dir, "index.html", gpa)) |abs| {
        return .{ .file = .{ .abs_path = abs, .mime = "text/html" } };
    }
    return .placeholder;
}

const testing = std.testing;

fn writeFixture(io: std.Io, dir: std.Io.Dir, rel: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(rel)) |sub| try dir.makePath(io, sub);
    var f = try dir.createFile(io, rel, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, bytes);
}

test "static.resolve against a fixture ui dir" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Build the cwd-relative path to the tmp dir (matches project_dir.zig test pattern).
    const ui_dir = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(ui_dir);

    try writeFixture(io, tmp.dir, "index.html", "<!doctype html>app");
    try writeFixture(io, tmp.dir, "_app/immutable/app.js", "console.log(1)");
    try writeFixture(io, tmp.dir, "styles.css", "body{}");

    // exact hit
    {
        var r = try resolve(io, gpa, ui_dir, true, "/_app/immutable/app.js");
        try testing.expect(r == .file);
        defer gpa.free(r.file.abs_path);
        try testing.expectEqualStrings("text/javascript", r.file.mime);
    }
    // root → index.html
    {
        var r = try resolve(io, gpa, ui_dir, true, "/");
        try testing.expect(r == .file);
        defer gpa.free(r.file.abs_path);
        try testing.expectEqualStrings("text/html", r.file.mime);
    }
    // unknown → SPA fallback to index.html
    {
        var r = try resolve(io, gpa, ui_dir, true, "/projects/abc");
        try testing.expect(r == .file);
        defer gpa.free(r.file.abs_path);
        try testing.expect(std.mem.endsWith(u8, r.file.abs_path, "index.html"));
    }
    // /api → not_handled
    try testing.expect((try resolve(io, gpa, ui_dir, true, "/api/v1/health")) == .not_handled);
    // non-GET → not_handled
    try testing.expect((try resolve(io, gpa, ui_dir, false, "/")) == .not_handled);
    // traversal → never escapes ui_dir (falls back to index.html within ui_dir)
    {
        var r = try resolve(io, gpa, ui_dir, true, "/../../../etc/passwd");
        try testing.expect(r == .file);
        defer gpa.free(r.file.abs_path);
        try testing.expect(std.mem.endsWith(u8, r.file.abs_path, "index.html"));
        try testing.expect(std.mem.indexOf(u8, r.file.abs_path, "etc/passwd") == null);
    }
}

test "static.resolve with missing ui dir → placeholder" {
    const gpa = testing.allocator;
    try testing.expect((try resolve(testing.io, gpa, "/nonexistent/ui/dir/xyz", true, "/")) == .placeholder);
}

test "mimeForPath coverage" {
    try testing.expectEqualStrings("text/javascript", mimeForPath("/x.js"));
    try testing.expectEqualStrings("image/png", mimeForPath("/favicon.png"));
    try testing.expectEqualStrings("application/octet-stream", mimeForPath("/weird.xyz"));
}
```

NOTE: verify the 0.16 stdlib calls against existing project code — `std.testing.tmpDir`, `tmp.sub_path`, `std.Io.Dir.cwd().openFile/openDir`, `dir.createFile`, `f.writeStreamingAll`, `dir.makePath` all appear in `src/storage/project_dir.zig` (and its tests) and `src/lock.zig`; mirror those exact signatures. The `.zig-cache/tmp/<sub_path>` reconstruction is the proven pattern from `project_dir.zig` tests. If `tokenizeScalar`/`trimLeft` names differ, adapt.

- [ ] **Step 3: Run static tests**

Add `_ = @import("api/static.zig");` to `src/main.zig`'s `test {}` block, then:
```bash
cd /Users/user/projects/lambe-haath/logos
zig build test --summary all 2>&1 | grep -E "tests passed|error"
```
Expected: 75 prior + 3 new static tests = **78/78**, node-free.

- [ ] **Step 4: Wire `ui_dir` through `ServeOptions` + dispatch in `src/api/server.zig`**

Add import: `const static = @import("static.zig");`

Add `ui_dir` to `ServeOptions`:
```zig
pub const ServeOptions = struct {
    port: u16,
    version: []const u8,
    data_dir: []const u8,
    ui_dir: []const u8,
};
```

Replace the `.not_found` switch arm:
```zig
.not_found => {
    const served = static.resolve(io, gpa, opts.ui_dir, request.head.method == .GET, target) catch
        return respondNotFound(gpa, request);
    switch (served) {
        .file => |f| {
            defer gpa.free(f.abs_path);
            try respondFile(io, gpa, request, f.abs_path, f.mime);
        },
        .placeholder => try respondUiPlaceholder(request, opts.ui_dir),
        .not_handled => try respondNotFound(gpa, request),
    }
},
```

Add the responders (reuse the chargesheet read pattern):
```zig
fn respondFile(io: std.Io, gpa: std.mem.Allocator, request: *http.Server.Request, abs_path: []const u8, mime: []const u8) !void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, abs_path, gpa, .limited(100 * 1024 * 1024)) catch
        return respondNotFound(gpa, request);
    defer gpa.free(bytes);
    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = mime },
    } ++ cors_headers;
    try request.respond(bytes, .{ .status = .ok, .extra_headers = &headers });
}

fn respondUiPlaceholder(request: *http.Server.Request, ui_dir: []const u8) !void {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.print(
        "logos daemon is running, but no web UI was found at:\n  {s}\n\n" ++
        "Build it (cd chargesheet-ui && yarn build) and set CHARGESHEET_UI_DIR to that build/ dir,\n" ++
        "or run the dev UI: cd chargesheet-ui && yarn dev (http://localhost:5173).\n",
        .{ui_dir},
    );
    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "text/plain" },
    } ++ cors_headers;
    try request.respond(w.buffered(), .{ .status = .ok, .extra_headers = &headers });
}
```

`io` is already a parameter of `serveRequest` (threaded in Phase 8b). `readFileAlloc` / `.limited(...)` matches the chargesheet handler — verify the exact call there and mirror it.

- [ ] **Step 5: Pass `config.ui_dir` from `src/main.zig`**

Find the `api_server.serve(io, gpa, &db, .{ ... })` call and add `.ui_dir = config.data_dir`-style field:
```zig
try api_server.serve(io, gpa, &db, .{
    .port = port,
    .version = version,
    .data_dir = config.data_dir,
    .ui_dir = config.ui_dir,
});
```

- [ ] **Step 6: Build + full test run + placeholder smoke**

```bash
cd /Users/user/projects/lambe-haath/logos
zig build test --summary all 2>&1 | grep -E "tests passed"   # 78/78, node-free
zig build
CHARGESHEET_DATA_DIR=/tmp/logos-ui-disk rm -rf /tmp/logos-ui-disk
CHARGESHEET_DATA_DIR=/tmp/logos-ui-disk CHARGESHEET_UI_DIR=/tmp/definitely-no-ui ./zig-out/bin/logos -p 7777 &
P=$!; sleep 1
echo "=== / placeholder ==="; curl -s -i http://localhost:7777/ | head -8
echo "=== /api/v1/health still JSON ==="; curl -s http://localhost:7777/api/v1/health
echo "=== /api unknown still JSON 404 ==="; curl -s -i http://localhost:7777/api/v1/nope | head -1
kill $P; wait $P 2>/dev/null
```
Expected: `/` → 200 text/plain placeholder naming the missing dir; health → JSON; `/api/v1/nope` → 404 JSON (NOT the placeholder).

- [ ] **Step 7: Commit**

```bash
cd /Users/user/projects/lambe-haath
git add logos/src/config.zig logos/src/api/static.zig logos/src/api/server.zig logos/src/main.zig
git commit -m "feat(api): serve web UI from disk (ui_dir, MIME, SPA fallback, traversal guard)"
```

---

### Task 2: Verify serving the real built UI from disk

No code — prove the daemon serves the actual SvelteKit build, end to end.

- [ ] **Step 1: Build the UI**

```bash
cd /Users/user/projects/lambe-haath/chargesheet-ui
yarn install --frozen-lockfile 2>&1 | tail -2
yarn build 2>&1 | tail -5
ls build/ | head   # expect index.html, _app/, favicon.png, etc.
```

- [ ] **Step 2: Run the daemon pointed at the build dir**

```bash
cd /Users/user/projects/lambe-haath/logos
CHARGESHEET_DATA_DIR=/tmp/logos-ui-real rm -rf /tmp/logos-ui-real
CHARGESHEET_DATA_DIR=/tmp/logos-ui-real \
CHARGESHEET_UI_DIR="$HOME/projects/lambe-haath/chargesheet-ui/build" \
  ./zig-out/bin/logos -p 7777 &
P=$!; sleep 1

echo "=== / returns SvelteKit HTML ==="; curl -s http://localhost:7777/ | head -c 200; echo
echo "=== an _app JS asset 200 + mime ==="
ASSET=$(curl -s http://localhost:7777/ | grep -oE '/_app/[^"]+\.js' | head -1)
echo "asset: $ASSET"; curl -s -o /dev/null -w "%{http_code} %{content_type}\n" "http://localhost:7777$ASSET"
echo "=== deep link → index.html (SPA) ==="; curl -s http://localhost:7777/projects/xyz | head -c 60; echo
echo "=== /api/v1/health still JSON ==="; curl -s http://localhost:7777/api/v1/health
echo "=== traversal blocked ==="; curl -s -o /dev/null -w "%{http_code}\n" "http://localhost:7777/../../../etc/passwd"
kill $P; wait $P 2>/dev/null
```
Expected: `/` → `<!doctype html>...`; the `_app/*.js` → `200 text/javascript`; `/projects/xyz` → index.html; health → JSON; the traversal path returns 200 (index.html via fallback) and never `/etc/passwd` contents.

- [ ] **Step 3: Browser check**

Open `http://localhost:7777` in a browser. Confirm the app loads and drives the API (create/list a project) entirely from the daemon — with NO `yarn dev` running. Note the result.

- [ ] **Step 4: Document the run command**

Append to `docs/superpowers/research/2026-05-27-zig-packaging-research.md` a short note under a "## Daemon-serves-UI (disk)" heading: the daemon serves the UI from `CHARGESHEET_UI_DIR` (default `<exe_dir>/ui`); the installer (#3) builds the UI and places it at `<exe_dir>/ui`. Commit:
```bash
cd /Users/user/projects/lambe-haath
git add logos/docs/superpowers/research/2026-05-27-zig-packaging-research.md
git commit -m "docs: note daemon-serves-UI-from-disk run command for installer phase"
```

---

## Acceptance Criteria

- `zig build test` passes node-free; `static.resolve` unit-tested incl. exact hit, root→index, SPA fallback, `/api` not-handled, non-GET not-handled, traversal-blocked, missing-dir→placeholder.
- Daemon with `CHARGESHEET_UI_DIR` → built `build/` serves the SPA: `/` + deep links → index.html, assets → correct bytes + MIME, `/api/*` unchanged.
- A traversal request never reads outside `ui_dir`.
- No `ui/` present → placeholder note; API still works.
- `build.zig` unchanged; no node dependency in the daemon build.

## Self-Review

**1. Spec coverage:** ui_dir resolution (Task 1 Step 1) ✓; static.zig resolve+mime+traversal (Step 2) ✓; server dispatch + respondFile + placeholder (Step 4) ✓; main wiring (Step 5) ✓; real-UI verification + traversal-blocked check (Task 2) ✓; node-free build (Steps 3,6) ✓; browser-free unit tests via tmpDir fixture (Step 2) ✓; build.zig untouched ✓.

**2. Placeholder scan:** No "TBD". The 0.16-sensitive stdlib calls (`selfExeDirPathAlloc`, `tmpDir`/`sub_path`, `Io.Dir` open/create/read, `writeStreamingAll`, `readFileAlloc .limited`, `tokenizeScalar`) are each flagged "mirror the existing pattern in project_dir.zig / lock.zig / the chargesheet handler" with the concrete contract — directives citing in-repo precedents, not gaps.

**3. Type consistency:** `Served` union (`file{abs_path,mime}`/`placeholder`/`not_handled`), `resolve(io,gpa,ui_dir,is_get,path)`, `mimeForPath`, `isSafeUrlPath`, `fileExists` — consistent between static.zig and server's dispatch. `ServeOptions.ui_dir` (Step 4) ↔ `config.ui_dir` passed in main (Step 5) ↔ `AppConfig.ui_dir` (Step 1). `respondFile`/`respondUiPlaceholder` defined where used.

## Deferred (#3 / later)

- Installer builds the UI in CI + places it at `<exe_dir>/ui`; cross-platform install script.
- Caching/compression headers; in-memory file caching.
