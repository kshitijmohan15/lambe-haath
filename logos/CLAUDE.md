# logos — the chargesheet daemon

Zig 0.16 daemon for the `lambe-haath` chargesheet pipeline. One process serves
**both** the JSON API (`/api/v1/*`) and the bundled web UI (static SPA) on a
single port (default `7777`). SQLite via `zqlite` for metadata, MuPDF via the
sibling `mupdf-zig` package for PDF slicing, and a pool of long-running Python
agent subprocesses (`ocr_agent`, `prompt_agent`) reached over newline-delimited
JSON-RPC for OCR and LLM-prompted reasoning.

> This file documents how the daemon actually works so future changes don't
> re-learn it the hard way. Keep it in sync with the code.

## Run it

```bash
zig build                                  # -> zig-out/bin/logos
CHARGESHEET_UI_DIR="$PWD/../chargesheet-ui/build" \
LAMBE_AGENTS_DIR="$PWD/../" \
  ./zig-out/bin/logos -p 7777
# open http://localhost:7777  (API + UI, one port, no `yarn dev`)
```

Flags: `-p/--port` (default 7777), `-h/--help`, `-V/--version`.
Ctrl+C (SIGINT) stops it; defer-block at end of `main` requests dispatcher stop,
joins its thread, then `sup.shutdownAll()` closes all Python workers cleanly.

## Environment

| Var | Meaning | Default |
|---|---|---|
| `CHARGESHEET_DATA_DIR` | SQLite DB + project files + `daemon.lock` + optional `agents.json` | per-OS app data dir (macOS: `~/Library/Application Support/ChargesheetTool`) |
| `CHARGESHEET_UI_DIR` | directory of built static UI to serve | `<exe_dir>/ui` (installer drops it beside the binary) |
| `LAMBE_AGENTS_DIR` | parent directory containing the `agents/` Python package | `<exe_dir>/..` → `<exe_dir>/../..` → `./` (binary-relative fallback chain in `src/paths.zig`) |

All three resolved once at startup in `src/config.zig` into `AppConfig{data_dir, ui_dir, agents_dir}`.

## Startup sequence (`src/main.zig`)

1. Parse args.
2. `AppConfig.load(io, gpa, env)` — resolve all three directories.
3. Create `data_dir` if missing.
4. `lock.acquire(...)` — exclusive instance lock; conflict → friendly message, exit 1.
5. `Db.open(<data_dir>/data.db)` — opens SQLite, runs migrations (currently v1→v2).
6. `jobs_mod.markStuckJobsFailed(db)` — any `status=running` row left over from a
   previous crash is flipped to `failed` with error `"daemon_restart_during_run"`.
   This MUST happen before the dispatcher starts so it doesn't try to resume
   ghost work.
7. `agent_config.loadFromDir(data_dir)` — read `<data_dir>/agents.json` if
   present, else use the hardcoded defaults in `src/agents/config.zig`
   (ocr=2 workers, prompt=5 workers; commands run via `python3 -m agents.*`).
8. `req_mutex` (`std.Io.Mutex`) + `event_ch` (`EventChannel`) constructed.
9. `Supervisor.init(...)` — does NOT spawn workers yet; pool is on-demand.
10. `Dispatcher.init(...)` then `std.Thread.spawn(Dispatcher.run, ...)` — the
    dispatcher loop runs on a dedicated OS thread for the whole process lifetime.
11. `api_server.serve(...)` — binds the port and loops forever. `error.AddressInUse`
    is caught and turned into an actionable message.
12. **Shutdown** (defer block at end of `main`): `disp.requestStop()`, join
    dispatcher thread, `sup.shutdownAll()` (sends `shutdown` + `notifications/exit`
    to each worker, closes stdin, waits for child exit).

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
  `zqlite.Conn` and allocator are never touched concurrently. Trade-off: a slow
  request briefly serializes others — fine for a single-user local tool.
- The dispatcher thread also acquires `req_mutex` for every DB read/write,
  so handlers and dispatcher are mutually serialized on one global lock.
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

## Storage layout

