# Daemon Serves Embedded UI — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The `logos` daemon serves the SvelteKit SPA from its own binary on `:7777` alongside `/api/v1/*`, gated behind a `-Dembed-ui` build option (default false) so the test suite + backend dev stay node-free while CI/release builds embed the UI into one self-contained binary.

**Architecture:** A pure `src/api/static.zig` unit owns asset lookup + MIME + the serve-vs-fallback decision (unit-tested with a fake map, no browser/build needed). `build.zig` always wires an `assets` named import onto the exe module — an empty committed stub when `embed-ui=false`, or a build-time-generated manifest (`yarn build` → a generator walks the output → emits `manifest.zig` that `@embedFile`s each asset) when `embed-ui=true`. `server.zig` routes unmatched GET non-`/api` paths through `static` with SPA fallback to `index.html`.

**Tech Stack:** Zig 0.16 (`b.option`, `b.addOptions`, `addRunArtifact`, `@embedFile`, `std.StaticStringMap`), the existing logos HTTP server, the `chargesheet-ui` SvelteKit `adapter-static` SPA. Spec: `docs/superpowers/specs/2026-05-27-daemon-serves-ui-design.md`.

**Branch:** Work happens on `feat/daemon-serves-ui` (already created; spec committed there).

---

## File Structure

```
logos/
├── build.zig                # MODIFIED: -Dembed-ui option, build_options, wire `assets` import (stub or generated)
├── src/api/
│   ├── static.zig           # NEW: Asset, MIME table, lookup/resolve (pure) + unit tests
│   ├── assets_empty.zig     # NEW: committed empty-map stub (used when embed-ui=false)
│   └── server.zig           # MODIFIED: route unmatched GET non-/api through static + SPA fallback
├── src/main.zig             # MODIFIED: add static + assets to the test-discovery block
└── tools/
    └── gen_assets.zig       # NEW (Task 2): build-time generator — walks the yarn build dir, emits manifest.zig
```

Boundaries: `static.zig` is pure (map → response decision), independently testable. `assets_empty.zig` / the generated manifest are interchangeable providers of `pub const map: std.StaticStringMap([]const u8)`. `gen_assets.zig` is a standalone build tool. `server.zig` only gains a dispatch arm.

Conventions: established logos patterns — `std.Io.Writer.fixed`, `request.respond(body, .{ .status, .extra_headers })`, `cors_headers`, exhaustive switches. No `@cImport`. Tests via `std.testing` pulled into discovery from `main.zig`'s `test {}` block.

---

### Task 1: `static.zig` + `-Dembed-ui` option + stub + routing (node-free, fully tested)

Everything except the actual `yarn build` embed. Delivers the node-free default path, the complete static-serving logic under unit test, and the daemon serving a placeholder at `/`.

**Files:**
- Create: `src/api/static.zig`
- Create: `src/api/assets_empty.zig`
- Modify: `build.zig`
- Modify: `src/api/server.zig`
- Modify: `src/main.zig`

- [ ] **Step 1: Create the empty-map stub `src/api/assets_empty.zig`**

```zig
//! Empty asset map — used when the daemon is built without -Dembed-ui.
//! The generated manifest (Task 2) exposes the same `map` symbol when embedding.
const std = @import("std");

pub const map = std.StaticStringMap([]const u8).initComptime(.{});
```

- [ ] **Step 2: Write `src/api/static.zig` with tests FIRST (TDD)**

