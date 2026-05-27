# Design: Daemon serves the embedded web UI

**Date:** 2026-05-27
**Status:** Approved (brainstorming) — ready for implementation plan
**Context:** Phase toward the single-CLI product (see `docs/superpowers/research/2026-05-27-zig-packaging-research.md` and the project memory). This is "#2 — daemon serves the bundled UI." Distribution model is **Model B**: prebuilt per-platform binaries (CI builds, embeds UI, publishes; receiver downloads a binary and installs nothing). The frontend build (node/yarn) runs only in CI/dev, never on the receiver.

---

## Goal

The `logos` daemon serves the SvelteKit web UI (`chargesheet-ui`) from its own binary on `:7777`, alongside the existing `/api/v1/*` — so the shipped binary is one self-contained file serving both API and UI. The user opens `http://localhost:7777` and uses the tool; no separate `yarn dev`, no static-file directory to ship.

The UI is already a pure SPA: `adapter-static` with `fallback: 'index.html'`, `ssr=false`, `prerender=false`. `yarn build` emits a static `build/` dir; unknown routes resolve to `index.html` for client-side routing.

## Build-time: `-Dembed-ui` option (default `false`)

`build.zig` gains a boolean option `embed-ui`, default **false**.

- **`-Dembed-ui=true`** (CI / release builds): a build step runs `yarn build` in `chargesheet-ui/`, producing the static `build/`. A generator step then emits a Zig manifest module that `@embedFile`s every file under `build/`, exposed as a `std.StaticStringMap([]const u8)` keyed by request path (`/`, `/_app/...`, `/favicon.png`, etc.). That module is imported into the daemon. A build option (`@import("build_options").embed_ui = true`) tells the daemon assets are present.
- **`-Dembed-ui=false`** (default — dev + the test suite): no `yarn` invocation, no embedded assets, **no node dependency**. `zig build` and `zig build test` stay node-free and fast; the existing 75-test daemon suite never acquires a node/yarn prerequisite. The daemon serves a short placeholder at `/`.

**Rationale for default-false:** Backend dev and CI test runs must not require node. UI dev uses the existing `yarn dev` (:5173, hot reload, Vite-proxies `/api`→:7777). The embedded UI matters only for the shipped binary, which CI builds with `-Dembed-ui=true`. This mirrors the MuPDF make-driven pattern: the heavy external-toolchain build is gated and runs only where that toolchain exists.

## Components

- **`build.zig`** — `embedUi(b, target) !*std.Build.Module` helper (only wired when `embed-ui=true`): runs `yarn build` via a `Run` step in `chargesheet-ui/`, then a generator (a small Zig program run at build time, or an `addWriteFiles` that emits the manifest) produces `assets.zig` `@embedFile`-ing each built file. Returns the assets module. The `embed_ui` bool flows to the daemon via `b.addOptions()` (`build_options`).
- **`src/api/static.zig`** — the static-serving unit. Holds:
  - the embedded asset map (imported from the generated module when `embed_ui`, else an empty map),
  - a hardcoded MIME table for the extensions a SvelteKit build emits: `.html→text/html`, `.js→text/javascript`, `.css→text/css`, `.json→application/json`, `.svg→image/svg+xml`, `.png→image/png`, `.ico→image/x-icon`, `.woff2→font/woff2`, `.webmanifest→application/manifest+json`, `.txt→text/plain`; default `application/octet-stream`.
  - `pub const Asset = struct { bytes: []const u8, mime: []const u8 };`
  - `pub fn lookup(path: []const u8) ?Asset` — exact-match asset lookup with MIME. Pure, unit-testable.
- **`src/api/server.zig`** — dispatch gains static handling (see Routing). The static-serving decision (exact hit vs SPA fallback) lives here; `static.zig` stays a pure lookup.

## Routing (dispatch order in `serveRequest`)

1. `/api/*` → existing API router + handlers (UNCHANGED).
2. `static.lookup(path)` exact hit (`/` normalized to `/index.html`; `/_app/...`; `/favicon.png`; etc.) → respond 200 with the asset bytes + its MIME.
3. Any other non-`/api` path → **SPA fallback**: serve `index.html` (200, `text/html`). This makes deep links and refresh on client-routed paths (e.g. `/projects/abc`) work.
4. When `embed_ui=false`: step 2/3 have no assets; `/` (and any non-`/api`) returns a short plaintext note: "UI not embedded — build with `-Dembed-ui=true`, or run the dev server (`cd chargesheet-ui && yarn dev`, http://localhost:5173)."

CORS headers remain on `/api/*` responses (the dev :5173→:7777 flow still needs them). The embedded UI is same-origin, so it doesn't rely on CORS.

## Error handling

- `embed_ui=true`, path not an exact asset, not `/api` → SPA fallback to `index.html`. If `index.html` itself is somehow absent (build produced nothing) → 404 plaintext. (Shouldn't happen if `yarn build` succeeded; the build step fails loudly if `yarn build` errors.)
- `embed_ui=false` → the placeholder note (not a hard error; the daemon + API still work for the dev/proxy flow).
- A failed `yarn build` during `-Dembed-ui=true` fails the `zig build` (the `Run` step's nonzero exit propagates) — we do not ship a binary with a broken/missing UI.

## Testing

- **Unit (`static.zig`)** — with a small fake asset map injected for tests:
  - `lookup("/index.html")` → bytes + `text/html`.
  - `lookup("/_app/immutable/x.js")` → bytes + `text/javascript`.
  - a `.css` path → `text/css`; an unknown extension → `application/octet-stream`.
  - `lookup("/api/v1/health")` → null (static never claims `/api`).
- **Unit (server fallback decision)** — a helper that, given a path + asset map, returns the chosen response (asset vs index.html-fallback vs api-passthrough), tested without sockets: `/` → index.html; `/projects/abc` (no exact asset) → index.html; `/_app/x.js` (exact) → that asset; `/api/...` → not static.
- **Manual smoke (`-Dembed-ui=true`)**: build with the flag, run the daemon, `curl http://localhost:7777/` returns the SvelteKit HTML; `curl /_app/...` returns JS with `Content-Type: text/javascript`; `curl /projects/xyz` returns index.html; `curl /api/v1/health` still returns the JSON. Open in a browser and confirm the app loads + drives the API.
- The existing 75 daemon tests must still pass with the default `-Dembed-ui=false` (no node needed).

## Out of scope (later phases)

- CI matrix build + GitHub Releases + the cross-platform install script (`curl|sh` + PowerShell) — that is "#3", which consumes this phase's `-Dembed-ui=true` binary.
- Compression/caching headers (`Content-Encoding`, `ETag`, `Cache-Control`) for assets — nice-to-have; defer until it matters.
- Serving the UI on a configurable port / path prefix — `:7777` root is fine for v1.

## Acceptance criteria

- `zig build test` passes with NO node/yarn dependency (default `embed-ui=false`); 75/75 daemon tests + the new `static.zig` unit tests green.
- `zig build -Dembed-ui=true` runs `yarn build`, embeds the output, and the daemon serves the SPA: `/` and deep links return `index.html`, asset paths return correct bytes + MIME, `/api/*` unchanged.
- The shipped binary (embed-ui=true) is a single self-contained file — no external UI directory required at runtime.
- `static.lookup` + the fallback decision are covered by unit tests that don't need a browser or a real build.