```
<data_dir>/
  data.db                          SQLite (WAL mode; pragmas in src/db/db.zig)
  data.db-wal, data.db-shm         WAL side files — back up all three together
  daemon.lock                      pid:port
  agents.json                      optional override of agent specs
  <project_id>/
    chargesheet.pdf                uploaded source PDF
    slices/<name>.pdf              MuPDF-sliced output PDFs
    extractions/<name>.md          ocr_agent output (Markdown)
    extractions/<name>.meta.json   OCR run metadata (model, tokens, latency)
    prompt_outputs/<prompt>.md     prompt_agent output (Markdown)
```

`src/storage/project_dir.zig` owns this layout; `src/paths.zig` owns
per-OS data-dir resolution and `LAMBE_AGENTS_DIR` fallback.

## Database (`src/db/`)

**One shared `zqlite.Conn`** opened at startup. WAL mode, `foreign_keys=ON`,
`synchronous=NORMAL`, `busy_timeout=5000`. Concurrency is handled at the
application layer (`req_mutex`), not via a pool.

`src/db/migrations.zig` runs `v1.sql` then `v2.sql` on open; the migrations
table records the version. **Never edit a checked-in migration** — add a new
one. New columns must be `NULLABLE` or have defaults so existing rows survive.

### Tables (one module per table — `src/db/<name>.zig` wraps the SQL)

- **`projects`** — `id` (uuid v4), `name`, `chargesheet_filename`, `page_count`,
  `size_bytes`, `created_at`, `last_opened_at`, `description`. The `/projects`
  list query LEFT JOINs slices/extractions/prompt_outputs to return per-project
  counts in one round-trip.
- **`slices`** — `(project_id, filename)` PK. `start_page`, `end_page` (1-based
  inclusive on both ends), `size_bytes`, `kind` (`annexure`|`rud`|`other`),
  `kind_key` (lower-roman or 2-digit suffix), `created_at`. Index
  `(project_id, kind, kind_key)` powers the prompt-params lookup in the
  dispatcher.
- **`jobs`** — `id` (uuid), `project_id`, `type` (`slice`|`ocr`|`prompt`),
  `status` (`queued`|`running`|`completed`|`failed`|`canceled`), `progress`
  (0..1), `payload` (request JSON), `results` (response JSON or null), `error`,
  `created_at`, `updated_at`. The schema CHECK enforces the type/status enums.
  Indices: `(status, type)`, `(project_id)`, `(created_at)`.
- **`extractions`** — `(project_id, slice_filename)` PK. OCR results:
  `markdown_path`, `meta_path`, `model`, `pages`, `page_markers_found`,
  `input_tokens?`, `output_tokens?`, `input_cost_usd?`, `output_cost_usd?`,
  `latency_s`, `created_at`. **`upsert()` uses ON CONFLICT REPLACE** — re-running
  OCR on the same slice overwrites the row. Costs are stored, not recomputed,
  so they're immutable for audit even if the pricing table changes later.
- **`prompt_outputs`** — `(project_id, prompt_name)` PK, mirror of `extractions`
  for prompt jobs. Adds a `warnings` JSON column (e.g. "missing annexure III").
- **`job_logs`** — autoincrement id, `job_id` FK, `ts` (ISO 8601), `level`,
  `logger`, `message`. Index `(job_id, ts)`. Populated by the dispatcher from
  agent `notifications/log` messages; surfaced at `GET /api/v1/jobs/:id/logs`.
- **`stats`** — no rows of its own. The module is read-only aggregation queries
  over extractions + prompt_outputs (lifetime totals, per-model breakdown,
  daily time-series, top-N slowest jobs).

## Agents subsystem (`src/agents/`)

The dispatcher + supervisor + workers + JSON-RPC layer is the biggest piece of
the daemon and the one that's easiest to get wrong.

### Workers (`src/agents/worker.zig`)

A **worker** is a long-running Python subprocess (`std.process.Child`) plus a
Zig-side **reader thread** that reads its stdout line-by-line, decodes each
line as a JSON-RPC message, and pushes it onto the shared `EventChannel`.
Stdin is owned by the dispatcher; nothing else writes to it. Each worker
carries its own `next_request_id`, `current_job_id` (set while assigned),
and a `kind` (`ocr` or `prompt`).