```zig
//! Static web-asset serving: maps request paths to embedded bytes + MIME,
//! with SPA fallback to index.html. Pure logic — the asset map is injected
//! (via the `assets` module in prod, or a fixture in tests).
const std = @import("std");
const assets = @import("assets"); // provides `pub const map: std.StaticStringMap([]const u8)`

pub const Asset = struct {
    bytes: []const u8,
    mime: []const u8,
};

/// What the server should do with a request, from the static layer's POV.
pub const Resolution = union(enum) {
    asset: Asset, // serve these bytes + mime, 200
    placeholder, // embed-ui=false (empty map): serve the dev note
    not_handled, // not a static concern (e.g. /api/* or non-GET) — caller decides (404/api)
};

/// MIME for a path's extension. Covers what a SvelteKit `adapter-static` build emits.
pub fn mimeForPath(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path); // includes the dot, e.g. ".js"
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

/// Pure resolution against an injected map — the unit-tested core.
pub fn resolveIn(m: std.StaticStringMap([]const u8), method_is_get: bool, path: []const u8) Resolution {
    if (!method_is_get) return .not_handled;
    if (std.mem.startsWith(u8, path, "/api/")) return .not_handled;
    if (m.values().len == 0) return .placeholder;

    const key = if (std.mem.eql(u8, path, "/")) "/index.html" else path;
    if (m.get(key)) |bytes| return .{ .asset = .{ .bytes = bytes, .mime = mimeForPath(key) } };
    // SPA fallback: any other GET path serves index.html for client-side routing.
    if (m.get("/index.html")) |bytes| return .{ .asset = .{ .bytes = bytes, .mime = "text/html" } };
    return .placeholder;
}

/// Production entry point — resolves against the build-provided asset map.
pub fn resolve(method_is_get: bool, path: []const u8) Resolution {
    return resolveIn(assets.map, method_is_get, path);
}

const testing = std.testing;

const fake_map = std.StaticStringMap([]const u8).initComptime(.{
    .{ "/index.html", "<!doctype html><body>app</body>" },
    .{ "/_app/immutable/app.js", "console.log(1)" },
    .{ "/favicon.png", "PNGDATA" },
    .{ "/styles.css", "body{}" },
});

test "mimeForPath covers the SvelteKit set" {
    try testing.expectEqualStrings("text/html", mimeForPath("/index.html"));
    try testing.expectEqualStrings("text/javascript", mimeForPath("/x.js"));
    try testing.expectEqualStrings("text/css", mimeForPath("/x.css"));
    try testing.expectEqualStrings("image/png", mimeForPath("/favicon.png"));
    try testing.expectEqualStrings("application/octet-stream", mimeForPath("/weird.xyz"));
}

test "resolveIn: exact asset hit returns bytes + mime" {
    const r = resolveIn(fake_map, true, "/_app/immutable/app.js");
    try testing.expect(r == .asset);
    try testing.expectEqualStrings("console.log(1)", r.asset.bytes);
    try testing.expectEqualStrings("text/javascript", r.asset.mime);
}

test "resolveIn: root normalizes to index.html" {
    const r = resolveIn(fake_map, true, "/");
    try testing.expect(r == .asset);
    try testing.expectEqualStrings("<!doctype html><body>app</body>", r.asset.bytes);
    try testing.expectEqualStrings("text/html", r.asset.mime);
}

test "resolveIn: unknown path falls back to index.html (SPA)" {
    const r = resolveIn(fake_map, true, "/projects/abc123");
    try testing.expect(r == .asset);
    try testing.expectEqualStrings("<!doctype html><body>app</body>", r.asset.bytes);
    try testing.expectEqualStrings("text/html", r.asset.mime);
}

test "resolveIn: /api paths are not_handled (left to the API/404)" {
    try testing.expect(resolveIn(fake_map, true, "/api/v1/health") == .not_handled);
}

test "resolveIn: non-GET is not_handled" {
    try testing.expect(resolveIn(fake_map, false, "/") == .not_handled);
}

test "resolveIn: empty map returns placeholder" {
    const empty = std.StaticStringMap([]const u8).initComptime(.{});
    try testing.expect(resolveIn(empty, true, "/") == .placeholder);
}
```

NOTE: `m.values().len` is the way to test emptiness on `std.StaticStringMap` in 0.16; if that field/method differs, use whatever exposes the entry count (e.g. `m.keys().len`). Verify against `lib/std/static_string_map.zig`.

- [ ] **Step 3: Wire `-Dembed-ui`, `build_options`, and the `assets` import in `build.zig`**

In `build()`, after `target`/`optimize`:

```zig
const embed_ui = b.option(bool, "embed-ui", "Build + embed the chargesheet-ui SPA into the daemon (requires node/yarn)") orelse false;

const build_opts = b.addOptions();
build_opts.addOption(bool, "embed_ui", embed_ui);

// The `assets` module: empty stub by default; Task 2 replaces this branch with the generated manifest when embed_ui.
const assets_mod = b.createModule(.{
    .root_source_file = b.path("src/api/assets_empty.zig"),
    .target = target,
    .optimize = optimize,
});
```

Add both to the exe's root module imports (alongside `logos`, `zqlite`, `mupdf`):

```zig
.imports = &.{
    .{ .name = "logos", .module = mod },
    .{ .name = "zqlite", .module = zqlite_dep.module("zqlite") },
    .{ .name = "mupdf", .module = mupdf_zig_dep.module("mupdf") },
    .{ .name = "assets", .module = assets_mod },
    .{ .name = "build_options", .module = build_opts.createModule() },
},
```

The exe's test executable (`exe_tests`, root_module = `exe.root_module`) inherits these imports, so `static.zig`'s `@import("assets")` + the daemon's `@import("build_options")` resolve in tests too (with the empty stub).

