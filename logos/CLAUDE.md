# logos — the chargesheet daemon

Zig 0.16 HTTP daemon for the `lambe-haath` PDF chargesheet slicing tool. One
process serves **both** the JSON API (`/api/v1/*`) and the bundled web UI
(static SPA) on a single port (default `7777`). SQLite for metadata, MuPDF (via
the sibling `mupdf-zig` package) for PDF slicing.

> This file documents how the daemon actually works so future changes don't
> re-learn it the hard way. Keep it in sync with the code.

## Run it

```bash
zig build                                  # -> zig-out/bin/logos
CHARGESHEET_UI_DIR="$PWD/../chargesheet-ui/build" ./zig-out/bin/logos -p 7777
# open http://localhost:7777  (API + UI, one port, no `yarn dev`)
```

Flags: `-p/--port` (default 7777), `-h/--help`, `-V/--version`.
Ctrl+C (SIGINT) stops it; it's one process, so nothing else to kill.

## Environment

| Var | Meaning | Default |
|---|---|---|
| `CHARGESHEET_DATA_DIR` | SQLite DB + project files live here | per-OS app data dir (macOS: `~/Library/Application Support/ChargesheetTool`) |
| `CHARGESHEET_UI_DIR` | directory of built static UI to serve | `<exe_dir>/ui` (installer drops it beside the binary) |

Both resolved once at startup in `src/config.zig` (`AppConfig{ data_dir, ui_dir }`).

## Startup sequence (`src/main.zig`)

1. Parse args.
2. `AppConfig.load(io, gpa, env)` — resolve `data_dir` + `ui_dir`.
3. Create `data_dir`.
4. `lock.acquire(...)` — exclusive instance lock (see below). Conflict → friendly message, exit 1.
5. `Db.open(<data_dir>/data.db)` — opens SQLite, runs migrations.
6. `api_server.serve(...)` — binds the port and loops forever.
   - `error.AddressInUse` is caught and turned into an actionable message
     (the port is held by some other process) instead of a raw bind stack trace.

## Connection model (`src/api/server.zig`) — READ THIS BEFORE TOUCHING THE LOOP

**Thread-per-connection, keep-alive, with a request mutex.** This shape was
chosen deliberately after several wrong turns; the alternatives are footguns:

- `serve()` accepts in a loop and spawns a **detached `std.Thread`** per
  connection, so the accept loop never blocks on one client. A browser opens
  ~6 parallel connections; a single-threaded accept loop blocking on one
  keep-alive socket hangs the whole page.
- Connections are **keep-alive** (the *client* closes them). Do NOT force
  `connection: close` / one-request-per-connection: that makes the *server* the
  active closer, piling up server-side `TIME_WAIT` sockets that block a quick
  restart (because `reuse_address = false`, see below).
- A single `std.Io.Mutex` (`req_mutex`) serializes **request processing**. It is
  acquired *after* `receiveHead` (so idle keep-alive connections don't block
  others) and released when the request finishes. This guarantees the shared
  `zqlite.Conn` and allocator are never touched concurrently, regardless of how
  SQLite was compiled. Trade-off: a slow request (a sync slice job) briefly
  serializes others — fine for a single-user local tool.
- `reuse_address = false` on `listen`: Zig's `reuse_address` sets **both**
  `SO_REUSEADDR` and `SO_REUSEPORT`. `SO_REUSEPORT` would let two daemons bind
  the same port and have the kernel silently load-balance between them. The
  lock file only guards *same-`data_dir`* collisions, so this flag is the only
  guard against two daemons (different `data_dir`) on one port. Don't flip it.

### Request dispatch (`serveRequest`)

`router.match(method, path)` → a `Route`. The `.not_found` route is the hinge:
unmatched non-API GETs fall through to **static UI serving**; unmatched
`/api/*` stays a JSON 404.

All responses carry CORS headers for `http://localhost:5173` (the Vite dev
origin) so `yarn dev` can still proxy to the daemon during UI development.

## Static UI serving (`src/api/static.zig`)

`resolve(io, gpa, ui_dir, is_get, path) -> Served` where
`Served = { file{abs_path, mime} | placeholder | not_handled }`:

- non-GET or `/api/*` → `.not_handled` (caller does API/404).
- `ui_dir` missing → `.placeholder` (plaintext "no UI built" note; API still works).
- exact file under `ui_dir` → serve it; otherwise **SPA fallback to `index.html`**
  (client-side routing).