Workers are **persistent**, not per-job. The cost of spawning a Python
interpreter (~500ms cold) is paid once per worker, then amortized over many
jobs. A worker is fungible within its kind — any free OCR worker can take
any OCR job.

### Supervisor (`src/agents/supervisor.zig`)

The pool manager. **On-demand**: `acquire(kind)` returns an idle worker if
one exists, else spawns one up to the configured `max_workers` cap, else
blocks the caller (the dispatcher) until one frees. `release(worker)` flips
it back to idle. `shutdownAll()` sends `{method:"shutdown"}` + then
`{method:"notifications/exit"}` to each, closes stdin, waits for exit, frees.

Worker states: `spawning` → `idle` ↔ `busy` → `draining` → `dead`.

Caps come from `agents.json` or the default in `src/agents/config.zig`
(currently ocr=2, prompt=5).

### Event channel (`src/agents/event_channel.zig`)

Single-consumer (the dispatcher), multi-producer (every worker reader
thread), bounded FIFO behind a mutex + condition variable. Envelopes are
`{worker_id, kind: message|dead|parse_error, payload}`. The dispatcher's
loop is the only thing that calls `recvTimeout`.

### Dispatcher (`src/agents/dispatcher.zig`)

A single thread, started from `main.zig` and running until `requestStop()`.
Each iteration:

1. `drainEvents()` — pop everything off the channel: route responses to
   their pending jobs, append logs to `job_logs`, update progress, handle
   worker-death events.
2. `flushPendingCancels()` — for each `cancel_requests[job_id]`, find the
   worker running that job and send it a `cancel` request.
3. `maybeDispatch("ocr")` then `maybeDispatch("prompt")` — pull the oldest
   `queued` job of that kind, acquire a worker for it, build the JSON-RPC
   params, send the request. If no workers are available or no queued
   jobs exist, skip.
4. `channel.recvTimeout(50)` — block up to 50ms waiting for any event.

**End-to-end trace of `POST /api/v1/projects/:id/jobs/ocr`:**

1. HTTP thread (`handlers_ocr.zig`) validates project + slice, generates a
   uuid, inserts a `jobs` row with `type=ocr, status=queued`, `payload =
   {"slice_filename":"annexure-i.pdf"}`. Returns `{job_id, status: "queued"}`
   immediately.
2. Dispatcher's next `maybeDispatch("ocr")` finds the row, calls
   `supervisor.acquire("ocr")`. Spawns a Python `ocr_agent` if needed.
3. `agent_params.buildOcrParams` looks up the slice's `start_page` from the
   slices table (so the OCR'd Markdown carries absolute page numbers, not
   slice-internal ones — verified by the 45 unit tests in
   `tests/test_ocr_page_offset.py`). Emits:
   `{slice_path, output_dir, start_page, job_id, _meta:{progressToken}}`.
4. Dispatcher writes one JSON-RPC line to the worker's stdin:
   `{"jsonrpc":"2.0","id":<n>,"method":"ocr.extract","params":{...}}`.
5. Worker processes; meanwhile it can stream `notifications/progress` and
   `notifications/log` events back. Dispatcher (in `drainEvents`) appends
   each log to `job_logs`, bumps `jobs.progress`.
6. Worker eventually emits `{"jsonrpc":"2.0","id":<n>,"result":{markdown_path,
   meta_path, pages, page_markers_found, input_tokens?, output_tokens?,
   latency_s}}`.
7. Dispatcher's `handleOcrSuccess` (a) computes input/output USD via
   `pricing.cost(model, in, out)`, (b) calls `extractions_mod.upsert(...)`,
   (c) calls `jobs_mod.markCompletedAt(...)`, (d) `supervisor.release(worker)`.
8. The HTTP client either polls `GET /api/v1/projects/:id/jobs/:id` or
   subscribes to `GET /api/v1/jobs/:id/stream` (SSE) to learn the result.