- [ ] **Step 4: Add static dispatch + placeholder to `src/api/server.zig`**

Add the import at the top:
```zig
const static = @import("static.zig");
```

In `serveRequest`'s switch, replace the `.not_found => respondNotFound(gpa, request)` arm so unmatched GET non-`/api` paths try static:

```zig
.not_found => {
    switch (static.resolve(request.head.method == .GET, target)) {
        .asset => |a| try respondAsset(request, a),
        .placeholder => try respondUiPlaceholder(request),
        .not_handled => try respondNotFound(gpa, request),
    }
},
```

(All the other arms — health, cors_preflight, projects_*, jobs_*, slices_* — stay exactly as they are.)

Add the two responders:

```zig
fn respondAsset(request: *http.Server.Request, a: static.Asset) !void {
    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = a.mime },
    } ++ cors_headers;
    try request.respond(a.bytes, .{ .status = .ok, .extra_headers = &headers });
}

fn respondUiPlaceholder(request: *http.Server.Request) !void {
    const body =
        "logos daemon is running. The web UI is not embedded in this build.\n" ++
        "Build with -Dembed-ui=true, or run the dev UI: cd chargesheet-ui && yarn dev (http://localhost:5173).\n";
    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "text/plain" },
    } ++ cors_headers;
    try request.respond(body, .{ .status = .ok, .extra_headers = &headers });
}
```

- [ ] **Step 5: Add static tests to discovery in `src/main.zig`**

In the trailing `test {}` block, add:
```zig
    _ = @import("api/static.zig");
```

- [ ] **Step 6: Build + run tests (node-free default)**

```bash
cd /Users/user/projects/lambe-haath/logos
zig build test --summary all 2>&1 | grep -E "tests passed|error"
```
Expected: 75 prior + 7 new static tests = **82/82**, with NO yarn/node invoked (default `embed-ui=false`).

- [ ] **Step 7: Smoke-test the placeholder path**

```bash
zig build
CHARGESHEET_DATA_DIR=/tmp/logos-ui-stub rm -rf /tmp/logos-ui-stub
CHARGESHEET_DATA_DIR=/tmp/logos-ui-stub ./zig-out/bin/logos -p 7777 &
P=$!; sleep 1
echo "=== / (placeholder) ==="; curl -s -i http://localhost:7777/ | head -8
echo "=== /api/v1/health still JSON ==="; curl -s http://localhost:7777/api/v1/health
echo "=== /api unknown still JSON 404 ==="; curl -s -i http://localhost:7777/api/v1/nope | head -1
kill $P; wait $P 2>/dev/null
```
Expected: `/` → 200 text/plain placeholder note; `/api/v1/health` → `{"status":"ok",...}`; `/api/v1/nope` → 404 JSON (NOT the placeholder — `/api/*` is `not_handled` by static, so it still hits `respondNotFound`).

- [ ] **Step 8: Commit**

```bash
cd /Users/user/projects/lambe-haath
git add logos/src/api/static.zig logos/src/api/assets_empty.zig logos/build.zig logos/src/api/server.zig logos/src/main.zig
git commit -m "feat(api): static asset serving + -Dembed-ui option (empty stub default)"
```

---

### Task 2: `yarn build` → embed the real UI (`-Dembed-ui=true`)

The build-time generator + wiring that turns the SvelteKit build into the `assets` module. Verified by serving the real SPA.

**Files:**
- Create: `tools/gen_assets.zig`
- Modify: `build.zig`

- [ ] **Step 1: Write the generator `tools/gen_assets.zig`**

A standalone Zig program: argv = `<input-build-dir> <output-dir>`. It recursively copies every file from the SvelteKit build dir into `<output-dir>` (preserving relative paths) and writes `<output-dir>/manifest.zig` exposing `pub const map` — a `StaticStringMap` of request-path → `@embedFile(<relative-path>)`. Because the manifest AND the assets live in the same output dir, `@embedFile` resolves relative to the manifest when the daemon compiles it.