- **Path-traversal guard:** any path with a `..`/`.` segment or `\`/NUL is
  unsafe and never resolves to a file outside `ui_dir` — it falls through to
  `index.html`. This is a security invariant; keep it.
- Query strings are stripped before resolution (`stripQuery`) — Vite assets
  carry `?v=` cache-busting params.
- MIME by extension (`mimeForPath`). **`.mjs` and `.wasm` MUST be JS/wasm MIME
  types** (`text/javascript`, `application/wasm`) — browsers refuse to execute
  an ES module / instantiate wasm served as `application/octet-stream`, which
  broke the pdf.js worker (`pdf.worker.min.*.mjs`).

`build.zig` is intentionally **node-free** and does not embed the UI; the UI is
built separately (`yarn build`) and placed on disk.

## Instance lock (`src/lock.zig`)

`<data_dir>/daemon.lock` holds `pid:port`. On startup, if the file exists and
the recorded PID is alive → `AnotherInstanceRunning`; if the PID is dead → the
lock is stale and reclaimed. **The lock is scoped to `data_dir`**, not the port.
It is not removed on SIGINT (signals skip `defer`), so a stale lock after Ctrl+C
is normal and auto-reclaimed on next start.

## Storage layout (`src/storage/project_dir.zig`)

```
<data_dir>/
  data.db                                  SQLite (projects, slices, jobs)
  daemon.lock                              pid:port
  <project_id>/
    chargesheet.pdf                        uploaded source PDF
    slices/<name>.pdf                      output slices
```

## API routes (`src/api/router.zig`)

| Method | Path | Route |
|---|---|---|
| GET | `/api/v1/health` | health |
| GET | `/api/v1/projects` | list |
| POST | `/api/v1/projects` | create (multipart) |
| GET/DELETE | `/api/v1/projects/:id` | get / delete |
| GET | `/api/v1/projects/:id/chargesheet` | download source PDF |
| POST | `/api/v1/projects/:id/jobs/slice` | run a slice job |
| GET | `/api/v1/projects/:id/jobs/:job_id` | job status |
| GET | `/api/v1/projects/:id/slices` | list slices |
| GET/DELETE | `/api/v1/projects/:id/slices/:filename` | download / delete slice |
| OPTIONS | `/api/v1/*` | CORS preflight |

### Upload (POST /api/v1/projects)

`multipart/form-data` with fields: **`name`** (required), `description`
(optional), and the file under field name **`chargesheet`** (NOT `file`). The
handler uses `request.readerExpectContinue` (NOT `readerExpectNone`) so clients
sending `Expect: 100-continue` (curl, many HTTP libraries) get the continuation
header instead of tripping an assert that would abort the whole daemon. The PDF
is written to disk, opened via `mupdf-zig`, page-counted, and a row inserted.

### Slicing

`POST .../jobs/slice` processes its slice items **synchronously** within the
request (opens the source PDF, writes each `slices/<name>.pdf` via MuPDF,
inserts a `slices` row per success; failures are best-effort per slice). MuPDF
write options use `do_garbage=2, do_clean=1` so a sliced-out subset is small
(orphaned objects are GC'd) — this lives in `mupdf-zig/src/bridge/bridge.c`.

## Build & test

```bash
zig build            # build the exe
zig build test       # full suite (node-free); currently 79/79
```

Cross-compiles + links for `x86_64-windows-gnu` and `x86_64-linux-musl` from
macOS (compile+link verified; cross-binaries not yet runtime-tested on target).
Per-OS branches exist (e.g. `nowIso8601` uses `RtlGetSystemTimePrecise` on
Windows vs `clock_gettime` on POSIX).

## Zig 0.16 notes (post-`std.Io` refactor — easy to get wrong)

- Filesystem via `std.Io.Dir.cwd()` (not `std.fs.cwd()`); reads via
  `readFileAlloc(io, path, gpa, .limited(N))`; `file.close(io)`,
  `file.writeStreamingAll(io, bytes)`.
- Mutex is `std.Io.Mutex` (`.init`, `lock(io)`/`lockUncancelable(io)`/`unlock(io)`)
  — there is no `std.Thread.Mutex`. The futex backing it works from raw
  `std.Thread.spawn` threads.
- HTTP: `request.respond(body, .{ .status, .extra_headers })`; body reading via
  `readerExpectContinue`/`readerExpectNone`.
- Exe-dir: `std.process.executableDirPathAlloc(io, gpa)`.
- `std.mem.trimStart` (not `trimLeft`); `dir.createDirPath` (not `makePath`).