**Crash handling:** if a worker reader thread sees EOF or a write fails,
the channel gets a `dead` event. The dispatcher requeues the in-flight job
**once** (`retry_attempts` map). A second death of the same job fails it
permanently with `worker_died: 2 attempts`. This bounds infinite-loop
crash recovery while tolerating one transient failure.

**Cancellation:** `POST /api/v1/jobs/:id/cancel` adds the id to
`cancel_requests`. The dispatcher's next iteration sends a JSON-RPC
`{method:"cancel", params:{job_id}}` to the worker running it. The agent
responds with error code `-32099` (treated as "canceled" rather than
"failed"). If the job hadn't started yet, the dispatcher just flips the row
to `status=canceled`.

### Agent params building (`src/agents/agent_params.zig`)

This module owns the **request → JSON-RPC params** conversion. It used to be
buggy: the daemon was nesting payload under a `_payload` key but the Python
agents expected a flat object, so OCR/prompt jobs failed with `"slice_path
and output_dir are required"`. Fixed in commit `5d79172`. Two builders:

- `buildOcrParams(gpa, db, data_dir, job_id, project_id, payload_json)`:
  pulls `slice_filename` from payload, looks up the slice via
  `slices_mod.getByKey` to get `start_page` (absolute in original chargesheet),
  emits the flat params object the OCR agent expects.
- `buildPromptParams(...)`: pulls `prompt_name` from payload, then iterates
  the extractions table for that project and classifies each via the
  lenient `normalize → annexureStem → romanFromSuffix` and `rudIdSuffix`
  helpers. Accepts `Annexure1.pdf`, `AnnexureII.pdf`, `ANNEXURE III.pdf`,
  `Annexure-IV.pdf`, `RUD1.pdf`, etc. Emits
  `{prompt_name, slices: {"annexure-i": {markdown_path}, ...},
  ruds: [{id: "RUD-01", markdown_path}, ...], output_dir, job_id, _meta}`.

The lenient classifier is **deliberately decoupled** from the `kind`/`kind_key`
columns on the slices table. Filenames are user input and may be edited; the
classifier re-normalizes at dispatch time rather than trusting stored columns.

### JSON-RPC framing (`src/agents/jsonrpc.zig`)

Newline-delimited JSON, JSON-RPC 2.0. One message per `\n`-terminated line on
stdin (daemon → agent) and stdout (agent → daemon). Params/result/error are
stored as raw JSON strings — callers parse them per-method. **Agent log
messages MUST escape embedded newlines** as `\\n` or they'll be split across
events; this has bitten us.

### Pricing (`src/agents/pricing.zig`)

Static table of `{model, input_usd_per_mtok, output_usd_per_mtok}` rows:

| model | input | output | notes |
|---|---|---|---|
| gemini-2.5-flash | $0.30 | $2.50 | |
| gemini-2.5-pro | $1.25 | $10.00 | |
| gemini-3.5-flash | $1.50 | $9.00 | current default for all prompts |
| gemini-3.1-pro-preview | $4.00 | $18.00 | **over-200k tier** (chargesheets always exceed it) |
| claude-sonnet-4-6 | $3.00 | $15.00 | |

**Append-only.** Existing rows are referenced by stored `*_cost_usd` columns
on extractions/prompt_outputs; editing a row in-place would corrupt audits.

### Agent config (`src/agents/config.zig`)

Loaded from `<data_dir>/agents.json` if present, else built-in defaults.
Each spec: `kind`, `command` (`python3` etc.), `args` (`-m agents.ocr_agent`),
`max_workers`, `model`. The `model` field on each spec is the *default* for
that kind; the Python `prompt_agent` can override per-prompt via its own
`PromptSpec.model` field.