```zig
const std = @import("std");

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var args = try std.process.argsAlloc(arena);
    if (args.len != 3) {
        std.debug.print("usage: gen_assets <input-build-dir> <output-dir>\n", .{});
        std.process.exit(2);
    }
    const in_dir_path = args[1];
    const out_dir_path = args[2];

    var in_dir = try std.fs.cwd().openDir(in_dir_path, .{ .iterate = true });
    defer in_dir.close();
    try std.fs.cwd().makePath(out_dir_path);
    var out_dir = try std.fs.cwd().openDir(out_dir_path, .{});
    defer out_dir.close();

    // Collect relative file paths.
    var rels = std.ArrayList([]const u8){};
    var walker = try in_dir.walk(arena);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        const rel = try arena.dupe(u8, entry.path); // path relative to in_dir
        // copy file into out_dir preserving structure
        if (std.fs.path.dirname(rel)) |d| try out_dir.makePath(d);
        try in_dir.copyFile(rel, out_dir, rel, .{});
        try rels.append(arena, rel);
    }

    // Write manifest.zig.
    var manifest = try out_dir.createFile("manifest.zig", .{});
    defer manifest.close();
    var buf: [4096]u8 = undefined;
    var fw = manifest.writer(&buf); // adapt to 0.16 File.writer signature
    const w = &fw.interface;
    try w.writeAll("const std = @import(\"std\");\npub const map = std.StaticStringMap([]const u8).initComptime(.{\n");
    for (rels.items) |rel| {
        // request path: "/" + rel, with backslashes normalized to "/"
        try w.writeAll("    .{ \"/");
        for (rel) |c| try w.writeByte(if (c == '\\') '/' else c);
        try w.writeAll("\", @embedFile(\"");
        for (rel) |c| try w.writeByte(if (c == '\\') '/' else c);
        try w.writeAll("\") },\n");
    }
    try w.writeAll("});\n");
    try w.flush();
}
```

NOTE: the `std.ArrayList`/`File.writer`/`Dir.walk`/`copyFile` calls are Zig-0.16-sensitive. Verify each against the stdlib and adapt: `std.ArrayList([]const u8){}` may need `= .empty`; `manifest.writer(&buf)` returns a `File.Writer` whose `.interface` is the `*std.Io.Writer` (mirror the pattern already used in `logos/src/lock.zig` / wherever the project writes files). The contract: copy all files + emit a compilable `manifest.zig` with one `@embedFile` per file, keyed by URL path.

- [ ] **Step 2: Wire the embed path in `build.zig`**

Replace the Task-1 `assets_mod` block with a conditional: stub when `!embed_ui`, generated manifest when `embed_ui`.

```zig
const assets_mod = blk: {
    if (!embed_ui) {
        break :blk b.createModule(.{
            .root_source_file = b.path("src/api/assets_empty.zig"),
            .target = target,
            .optimize = optimize,
        });
    }

    // 1. yarn build → chargesheet-ui/build
    const yarn = b.addSystemCommand(&.{ "yarn", "--cwd", "chargesheet-ui", "build" });
    // (If yarn isn't found, the build fails loudly — intended: embed-ui requires node/yarn.)

    // 2. Run the generator: gen_assets <build-dir> <out-dir>
    const gen_exe = b.addExecutable(.{
        .name = "gen_assets",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_assets.zig"),
            .target = b.graph.host, // generator runs on the BUILD host, not the cross target
            .optimize = .Debug,
        }),
    });
    const gen = b.addRunArtifact(gen_exe);
    gen.step.dependOn(&yarn.step); // generator runs after yarn build
    gen.addArg(b.pathFromRoot("chargesheet-ui/build")); // input dir (produced by yarn)
    const out = gen.addOutputDirectoryArg("ui-assets"); // make-dependent LazyPath to the generated dir

    break :blk b.createModule(.{
        .root_source_file = out.path(b, "manifest.zig"),
        .target = target,
        .optimize = optimize,
    });
};
```

Key points the implementer must get right (mirror the proven MuPDF make-step pattern from `mupdf-zig/build.zig`):
- `gen.addOutputDirectoryArg("ui-assets")` returns a `LazyPath` that **carries a dependency on the generator Run step**, so the daemon's compile waits for generation. The manifest module's `root_source_file = out.path(b, "manifest.zig")` inherits that dependency — no manual `dependOn` on the exe needed.
- The generator exe targets `b.graph.host` (runs on the build machine), independent of the daemon's cross-compile target.
- `yarn --cwd chargesheet-ui build` writes to `chargesheet-ui/build`; pass that as the generator's input. (If yarn's `--cwd` flag differs, use `cd chargesheet-ui && yarn build` via a shell, or `b.addSystemCommand` with `setCwd`.) Verify yarn is the right invocation (`yarn build` per package.json scripts).

- [ ] **Step 3: Build with the UI embedded**

```bash
cd /Users/user/projects/lambe-haath/logos
# ensure UI deps are installed once (build machine only):
( cd ../chargesheet-ui && yarn install --frozen-lockfile 2>&1 | tail -2 )
zig build -Dembed-ui=true 2>&1 | tail -20
```
Expected: yarn build runs, gen_assets emits the manifest, the daemon links with the embedded assets. Clean build.

- [ ] **Step 4: Smoke-test serving the real UI**

