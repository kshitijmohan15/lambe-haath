# Design: Daemon serves the web UI from disk

**Date:** 2026-05-27 (revised — switched from embed to disk-serve)
**Status:** Approved (brainstorming) — ready for implementation plan
**Context:** Phase "#2 — daemon serves the bundled UI" toward the single-CLI product. Distribution model is **Model B**: prebuilt per-platform binaries + the UI built in CI; the installer places both on the user's machine (user installs nothing). See `docs/superpowers/research/2026-05-27-zig-packaging-research.md`.

---

## Goal

The `logos` daemon serves the SvelteKit SPA (`chargesheet-ui`) over HTTP on `:7777` alongside `/api/v1/*`, **reading the built UI files from a directory on disk at request time**. The installer lays the built UI next to the binary; the user opens `http://localhost:7777` and uses the tool — no separate `yarn dev`, no embedding.

The UI is a pure SPA (`adapter-static`, `fallback: 'index.html'`, `ssr=false`, `prerender=false`): `yarn build` emits a static `build/` dir; unknown routes resolve to `index.html` for client-side routing.

**Why disk-serve, not embed:** serving static files from the daemon process is the standard pattern for local/self-hosted tools (PocketBase, Gitea, Syncthing, Ollama UIs). Embedding into the binary (`@embedFile` + a generator) was considered and rejected as unnecessary build complexity — the installer can place a `ui/` directory beside the binary just as easily as a single file, and disk-serve keeps `build.zig` untouched and the daemon build node-free.

## UI directory resolution

A new `ui_dir` on `AppConfig`:
- **Default:** the directory containing the running `logos` executable + `/ui` (i.e. `<exe_dir>/ui`). The installer drops the built UI there, beside the binary.
- **Override:** env var `CHARGESHEET_UI_DIR` (mirrors the existing `CHARGESHEET_DATA_DIR`). Dev points it at `chargesheet-ui/build` after a `yarn build`.

Resolved once at startup in `config.zig`, alongside `data_dir`.

## Components

- **`src/config.zig`** — add `ui_dir: []u8` to `AppConfig`, resolved from `CHARGESHEET_UI_DIR` or `<exe_dir>/ui`.
- **`src/api/static.zig`** (NEW) — the static-serving unit:
  - `mimeForPath(path) []const u8` — MIME by extension (the SvelteKit set: html/js/css/json/svg/png/ico/woff2/webmanifest/txt; default `application/octet-stream`).
  - A **path-traversal guard**: a request path must not escape `ui_dir`. Reject any path whose components include `..` (or contain `\` / NUL). A rejected/traversing path is treated as "no exact file" → SPA fallback to `index.html`, never the escaped file.
  - `resolve(io, gpa, ui_dir, method_is_get, path) !Served` where
    `Served = union(enum) { file: struct { abs_path: []u8, mime: []const u8 }, placeholder, not_handled }`.
    `abs_path` is gpa-owned (caller frees). Logic below. Filesystem-touching but unit-testable against a `std.testing.tmpDir` fixture.
- **`src/api/server.zig`** — dispatch the `not_found` arm through `static.resolve`; add `respondFile` (read bytes + serve with MIME) and `respondUiPlaceholder`. `ServeOptions` gains `ui_dir: []const u8`.
- **`src/main.zig`** — pass `config.ui_dir` into `ServeOptions`; add `static.zig` to test discovery.

`build.zig` is **unchanged** — no embedding, no build option, no node dependency. The UI is produced by `yarn build` separately and placed by the installer.

## `resolve` logic

1. `!method_is_get` → `.not_handled`.
2. path starts with `/api/` → `.not_handled` (the API/404 owns it).
3. `ui_dir` does not exist on disk → `.placeholder`.
4. Sanitize: split the URL path on `/`; if any component is `..`, `.`, empty-from-`\\`, or contains `\`/NUL → mark "unsafe". Normalize `/` → `index.html`.
5. If safe and the joined `<ui_dir>/<relpath>` exists and is a file → `.file{ abs_path, mimeForPath(relpath) }`.
6. Else (missing, or unsafe) → SPA fallback: if `<ui_dir>/index.html` exists → `.file{ that, "text/html" }`; else `.placeholder`.

This guarantees a traversal attempt (`/../../etc/passwd`) can never return a file outside `ui_dir` — it falls through to `index.html`.

## Routing (dispatch order in `serveRequest`)

1. `/api/*`, health, cors_preflight, projects_*/jobs_*/slices_* → UNCHANGED.
2. `.not_found` arm → `static.resolve(...)`:
   - `.file` → `respondFile` (read bytes, 200, MIME).
   - `.placeholder` → `respondUiPlaceholder` (plaintext note: "UI not found at `<ui_dir>` — build it (`cd chargesheet-ui && yarn build`) and set CHARGESHEET_UI_DIR, or use the dev server on :5173").
   - `.not_handled` → existing `respondNotFound` (JSON 404 — keeps `/api/*` unknowns as JSON).

CORS headers stay on responses (the dev :5173→:7777 flow still needs them; same-origin disk-serve doesn't).

## Error handling

- File read failure after `resolve` said `.file` (race: deleted between stat and read) → 404 plaintext.
- `ui_dir` missing/empty → placeholder (not a hard error; API still works for the dev/proxy flow).
- Traversal attempts → never serve outside `ui_dir` (guaranteed by step 4/6).

## Testing

- **Unit (`static.zig`)** against a `std.testing.tmpDir` fixture containing `index.html`, `_app/immutable/app.js`, `favicon.png`, `styles.css`:
  - exact hit → `.file` with correct `abs_path` + MIME.
  - `/` → index.html, `text/html`.
  - unknown path (`/projects/abc`) → index.html (SPA fallback).
  - `/api/v1/health` → `.not_handled`.
  - non-GET → `.not_handled`.
  - **traversal** (`/../../../etc/passwd`, `/..%2f..` already URL-decoded by the server to `/../..`) → does NOT resolve to a path outside the fixture dir (falls back to index.html or placeholder); assert the returned `abs_path`, if any, is within the fixture dir.
  - `mimeForPath` table coverage.
  - nonexistent `ui_dir` → `.placeholder`.
- **Manual smoke (real UI):** `cd chargesheet-ui && yarn build`; run the daemon with `CHARGESHEET_UI_DIR=$PWD/chargesheet-ui/build`; `curl /` → SvelteKit HTML, `curl /_app/...` → JS + `text/javascript`, `curl /projects/xyz` → index.html, `curl /api/v1/health` → JSON; open in a browser and drive the API from the daemon (no `yarn dev`).
- Existing 75 daemon tests must still pass; `zig build test` needs no node.

## Out of scope (later)

- The installer placing `ui/` next to the binary + CI building the UI (that's #3).
- Caching/compression headers (`ETag`, `Cache-Control`, gzip).
- In-memory caching of file reads (per-request read is fine for a local single-user tool).

## Acceptance criteria

- `zig build test` passes node-free; `static.resolve` fully unit-tested incl. the traversal guard, using a temp-dir fixture (no browser).
- Daemon with `CHARGESHEET_UI_DIR` pointed at a built `build/` serves the SPA: `/` + deep links → `index.html`, asset paths → correct bytes + MIME, `/api/*` unchanged.
- A traversal request cannot read any file outside `ui_dir`.
- With no `ui/` present, the daemon serves the placeholder note and the API still works.
- `build.zig` unchanged; no node dependency added to the daemon build.