## API routes (`src/api/router.zig`)

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/v1/health` | health + version |
| GET | `/api/v1/projects` | list projects (with per-project counts) |
| POST | `/api/v1/projects` | create (multipart `chargesheet`) |
| GET / DELETE | `/api/v1/projects/:id` | get / delete |
| GET | `/api/v1/projects/:id/chargesheet` | download source PDF |
| POST | `/api/v1/projects/:id/jobs/slice` | **synchronous** slice job (returns when done) |
| GET | `/api/v1/projects/:id/jobs/:job_id` | one job |
| GET | `/api/v1/projects/:id/jobs` | list jobs (`?status=running` filter) |
| POST | `/api/v1/projects/:id/jobs/ocr` | enqueue OCR for one slice |
| POST | `/api/v1/projects/:id/jobs/ocr/all` | enqueue OCR for every slice missing one |
| POST | `/api/v1/projects/:id/jobs/prompt` | enqueue one prompt |
| POST | `/api/v1/projects/:id/jobs/prompt/all` | enqueue every prompt |
| GET / DELETE | `/api/v1/projects/:id/slices` (+ `/:filename`) | list / download / delete slice |
| GET | `/api/v1/projects/:id/extractions` (+ `/:filename`) | list / read extraction markdown |
| GET | `/api/v1/projects/:id/prompts` (+ `/:name`) | list / read prompt markdown |
| POST | `/api/v1/jobs/:id/cancel` | request cancel |
| GET | `/api/v1/jobs/:id/logs` | flat log array |
| GET | `/api/v1/jobs/:id/stream` | SSE stream of progress |
| GET | `/api/v1/stats` | lifetime + per-model + top-projects |
| GET | `/api/v1/stats/project/:id` | project breakdown |
| GET | `/api/v1/stats/timeseries` | daily series (`?from=&to=`) |
| GET | `/api/v1/stats/slow` | top-N slowest jobs |
| OPTIONS | `/api/*` | CORS preflight |

`slice` is the only job type still handled **synchronously inside the HTTP
request**; OCR and prompt jobs are enqueued and run via the dispatcher.

### Upload (POST /api/v1/projects)

`multipart/form-data` with fields: **`name`** (required), `description`
(optional), and the file under field name **`chargesheet`** (NOT `file`). The
handler uses `request.readerExpectContinue` (NOT `readerExpectNone`) so clients
sending `Expect: 100-continue` (curl, many HTTP libs) get the continuation
header instead of tripping an assert that would abort the whole daemon.

### SSE (`src/api/sse.zig`)

`/api/v1/jobs/:id/stream` returns `Content-Type: text/event-stream` with
chunked transfer. The handler holds the connection open, polling the jobs
table every 500ms (releasing `req_mutex` between polls so other requests can
run), emitting `data: <json>\n\n` frames on each change. Closes when the job
reaches a terminal state or the client disconnects.

## Static UI serving (`src/api/static.zig`)

`resolve(io, gpa, ui_dir, is_get, path) -> Served`:

- non-GET or `/api/*` → `.not_handled` (caller does API/404).
- `ui_dir` missing → `.placeholder` (plaintext "no UI built" note; API still works).
- exact file under `ui_dir` → serve it; otherwise **SPA fallback to `index.html`**.
- **Path-traversal guard:** any path with a `..`/`.` segment or `\`/NUL is
  unsafe and falls through to `index.html`. Security invariant; keep it.
- Query strings are stripped (`stripQuery`) — Vite assets carry `?v=` busting.
- MIME by extension. **`.mjs` and `.wasm` MUST be `text/javascript` /
  `application/wasm`** — browsers refuse to execute an ES module or instantiate
  wasm served as `application/octet-stream`. This broke pdf.js's worker once.

`build.zig` is intentionally **node-free** and does not embed the UI; UI is
built separately (`yarn build`) and placed on disk.

## Instance lock (`src/lock.zig`)

`<data_dir>/daemon.lock` holds `pid:port`. On startup, if the file exists and
the recorded PID is alive → `AnotherInstanceRunning`; if dead → the lock is
stale and reclaimed. **Scoped to `data_dir`**, not the port. Not removed on
SIGINT (signals skip `defer`), so a stale lock after Ctrl+C is normal and
auto-reclaimed on the next start.

## Build & test

```bash
zig build            # build the exe
zig build test       # full suite (node-free)
```

Cross-compiles + links for `x86_64-windows-gnu` and `x86_64-linux-musl` from
macOS (compile+link verified; cross-binaries not yet runtime-tested on
target). Per-OS branches exist (e.g. `nowIso8601` uses `RtlGetSystemTimePrecise`
on Windows vs `clock_gettime` on POSIX).

Tests cover DB CRUD per table, router match cases, supervisor pool semantics,
JSON-RPC encode/decode round-trips, agent params construction (annexure/RUD
filename normalization, OCR start_page lookup), pricing math, event channel
send/recv, project_dir tree creation. `src/agents/integration_test.zig` spawns
a mock Python agent and exercises the full dispatcher round-trip — gated on
`LAMBE_MOCK_AGENT_PATH` env var so CI without Python skips it.

## Zig 0.16 notes (post-`std.Io` refactor — easy to get wrong)

- Filesystem via `std.Io.Dir.cwd()` (not `std.fs.cwd()`); reads via
  `readFileAlloc(io, path, gpa, .limited(N))`; `file.close(io)`,
  `file.writeStreamingAll(io, bytes)`.
- Mutex is `std.Io.Mutex` (`.init`, `lock(io)`/`lockUncancelable(io)`/`unlock(io)`)
  — there is no `std.Thread.Mutex`. The futex backing it works from raw
  `std.Thread.spawn` threads.
- HTTP: `request.respond(body, .{ .status, .extra_headers })`; body reading via
  `readerExpectContinue` / `readerExpectNone`.
- Exe-dir: `std.process.executableDirPathAlloc(io, gpa)`.
- `std.mem.trimStart` (not `trimLeft`); `dir.createDirPath` (not `makePath`).
- `std.ArrayList(T)` has **no `.writer()`** — for incremental string building
  use `std.fmt.allocPrint` + `appendSlice`, or write to a `std.Io.Writer`
  backed by a `BoundedArray`.

## Critical invariants — don't break these

1. **`req_mutex` covers both HTTP handlers and the dispatcher thread.** A
   single global mutex is simpler than per-table locking and correct because
   there's only one SQLite connection. Don't add a second connection without
   re-thinking this.
2. **The startup order in `main.zig` is load-bearing:** stuck-job cleanup
   MUST happen before the dispatcher starts. If you reorder, ghost jobs from
   a previous crash will be re-dispatched.
3. **Workers are persistent, not per-job.** Releasing returns them to the
   idle pool. If you find yourself spawning per-request, you've regressed
   the cost model — Python cold-start is ~500ms.
4. **Crash retry is bounded at 1.** If a job's worker dies twice in a row,
   the job fails. Don't loosen this without a bigger plan; unbounded retries
   on a deterministic bug are infinite spin.
5. **`extractions` and `prompt_outputs` upserts on conflict.** Re-running OCR
   on the same slice overwrites the row — by design (idempotency for
   recovery), but it means you cannot get history of past runs from these
   tables. Costs/latency are point-in-time for the *latest* run.
6. **Pricing rows are append-only.** Stored `*_cost_usd` columns are
   immutable historical truth; if you edit a price row in-place, past audits
   silently become wrong.
7. **`reuse_address = false` on listen.** This blocks both `SO_REUSEADDR`
   and `SO_REUSEPORT`. Don't flip it — `SO_REUSEPORT` would let two daemons
   silently share a port.
8. **Multipart upload uses `readerExpectContinue`**, not `readerExpectNone`.
   Clients sending `Expect: 100-continue` will otherwise trip an assert that
   aborts the whole daemon.
9. **Slice/extraction/prompt filename classification is lenient and lives in
   `agent_params.zig`,** not in the DB. Filenames are user input.
10. **Page numbers are 1-based inclusive on both ends, end-to-end.** UI →
    `handlers.zig:435` validation → mupdf-zig slice → slices.start_page/end_page
    → `agent_params.buildOcrParams` → OCR agent `absolute_page_range` helper.
    There are 45 unit tests locking this contract in
    `tests/test_ocr_page_offset.py`. Don't introduce 0-based offsets anywhere
    in this chain.