```bash
CHARGESHEET_DATA_DIR=/tmp/logos-ui-real rm -rf /tmp/logos-ui-real
CHARGESHEET_DATA_DIR=/tmp/logos-ui-real ./zig-out/bin/logos -p 7777 &
P=$!; sleep 1
echo "=== / returns SvelteKit HTML ==="; curl -s http://localhost:7777/ | head -c 200; echo
echo "=== an app JS asset ==="; curl -s -i "$(curl -s http://localhost:7777/ | grep -oE '/_app/[^"]+\.js' | head -1)" -o /dev/null -w "%{http_code} %{content_type}\n" --url "http://localhost:7777$(curl -s http://localhost:7777/ | grep -oE '/_app/[^\"]+\.js' | head -1)"
echo "=== deep link returns index.html (SPA) ==="; curl -s http://localhost:7777/projects/xyz | head -c 60; echo
echo "=== /api/v1/health still JSON ==="; curl -s http://localhost:7777/api/v1/health
kill $P; wait $P 2>/dev/null
```
Expected: `/` → SvelteKit HTML (`<!doctype html>...`); the `_app/*.js` asset → `200 text/javascript`; `/projects/xyz` → the same index.html (SPA fallback); `/api/v1/health` → JSON. Then open `http://localhost:7777` in a browser and confirm the app loads and drives the API (create/list a project) entirely from the daemon — no `yarn dev` running.

- [ ] **Step 5: Confirm the default build is still node-free**

```bash
zig build test --summary all 2>&1 | grep -E "tests passed"  # 82/82, no yarn invoked
```

- [ ] **Step 6: Commit**

```bash
cd /Users/user/projects/lambe-haath
git add logos/tools/gen_assets.zig logos/build.zig
git commit -m "feat(api): embed + serve the SvelteKit UI under -Dembed-ui=true"
```

---

## Acceptance Criteria

- `zig build test` passes with **no node/yarn dependency** (default `embed-ui=false`): 82/82 (75 daemon + 7 static).
- `static.resolveIn` is fully unit-tested (exact hit, root→index, SPA fallback, `/api` not-handled, non-GET not-handled, empty→placeholder) with a fixture map — no browser/build.
- `zig build -Dembed-ui=true` runs `yarn build`, embeds the output, and the daemon serves the SPA: `/` + deep links → `index.html`, asset paths → correct bytes + MIME, `/api/*` unchanged.
- The `-Dembed-ui=true` binary is one self-contained file (no UI directory needed at runtime).
- Default (stub) build serves the placeholder note at `/` and leaves `/api/*` behavior identical.

## Self-Review

**1. Spec coverage:** `-Dembed-ui` option + default-false (Task 1 Step 3) ✓; `static.zig` with MIME + lookup (Task 1 Step 2) ✓; routing + SPA fallback + placeholder (Task 1 Step 4) ✓; `yarn build` + embed via generator (Task 2) ✓; node-free test suite (Task 1 Step 6, Task 2 Step 5) ✓; unit tests not needing a browser (Task 1 Step 2) ✓; CORS retained (responders use `++ cors_headers`) ✓. The generator-after-build mechanism (the spec's one fiddly point) is Task 2 Steps 1-2 with the proven output-dir-LazyPath dependency pattern.

**2. Placeholder scan:** No "TBD". The Zig-0.16-sensitive calls (`StaticStringMap.values().len`, `File.writer`, `Dir.walk`, `ArrayList` init, `addOutputDirectoryArg`) are each flagged with "verify against stdlib / mirror existing project pattern" + the concrete contract — directives, not gaps. The proven precedents are cited (the MuPDF make-step output-dir-LazyPath in `mupdf-zig/build.zig`; file-writing in `lock.zig`).

**3. Type consistency:** `Asset { bytes, mime }`, `Resolution` union (`asset`/`placeholder`/`not_handled`), `resolveIn`/`resolve`/`mimeForPath`, `assets.map` (StaticStringMap) — consistent between `static.zig`, `server.zig`'s dispatch, and the generated/stub modules (both expose `pub const map`). The `assets` + `build_options` named imports are wired on the exe module in Task 1 Step 3 and consumed in `static.zig`.

## Deferred (later / #3)

- CI matrix build + GitHub Releases + cross-platform install script — consumes this phase's `-Dembed-ui=true` binary.
- Asset `Cache-Control`/`ETag`/`Content-Encoding: gzip` (SvelteKit can `precompress`) — defer until perf matters.
- The `build_options.embed_ui` bool is wired but the daemon currently infers "no UI" from the empty map; keep the option for an explicit startup log line if desired later.
