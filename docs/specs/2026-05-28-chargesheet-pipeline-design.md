# Chargesheet OCR + Agent Pipeline — Design

**Status:** Draft complete; awaiting user review before implementation planning.
**Last updated:** 2026-05-28
**Target project:** `lambe-haath` (Zig daemon `logos` + Svelte SPA `chargesheet-ui`)
**Agent repo:** `pdf-extraction-experiments` (this repo)

---

## Goal

Add an OCR + multi-prompt extraction pipeline to the existing `lambe-haath` chargesheet tool. The user uploads a PDF chargesheet to `logos`, slices it by annexure / RUD (existing feature), and then:

1. **OCR** of each slice through Gemini 2.5 Flash, producing per-page-marked Markdown + a JSON page index (already prototyped in `main.py`).
2. **Five reasoning prompts** through Claude Sonnet 4.6, each consuming a specific subset of slices and producing a Markdown legal analysis (`charge_memo_analysis`, `imputation_scrutiny`, `time_chart`, `evidence_audit`, `objection_brief`).

Outputs are stored on disk and indexed in SQLite; the Svelte SPA renders them with live job progress.

## Constraints

- **Single-user local desktop tool.** No multi-tenancy.
- **`logos` (Zig) is the brain.** Owns SQLite (WAL), the file system layout, the agent supervisor, the HTTP API, and serves the SPA. Single binary on port 7777.
- **Language-agnostic agents.** Workers communicate with `logos` only via JSON-RPC over stdio. The supervisor knows agents as `(command, args)` and capability declarations; it never imports anything from them.
- **Existing slicing is unchanged.** Slices are still produced by `logos` via `mupdf-zig`.
- **SQLite + WAL.** Single-writer (`logos`), readable by external tools.
- **Prompts are code, versioned in git.** Editing a prompt requires a build + restart of the relevant agent.

## Non-goals (v1)

- RAG / embeddings / vector search (deferred to a later phase; see _Future work_).
- Cross-document case profile aggregation across many cases.
- Multi-tenant or remote deployment.
- Web UI for editing prompts.
- Per-prompt model selection at runtime (each agent kind has a single configured model).

---

## Slicing convention (load-bearing assumption)

The pipeline assumes the user (via `logos`'s slicing UI) splits each chargesheet PDF into slices that follow a **fixed naming convention**:

| Slice kind | Filename | What it contains |
|---|---|---|
| Annexure I | `annexure-i.pdf` | Articles of Charge |
| Annexure II | `annexure-ii.pdf` | Statement of Imputations of Misconduct/Misbehaviour |
| Annexure III | `annexure-iii.pdf` | List of Relied Upon Documents (RUDs) |
| Annexure IV | `annexure-iv.pdf` | List of Prosecution Witnesses |
| RUD 01..NN | `rud-01.pdf`, `rud-02.pdf`, … | Each Relied Upon Document, one slice per RUD, two-digit zero-padded |
| Other | any other name | Treated as "auxiliary" — OCR'd but not consumed by the v1 prompts |

The slicing job in `logos` validates names against this convention. Non-conforming names produce a warning in the slice job's `results` JSON but are allowed (you might genuinely have a misc supplement that doesn't fit). The downstream prompt dispatcher only consumes slices matching the convention.

**Why this matters for the schema:** the existing `slices` table needs to know each slice's `kind` and `kind_key` so the dispatcher can look up "the ANNEXURE-II slice for project X" or "all RUDs for project X" without filename grepping. See _Database schema additions_ below.

**Why this matters for the prompts:** each prompt declares which slices it needs (next section).

---

## Architecture overview

```
                                 ┌──────────────────────────────────┐
                                 │   Svelte SPA (chargesheet-ui)    │
                                 │   served at :7777 by logos       │
                                 └──────────────┬───────────────────┘
                                                │ JSON over fetch / SSE
                                                ▼
                ┌────────────────────────────────────────────────────────────┐
                │                          logos                             │
                │                       (Zig daemon)                         │
                │                                                            │
                │   ┌───────────┐  ┌──────────┐  ┌──────────────────────┐    │
                │   │ HTTP API  │  │  SQLite  │  │  Agent supervisor    │    │
                │   │  router   │◄►│   (WAL)  │◄►│  + dispatcher loop   │    │
                │   └───────────┘  └──────────┘  └──────────┬───────────┘    │
                │                                            │ spawns child  │
                │                                            │ processes;    │
                │                                            │ JSON-RPC over │
                │                                            │ stdio         │
                └────────────────────────────────────────────┼───────────────┘
                                                             │
                            ┌────────────────────────────────┼───────────────────────┐
                            ▼                                ▼                       ▼
                ┌──────────────────────┐        ┌──────────────────────┐  ┌────────────────────────┐
                │   ocr agent pool     │        │  prompt agent pool   │  │  (future) embed pool   │
                │   max_workers = N    │        │  max_workers = M     │  │  any language          │
                │   ANY language       │        │  ANY language        │  │                        │
                └──────────────────────┘        └──────────────────────┘  └────────────────────────┘
                                                             │
                                                             ▼
                                                  Upstream APIs / local compute
                                                  (Gemini, Anthropic, local models)
```

### Process topology

Three classes of process on the user's machine:

1. **`logos`** — single Zig binary. Adds two new internal modules to today's daemon:
   - **agent supervisor** — spawns and monitors agent worker processes; tracks `(kind, pid, state)` per worker.
   - **dispatcher loop** — pulls queued jobs from the `jobs` table, picks an idle worker (or spawns a new one, up to the cap), routes the request, handles the response.

2. **Agent workers** — any executable speaking the `lambe-haath/1` JSON-RPC protocol on stdio. Lazily spawned, kept warm between jobs, capped per kind. The supervisor never inspects an agent's code.

3. **Svelte SPA** — existing UI. Gets new pages for OCR status, prompt outputs, and a per-slice "extraction view." Polls `GET /api/v1/projects/:id/jobs` for progress or subscribes via SSE.

### Supervisor ↔ agent contract

| Supervisor expects | Agent must |
|---|---|
| an executable at the configured path | exit cleanly on EOF of stdin |
| stdin = JSON-RPC requests, one per line | respond to `initialize` declaring its capabilities |
| stdout = JSON-RPC responses + notifications, one per line | respond to method calls listed in its capabilities |
| stderr = free-form text (captured to a log file, never parsed) | emit `notifications/progress` if it declared progress support |
| respawn on crash, redeliver in-flight job | be idempotent: same input → same output |

**That is the entire interface.** No mention of language anywhere.

### Concurrency model

- **logos**: existing `req_mutex` continues to serialize HTTP request processing (per logos `CLAUDE.md`). The dispatcher loop runs in its own thread and also acquires `req_mutex` for any DB write. The supervisor's per-worker reader threads (one per worker process) feed responses into a channel that the dispatcher consumes.
- **Across agents**: parallelism is bounded by total worker count. When all workers of a kind are busy and the cap is reached, new jobs queue.
- **Within an agent process**: **one job at a time.** Agents do not multiplex; parallelism comes from horizontal workers. Matches LSP/MCP precedent and keeps each agent implementation simple.

---

## Worker pool model

Each agent kind has a strict `max_workers` cap. The pool is **lazy**:

- Pool starts at 0 workers.
- When the dispatcher has a queued job for kind K:
  - If an idle worker of kind K exists → assign the job to it.
  - Else if `current_workers[K] < max_workers[K]` → spawn a new worker, complete its `initialize` handshake, then assign the job.
  - Else → leave the job queued; the dispatcher retries when a worker frees up.
- Workers **stay warm** between jobs. No idle timeout in v1.
- If a worker dies (EOF on stdout, non-zero exit, unparseable response), `current_workers[K]` decrements; the supervisor logs; the in-flight job is marked `failed` (or re-queued under a retry policy — see _Error handling_).

This decouples the cap from the prompt count: a 5-prompt fan-out can run on a 2-worker pool (jobs queue) or a 5-worker pool (full parallelism), without changing any other code.

### Config schema

```toml
# logos config (extended)

[[agent]]
kind = "ocr"
command = "python3"
args = ["-m", "agents.ocr_agent"]
max_workers = 2
model = "gemini-2.5-flash"
# Optional overrides (defaults shown):
# env = {}                            # inherited from logos's environment; this table adds/replaces keys
# cwd = "<logos_data_dir>/agents"    # working dir for the spawned process
# stderr_log = "<data_dir>/agent-stderr/<kind>-<worker_id>.log"

[[agent]]
kind = "prompt"
command = "python3"
args = ["-m", "agents.prompt_agent"]
max_workers = 5
model = "claude-sonnet-4-6"   # or "gemini-2.5-flash" / "gemini-2.5-pro" for testing without an Anthropic key
```

**Env var passthrough.** API keys like `GEMINI_API_KEY` and `ANTHROPIC_API_KEY` are read from logos's own environment and inherited by every spawned worker. The optional `env` table in agent config adds or overrides specific keys without disturbing the rest. Workers should NEVER read secrets from arguments or config files; only from inherited env vars.

**Model interchangeability.** The `model` field is mandatory per agent entry. logos passes it to the worker process via the `LAMBE_MODEL` environment variable at spawn time. The agent reads `os.environ['LAMBE_MODEL']` at startup, selects the appropriate upstream SDK (anthropic vs google.genai vs others), and uses that model for every job over its lifetime. To switch models, the user edits `agents.json` and restarts logos (which restarts the worker pool).

This decoupling matters in practice: the prompt agent can run against `claude-sonnet-4-6` in production and `gemini-2.5-flash` during local testing (when no Anthropic key is available), without code changes — just a config edit. The agent's response always includes the `model` it actually used, so `prompt_outputs.model` reflects ground truth and cost computation uses the correct pricing entry.

Implementation implication for the prompt agent (Plan D): import both `anthropic` and `google.genai`, route to the right SDK based on `LAMBE_MODEL.startswith("claude-")` vs `LAMBE_MODEL.startswith("gemini-")`. A thin `clients.py` module hides this so the rest of the agent is model-agnostic.

Switching a kind to a Go/Rust/Zig implementation is a one-line config change:

```toml
[[agent]]
kind = "prompt"
command = "/usr/local/bin/lambe-prompt-agent"  # native binary
args = []
max_workers = 5
```

`logos` itself learns nothing new.

---

## Agent inventory (v1)

| Kind | Method | Model | v1 implementation | v1 language rationale |
|---|---|---|---|---|
| `ocr` | `ocr.extract` | Gemini 2.5 Flash | extends today's `main.py` | `google-genai` SDK is most mature in Python; pypdf for size-bounded chunking; we already wrote it |
| `prompt` | `prompt.run` | Claude Sonnet 4.6 | new Python agent, Anthropic SDK + Pydantic schemas | smallest delta to ship |
| `embed` (deferred) | `embed.batch` | sentence-transformers (local) | Python | ML lib is Python-only distribution |

**These language choices are v1 conveniences, not architectural commitments.** Any of these can be replaced by a Go/Rust/Zig/Node binary without changes to `logos`, the supervisor, the dispatcher, or any other agent.

### The five prompts (v1)

Source: top 5 prompts (numbered 01–05) of the Defence Analysis Prompt corpus, which encode the legal analysis a Defence Assistant performs under Rule 14 of the CCS (CCA) Rules, 1965. Originals (Word documents) are committed in this repo at `agents/prompt_agent/prompts/raw/`; rendered Markdown copies live at `agents/prompt_agent/prompts/*.md` and are the canonical source loaded by the agent at startup.

| Name (Python id) | Required slices | Source docx | What it produces |
|---|---|---|---|
| `charge_memo_analysis` | `annexure-i`, `annexure-ii`, `annexure-iii`, `annexure-iv` | `01 Master Prompt Charge Memorandum.docx` | Pointwise summary of Articles of Charge + mapping to CCS (Conduct) Rules + charge–evidence matrix |
| `imputation_scrutiny` | `annexure-i`, `annexure-ii` | `02 Prompt No New Charge through Statement of Imputation.docx` | Per-Article comparison: does ANNEXURE-II (imputations) impermissibly travel beyond ANNEXURE-I (charges)? Lists deviations. |
| `time_chart` | `annexure-i`, `annexure-ii` | `03 Time Chart & Flow Chart.docx` | Per-Article chronological time chart (table) + brief narrative + Mermaid flowchart |
| `evidence_audit` | `annexure-i`, `annexure-ii`, `annexure-iii`, `annexure-iv`, all `rud-NN` | `04 Inconsitency in Proving the Document and Witnesses.docx` | Four deficiency lists: (A) unlisted docs, (B) RUDs without competent witnesses, (C) statements without cross-exam, (D) digital evidence lacking Section 65B certificate |
| `objection_brief` | `annexure-i`, `annexure-ii`, `annexure-iii`, `annexure-iv`, all `rud-NN` | `05 Inconsitency in Proving Output for Objection.docx` | Same four lists as `evidence_audit` but in "objection-ready" compact form, draft-ready for Inquiry Officer objections / Defence Statement / CAT pleadings |

**Required slices** are declared per prompt and surfaced at the agent's `initialize` time so the dispatcher can refuse to enqueue a `prompt.run` job until the required slices are all `ocr completed`. This is what makes the prompt fan-out gated on OCR fan-in — see _Job lifecycle_ below.

### Output format: Markdown, not structured JSON

Each prompt produces a single Markdown file. **No Pydantic schemas, no structured-output validation.** The prompts themselves already specify the output shape — tables with named columns, mermaid flowcharts, numbered article-wise sections, narrative paragraphs — and Markdown represents all of these natively. Forcing the model into typed JSON would fragment reasoning that's better expressed as prose, and trigger schema-retry churn that produces worse output than the first pass.

What the agent does with the model's response:

- Save it verbatim as `<prompt_name>.md` under the project's `prompts/` directory.
- Apply **soft, non-fatal checks** only:
  - Output is non-empty.
  - Output contains at least one Markdown heading (`#` or `##`).
  - Output is well-formed UTF-8.
- Log warnings if the checks fail; do **not** retry the model. The user sees the warning in the job log and decides whether to re-run.

What lives in `prompt_outputs` (DB):
- `project_id`, `prompt_name`, `markdown_path`, `model`, `input_tokens`, `output_tokens`, `latency_s`, `created_at`, plus any soft-check warnings.

What lives in the file (`<project_id>/prompts/<prompt_name>.md`):
- The full Markdown analysis as the model produced it.

**Why this is enough for v1:**
- Each prompt's source docx specifies its own output structure (e.g., `time_chart.md` will contain per-Article H2 sections, each with a chronological table and a mermaid block — because that's literally what the prompt asks for).
- The Svelte UI renders Markdown with table styling + mermaid rendering. That works for every prompt without per-prompt UI components.
- Downstream consumers (RAG, cross-prompt aggregation) can chunk Markdown by heading just like the OCR outputs.

**What we explicitly defer:**
- **Cross-case structured queries** ("show me all RUDs missing witnesses across all my cases") — these would need an extraction pass on top of the Markdown to build a sidecar index. Easy to add later; no point doing it before we know which queries the user actually runs.
- **Per-prompt UI tables with sort/filter** — same answer. The Markdown table renders fine; sortable views are a phase-2 feature.

Adding a 6th prompt = drop a new `.md` instruction file in `agents/prompt_agent/prompts/` + add a row to `PROMPTS` dict + restart `prompt_agent` workers. No DB migration. No UI change.

**External-reference dependency.** Prompts 04 and 05 reference external legal materials in their source docx (e.g., *"04 Laws applicable to Proving t…"*, *"Proving the document & Cross Ex…"*). The Markdown-rendered prompts embed the core legal principles inline (the source docx already restates the rules). If the user wants the full external references included, they can be bundled as additional files passed in `prompt.run`'s params (deferred to v1.1).

---

## JSON-RPC protocol (`lambe-haath/1`)

### Framing

**Newline-delimited JSON over stdio.** Each message is a single line of JSON terminated by `\n`. No `Content-Length` header (LSP's framing is unnecessary overhead for our case; MCP stdio uses the same newline convention).

### Lifecycle

```
host (logos)                                 agent
     │                                            │
     │  → initialize (id=0)                       │
     │ ←  initialize result                       │
     │  → notifications/initialized               │
     │                                            │
     │       ... many jobs over the lifetime ...  │
     │                                            │
     │  → shutdown (request)                      │
     │ ←  shutdown result                         │
     │  → notifications/exit                      │
     │       (agent exits 0)                      │
```

**initialize request:**

```json
{"jsonrpc":"2.0","id":0,"method":"initialize",
 "params":{
   "protocolVersion":"lambe-haath/1",
   "hostInfo":{"name":"logos","version":"0.3.0"},
   "capabilities":{"progress":true,"cancellation":true}}}
```

**initialize response:**

```json
{"jsonrpc":"2.0","id":0,
 "result":{
   "protocolVersion":"lambe-haath/1",
   "agentInfo":{"name":"ocr_agent","version":"0.1.0"},
   "capabilities":{
     "methods":["ocr.extract"],
     "progress":true,
     "cancellation":true}}}
```

### Job invocation — first-class methods

No `tools/call` indirection. Method names use dotted hierarchy.

```json
{"jsonrpc":"2.0","id":17,"method":"ocr.extract",
 "params":{
   "slice_path":"/data/<project>/slices/charges.pdf",
   "output_dir":"/data/<project>/extractions/charges",
   "_meta":{"progressToken":"j17"}}}
```

Response:

```json
{"jsonrpc":"2.0","id":17,
 "result":{
   "markdown_path":"/data/<project>/extractions/charges/charges.md",
   "meta_path":"/data/<project>/extractions/charges/charges.meta.json",
   "pages":176,
   "page_markers_found":156,
   "input_tokens":46154,
   "output_tokens":136477,
   "latency_s":617.0}}
```

### prompt.run request/response

`prompt_agent` declares its supported prompts and per-prompt slice requirements in its `initialize` response:

```json
{"jsonrpc":"2.0","id":0,
 "result":{
   "protocolVersion":"lambe-haath/1",
   "agentInfo":{"name":"prompt_agent","version":"0.1.0"},
   "capabilities":{
     "methods":["prompt.run"],
     "progress":true,
     "cancellation":true,
     "prompts":{
       "charge_memo_analysis":{"requires":["annexure-i","annexure-ii","annexure-iii","annexure-iv"]},
       "imputation_scrutiny":{"requires":["annexure-i","annexure-ii"]},
       "time_chart":{"requires":["annexure-i","annexure-ii"]},
       "evidence_audit":{"requires":["annexure-i","annexure-ii","annexure-iii","annexure-iv","ruds:*"]},
       "objection_brief":{"requires":["annexure-i","annexure-ii","annexure-iii","annexure-iv","ruds:*"]}}}}}
```

`ruds:*` is a sentinel meaning "all RUD slices, however many exist for this project." The dispatcher expands it at job-enqueue time.

A `prompt.run` request passes the gathered slice paths as a map keyed by slice kind:

```json
{"jsonrpc":"2.0","id":42,"method":"prompt.run",
 "params":{
   "prompt_name":"evidence_audit",
   "project_id":"abc123",
   "slices":{
     "annexure-i":{"markdown_path":"/data/abc123/extractions/annexure-i/annexure-i.md",
                   "meta_path":"/data/abc123/extractions/annexure-i/annexure-i.meta.json"},
     "annexure-ii":{"markdown_path":"…","meta_path":"…"},
     "annexure-iii":{"markdown_path":"…","meta_path":"…"},
     "annexure-iv":{"markdown_path":"…","meta_path":"…"}},
   "ruds":[
     {"id":"RUD-01","markdown_path":"…","meta_path":"…"},
     {"id":"RUD-02","markdown_path":"…","meta_path":"…"},
     {"id":"RUD-03","markdown_path":"…","meta_path":"…"}],
   "_meta":{"progressToken":"j42"}}}
```

Response carries the Markdown output path plus telemetry and any soft-check warnings:

```json
{"jsonrpc":"2.0","id":42,
 "result":{
   "markdown_path":"/data/abc123/prompts/evidence_audit.md",
   "model":"claude-sonnet-4-6",
   "input_tokens":48211,
   "output_tokens":9876,
   "latency_s":42.3,
   "warnings":[]}}
```

`warnings` is a list of soft-check failures (`"empty_output"`, `"no_markdown_headings"`, `"invalid_utf8"`). Empty list = clean run. Warnings are non-fatal: the file is written either way, and the user can re-run from the UI if they don't like the result.

### Method namespace

| Method | Agent kind | Purpose |
|---|---|---|
| `ocr.extract` | `ocr` | Extract page-marked Markdown + meta.json from a slice PDF |
| `prompt.run` | `prompt` | Run a named prompt against the project's required OCR'd slices; return Markdown analysis |
| `embed.batch` _(future)_ | `embed` | Embed text chunks; return vectors |
| `system/status` _(optional)_ | _any_ | Health / diagnostic — agents MAY implement this; supervisor uses it only if declared in `capabilities.methods` |

### Progress notifications

Caller passes `_meta.progressToken` in the request. Agent emits:

```json
{"jsonrpc":"2.0","method":"notifications/progress",
 "params":{"progressToken":"j17","progress":0.18,"message":"streaming pages 1-40: 32000 chars"}}
```

`progress ∈ [0, 1]` — written directly into `jobs.progress`.

### Log notifications

```json
{"jsonrpc":"2.0","method":"notifications/log",
 "params":{"level":"info","logger":"ocr_agent","message":"Uploaded as files/abc, state=ACTIVE"}}
```

Levels: `debug`, `info`, `warning`, `error`. Persisted to a `job_logs` table; surfaced live in the UI per job.

### Cancellation

```json
{"jsonrpc":"2.0","method":"notifications/cancelled",
 "params":{"requestId":17,"reason":"user_requested"}}
```

Agent aborts the in-flight upstream call, cleans up any uploaded files / open resources, sends an error response for request 17 with code `-32099`. Stays alive for the next request.

### Error codes

| Code | Meaning |
|---|---|
| -32700 | JSON parse error |
| -32600 | Invalid request |
| -32601 | Method not found |
| -32602 | Invalid params |
| -32603 | Internal error |
| -32099 | Canceled (matches LSP's `RequestCancelled`) |
| -32001 | Upstream API error (4xx/5xx) — `data` includes status + body |
| -32002 | Upstream rate limited — `data` includes `retry_after_s` |
| -32003 | Input file invalid (missing, unreadable, wrong format) |
| -32004 | Output exceeded model token limit (truncated) |
| -32005 | Auth missing/invalid (env var or credentials) |

### Dual-mode agent CLI

Every agent supports:

- **No args**: stdio JSON-RPC server loop (production, spawned by `logos`).
- **`--once <json-args>`**: run a single job from CLI args, write the result to stdout as plain JSON, exit. For local debugging without the daemon.
- **`--version`, `--help`**: standard.

---

## Database schema additions

Lands as `src/db/v2.sql` in `logos`. Bumps `schema_version` from 1 → 2.

### Changes to existing tables

**`slices`** — add two columns so the dispatcher can resolve a prompt's required slices without filename string-matching:

```sql
ALTER TABLE slices ADD COLUMN kind TEXT;       -- 'annexure' | 'rud' | 'other' | NULL
ALTER TABLE slices ADD COLUMN kind_key TEXT;   -- 'i'/'ii'/'iii'/'iv' for annexures,
                                                -- '01','02',... for RUDs, NULL for other

CREATE INDEX idx_slices_kind ON slices(project_id, kind, kind_key);
```

`kind` / `kind_key` are written by the slicing job at slice-creation time, parsed from the filename against the convention. SQLite can't add a `CHECK` constraint via `ALTER`, so the slicing job is responsible for setting these correctly; the application validates on write. Existing pre-v2 slice rows have `kind = NULL` and are treated as `'other'` (skipped by the prompt dispatcher).

**`jobs`** — expand `type` to include `ocr` and `prompt`. SQLite can't modify a CHECK constraint in place, so we rebuild the table:

```sql
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
CREATE INDEX idx_jobs_status_type ON jobs(status, type);  -- dispatcher's hot query
```

`payload` and `results` stay as `TEXT` (JSON). Conventions per type:

| type | `payload` JSON | `results` JSON |
|---|---|---|
| `slice` (existing) | `{start, end, name, kind, kind_key}` | `{slices: [{filename, size_bytes}]}` |
| `ocr` (new) | `{slice_filename}` | mirror of the corresponding `extractions` row |
| `prompt` (new) | `{prompt_name}` | mirror of the corresponding `prompt_outputs` row |

The `results` column is denormalized debug audit; the indexed source-of-truth for OCR / prompt outputs lives in their own tables.

### New tables

**`extractions`** — one row per OCR'd slice. Re-running OCR on the same slice **overwrites** the row (PK enforces this):

```sql
CREATE TABLE extractions (
    project_id          TEXT    NOT NULL,
    slice_filename      TEXT    NOT NULL,
    markdown_path       TEXT    NOT NULL,
    meta_path           TEXT    NOT NULL,
    model               TEXT    NOT NULL,
    pages               INTEGER NOT NULL CHECK (pages > 0),
    page_markers_found  INTEGER NOT NULL CHECK (page_markers_found >= 0),
    input_tokens        INTEGER,                      -- nullable: model may not return usage on partial runs
    output_tokens       INTEGER,
    input_cost_usd      REAL,                          -- nullable: model not in pricing table
    output_cost_usd     REAL,
    latency_s           REAL    NOT NULL,
    created_at          TEXT    NOT NULL,
    PRIMARY KEY (project_id, slice_filename),
    FOREIGN KEY (project_id, slice_filename)
        REFERENCES slices(project_id, filename) ON DELETE CASCADE
);
```

**`prompt_outputs`** — one row per `(project_id, prompt_name)`. Re-running a prompt overwrites. No analysis content here; the markdown file is the source of truth:

```sql
CREATE TABLE prompt_outputs (
    project_id       TEXT    NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    prompt_name      TEXT    NOT NULL,
    markdown_path    TEXT    NOT NULL,
    model            TEXT    NOT NULL,             -- 'claude-sonnet-4-6'
    input_tokens     INTEGER,
    output_tokens    INTEGER,
    input_cost_usd   REAL,                          -- nullable: model not in pricing table
    output_cost_usd  REAL,
    latency_s        REAL    NOT NULL,
    warnings         TEXT    NOT NULL DEFAULT '[]', -- JSON array of strings; queryable via json_each()
    created_at       TEXT    NOT NULL,
    PRIMARY KEY (project_id, prompt_name)
);
```

**`job_logs`** — the `notifications/log` stream from agents. One row per log line:

```sql
CREATE TABLE job_logs (
    id       INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id   TEXT    NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    ts       TEXT    NOT NULL,
    level    TEXT    NOT NULL CHECK (level IN ('debug','info','warning','error')),
    logger   TEXT    NOT NULL,                    -- agent name, e.g. 'ocr_agent'
    message  TEXT    NOT NULL
);
CREATE INDEX idx_job_logs_job_ts ON job_logs(job_id, ts);
```

`AUTOINCREMENT` keeps insertion order stable across the lifetime of the DB (sqlite default `INTEGER PRIMARY KEY` can reuse rowids). Order matters for replaying logs in the UI.

### Hot queries the dispatcher / UI need

These are the queries that drive design; called out to make sure the indexes above cover them.

```sql
-- Dispatcher: any queued OCR jobs to assign?
SELECT * FROM jobs WHERE status='queued' AND type='ocr' ORDER BY created_at ASC LIMIT 1;
--                                          ^ idx_jobs_status_type covers this

-- Dispatcher: find a slice by kind for prompt input
SELECT filename FROM slices WHERE project_id=? AND kind='annexure' AND kind_key='ii';
SELECT filename FROM slices WHERE project_id=? AND kind='rud' ORDER BY kind_key;
--                                          ^ idx_slices_kind covers both

-- Dispatcher: gate a prompt.run on OCR fan-in -- are all required slices extracted?
SELECT s.filename
FROM   slices s
LEFT JOIN extractions e
       ON s.project_id = e.project_id AND s.filename = e.slice_filename
WHERE  s.project_id=? AND s.kind IN ('annexure','rud') AND e.slice_filename IS NULL;
-- empty result == all required slices are OCR'd

-- UI: live log tail for a running job
SELECT ts, level, logger, message FROM job_logs WHERE job_id=? ORDER BY id;

-- UI: project dashboard -- one query for the whole status
SELECT
  (SELECT count(*) FROM slices       WHERE project_id=?)                             AS n_slices,
  (SELECT count(*) FROM extractions  WHERE project_id=?)                             AS n_extracted,
  (SELECT count(*) FROM prompt_outputs WHERE project_id=?)                           AS n_prompts_done,
  (SELECT count(*) FROM jobs WHERE project_id=? AND status='running')                AS n_running,
  (SELECT count(*) FROM jobs WHERE project_id=? AND status='failed')                 AS n_failed;
```

### Idempotency invariants

- **OCR re-run**: `INSERT … ON CONFLICT(project_id, slice_filename) DO UPDATE SET …` overwrites the row. The agent overwrites the `.md` and `.meta.json` files in place. No orphan files (paths are deterministic from slice name).
- **Prompt re-run**: same shape. `INSERT … ON CONFLICT(project_id, prompt_name) DO UPDATE SET …`. Overwrites the `.md`.
- **Slice deletion**: cascades to `extractions` (FK to `slices`). The agent's `.md` / `.meta.json` files are orphaned on disk; a periodic GC job (out of scope for v1, noted in _Future work_) reaps them.

### Migration order in v2.sql

1. `INSERT INTO schema_version VALUES (2);`
2. `ALTER TABLE slices` to add `kind`, `kind_key`. Backfill from filename in application code (not SQL — easier to express the regex in Zig).
3. Rebuild `jobs` with expanded CHECK.
4. `CREATE TABLE extractions / prompt_outputs / job_logs`.
5. Create indexes last (so they're built after data is in place).

---

## logos modules to add

### New Zig modules

```
src/
  db/
    v2.sql                  ← migration SQL designed in the previous section
    extractions.zig         ← INSERT/UPSERT/SELECT for `extractions`
    prompt_outputs.zig      ← INSERT/UPSERT/SELECT for `prompt_outputs`
    job_logs.zig            ← INSERT/SELECT for `job_logs`
    slices.zig              ← extend with kind/kind_key write + lookup helpers
    jobs.zig                ← extend to support 'ocr' / 'prompt' types
    migrations.zig          ← extend to run v2.sql when version=1
  agents/
    config.zig              ← parse agents.json from data_dir
    jsonrpc.zig             ← newline-delimited JSON-RPC 2.0 codec
    worker.zig              ← one child-process worker + its state machine
    supervisor.zig          ← worker pool: spawn/respawn, idle/busy bookkeeping
    dispatcher.zig          ← pull queued jobs, gate on preconditions, route to workers
  api/
    sse.zig                 ← server-sent-events helper (held-open connections)
    handlers_ocr.zig        ← new HTTP handlers for OCR job endpoints
    handlers_prompts.zig    ← new HTTP handlers for prompt job endpoints
    handlers.zig            ← (modified) wires the above in
    router.zig              ← (modified) new route table entries
```

### `src/agents/config.zig` — agent registry

Reads `<data_dir>/agents.json` once at startup. Falls back to a hardcoded default if the file is missing (so a fresh install works without manual config).

Schema:

```json
{
  "agents": [
    {"kind": "ocr",    "command": "python3", "args": ["-m", "agents.ocr_agent"],    "max_workers": 2},
    {"kind": "prompt", "command": "python3", "args": ["-m", "agents.prompt_agent"], "max_workers": 5}
  ]
}
```

Why JSON: Zig stdlib parses it natively, no new dep. Why a file (not env vars): user may want to swap an agent's command line without restarting their shell.

### `src/agents/jsonrpc.zig` — protocol codec

Pure functions, no I/O. Two operations:

- `encode(allocator, msg: Message) -> []u8` — serialize a request/response/notification to a single line ending in `\n`.
- `decodeLine(allocator, line: []const u8) -> !Message` — parse one stdout line.

`Message` is a tagged union: `{request: {id, method, params}, response: {id, result|error}, notification: {method, params}}`. Decoding distinguishes by presence of `id` and `method`/`result`/`error`.

No streaming parser; messages are line-bounded by protocol contract. If a line fails to parse, the supervisor logs and discards (does not crash the agent — that's the agent's bug to fix).

### `src/agents/worker.zig` — one worker, one state machine

Represents a single child-process worker. Holds:

```
Worker {
  id:                u64,          // monotonic, assigned by supervisor
  kind:              []const u8,   // 'ocr' / 'prompt' / ...
  pid:               std.process.Child,
  stdin_writer:      std.fs.File.Writer,
  stdout_reader:     std.fs.File.Reader,   // owned by per-worker reader thread
  stderr_log_file:   std.fs.File,          // stderr piped to disk
  state:             WorkerState,
  current_job_id:    ?[]const u8,
  capabilities:      ?AgentCapabilities,   // populated after initialize
  next_request_id:   u64,
}

WorkerState = enum { spawning, idle, busy, draining, dead }
```

State transitions:

```
            spawn()
   (start)──────────►[spawning]
                          │  initialize response
                          ▼
            assign(job)
   ┌────────────────────[idle]◄──────┐
   │                          ▲      │ response from agent
   ▼                          │      │
[busy]──── response ──────────┘      │
   │                                  │
   │ pipe EOF / non-zero exit         │
   ▼                                  │
[dead] ─── respawn() ─────────────────┘
```

The reader thread is the worker's owner of `stdout_reader`. It loops:
```
while (read_line) |line| {
    msg = jsonrpc.decodeLine(line) catch { log_warn; continue };
    response_channel.send(.{ worker_id, msg });
}
on EOF: response_channel.send(.{ worker_id, .dead });
```

### `src/agents/supervisor.zig` — pool manager

Public surface (called by dispatcher):

```
Supervisor.init(allocator, config: AgentConfig) -> Supervisor
Supervisor.acquire(kind: []const u8) -> ?*Worker
  // returns an idle worker; spawns a fresh one if cap not yet reached;
  // returns null if cap reached and all busy
Supervisor.release(worker: *Worker)
  // mark idle (after response received)
Supervisor.markDead(worker: *Worker)
  // pipe EOF / unexpected exit; idle_by_kind set is cleaned
Supervisor.shutdownAll()
  // graceful: send 'shutdown' to each, await 'exit' notif, reap
```

Holds:
- `workers: ArrayList(Worker)`
- `idle_by_kind: StringHashMap(ArrayList(*Worker))`
- `current_count_by_kind: StringHashMap(u32)`

All operations behind a `std.Io.Mutex` (separate from the HTTP `req_mutex` to avoid serializing dispatch behind HTTP).

### `src/agents/dispatcher.zig` — the loop

Runs on its own thread, started from `main.zig` after `Db.open` and supervisor init.

```
loop:
  // 1. Drain responses from workers (non-blocking, up to N per tick)
  while (response_channel.tryReceive()) |evt| {
    handleResponse(evt)   // mark job done/failed; insert extractions/prompt_outputs row;
                          //   write job_logs from notifications; call supervisor.release()
  }

  // 2. Poll DB for queued, dispatchable jobs
  for (kind in ["ocr", "prompt", "slice"]) {  // slice stays sync within HTTP for now
    while (true) {
      job = nextDispatchable(kind) orelse break
      worker = supervisor.acquire(kind) orelse break  // cap reached
      sendRequest(worker, job)
      markJobRunning(job)
    }
  }

  sleep(50ms)
```

`nextDispatchable(kind)` runs the query from the schema section. For `ocr`: any `queued`+`type='ocr'` job. For `prompt`: queued+`type='prompt'` AND the LEFT JOIN gate passes (all required slices have extractions).

DB writes from the dispatcher go through the existing `req_mutex` (same mutex HTTP handlers use). The dispatcher acquires it only for the brief write — never holds it across a network call to an agent.

### `src/api/sse.zig` — server-sent events

Helper for held-open `text/event-stream` connections. v1 implementation: the SSE handler polls the DB every 500 ms for new `job_logs` and `jobs` rows for the watched `job_id`, emits new ones as `data: <json>\n\n`. Disconnects cleanly when the job reaches a terminal state.

Future upgrade path (deferred): an in-process broadcast channel that the dispatcher posts to and SSE handlers subscribe to, eliminating the poll. Noted only.

### New HTTP routes

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/api/v1/projects/:id/jobs/ocr` | Enqueue OCR for one slice. Body: `{slice_filename}`. |
| `POST` | `/api/v1/projects/:id/jobs/ocr/all` | Enqueue OCR for every slice without an extraction. |
| `POST` | `/api/v1/projects/:id/jobs/prompt` | Enqueue one prompt. Body: `{prompt_name}`. May queue even if required slices not yet extracted — dispatcher gates. |
| `POST` | `/api/v1/projects/:id/jobs/prompt/all` | Enqueue all 5 prompts at once. |
| `GET` | `/api/v1/projects/:id/extractions` | List extraction rows for project. |
| `GET` | `/api/v1/projects/:id/extractions/:slice_filename` | Download the `.md`. |
| `GET` | `/api/v1/projects/:id/prompts` | List prompt_outputs rows for project. |
| `GET` | `/api/v1/projects/:id/prompts/:prompt_name` | Download the prompt's `.md`. |
| `GET` | `/api/v1/jobs/:id/logs` | One-shot list of all log lines for a job. |
| `GET` | `/api/v1/jobs/:id/stream` | SSE: live log lines + status updates until terminal state. |

### Slicing-job changes

Existing `POST /api/v1/projects/:id/jobs/slice` already does the page-range → `slices/<name>.pdf` work. It needs two small extensions:

1. **Parse `kind` / `kind_key` from the slice name** using a regex per the convention table:
   - `^annexure-(i|ii|iii|iv)\.pdf$` → `kind='annexure', kind_key=<group1>`
   - `^rud-(\d{2})\.pdf$` → `kind='rud', kind_key=<group1>`
   - else → `kind='other', kind_key=NULL`
2. **Write `kind` / `kind_key`** into the new `slices` columns on insert.

Per the slicing-convention open question, non-conforming names produce a warning in the slice job's `results` JSON but are accepted.

### Startup sequence change (`src/main.zig`)

Existing sequence (per logos `CLAUDE.md`):
1. Parse args
2. `AppConfig.load`
3. Create `data_dir`
4. `lock.acquire`
5. `Db.open` (runs migrations)
6. `api_server.serve` (binds + loops forever)

New steps inserted between 5 and 6:

5a. `agent_config.load(data_dir)` — read `agents.json` (or default).
5b. `supervisor.init(agent_config)` — no spawning yet; pool starts empty.
5c. `spawn_dispatcher_thread()` — runs `dispatcher.loop` until shutdown.

Shutdown (Ctrl+C / SIGINT) becomes:
1. Stop accepting new HTTP requests.
2. Signal dispatcher to stop polling.
3. `supervisor.shutdownAll()` — graceful agent exits, with a 5 s deadline before SIGKILL.
4. Close DB, release lock.

### Threading model recap

| Thread | Owns | Acquires `req_mutex`? |
|---|---|---|
| HTTP accept loop | listening socket | no |
| Per-HTTP-request worker | one client conn | yes, around DB writes |
| Dispatcher | DB poll loop, agent request writes | yes, around DB writes |
| Per-worker stdout reader | one child stdout pipe | no (posts to response channel) |
| Supervisor (callable from any thread) | worker pool state | own internal mutex |

`req_mutex` is still the only mutex that touches the DB. Brief acquisitions, no work held inside it.

---

## File layout on disk

_TBD — to be designed in the next section._

Anticipated:

```
<data_dir>/
  data.db
  daemon.lock
  <project_id>/
    chargesheet.pdf
    slices/
      annexure-i.pdf
      annexure-ii.pdf
      annexure-iii.pdf
      annexure-iv.pdf
      rud-01.pdf
      rud-02.pdf
      ...
    extractions/
      annexure-i/
        annexure-i.md
        annexure-i.meta.json
      annexure-ii/
      ...
      rud-01/
      ...
    prompts/
      charge_memo_analysis.md
      imputation_scrutiny.md
      time_chart.md
      evidence_audit.md
      objection_brief.md
    logs/
      job-<id>.log
```

Prompt outputs live at the **project level**, not per-slice, because each prompt consumes multiple slices and produces a single project-level analysis.

---

## Job lifecycle walkthroughs

Five concrete traces that together exercise every component in the design. Components in the diagrams:

```
UI    – the Svelte SPA in the user's browser
API   – an HTTP handler thread inside logos
DB    – SQLite via Db module (writes acquire req_mutex)
DISP  – the dispatcher thread inside logos
SUP   – the supervisor (callable from any thread; own mutex)
W     – a worker child process (Python ocr_agent or prompt_agent)
MODEL – upstream API (Gemini / Claude)
```

### 1. Cold start: first OCR job for a project

```
UI            API            DB           DISP          SUP          W            MODEL
 │             │              │            │             │            │             │
 │ POST .../jobs/ocr           │            │             │            │             │
 │ {slice:annexure-i.pdf}      │            │             │            │             │
 ├────────────►│              │            │             │            │             │
 │             │ INSERT jobs(type='ocr',   │             │            │             │
 │             │   status='queued',        │             │            │             │
 │             │   payload={slice_filename})            │            │             │
 │             ├─────────────►│            │             │            │             │
 │             │ 201 {job_id} │            │             │            │             │
 │◄────────────┤              │            │             │            │             │
 │ GET .../jobs/<id>/stream  (SSE; held open)            │            │             │
 ├────────────►│ ··· SSE poll loop begins ···            │            │             │
 │             │              │            │             │            │             │
 │             │              │   (≤50ms)  │             │            │             │
 │             │              │            │  poll: SELECT * WHERE status='queued'   │
 │             │              │            │   AND type='ocr' LIMIT 1│            │             │
 │             │              │◄───────────┤             │            │             │
 │             │              │ row        │             │            │             │
 │             │              ├───────────►│             │            │             │
 │             │              │            │ acquire('ocr')           │            │             │
 │             │              │            ├────────────►│            │             │
 │             │              │            │             │ no idle; count=0 < cap=2 │             │
 │             │              │            │             │ spawn python3 ocr_agent  │             │
 │             │              │            │             ├───────────►│             │
 │             │              │            │             │ {initialize, id=0}        │
 │             │              │            │             ├───────────►│             │
 │             │              │            │             │            │ (loads google-genai SDK)│
 │             │              │            │             │ {result: capabilities}    │
 │             │              │            │             │◄───────────┤             │
 │             │              │            │             │ W -> IDLE  │             │
 │             │              │            │◄────────────┤            │             │
 │             │              │            │ ← Worker handle           │            │             │
 │             │              │ UPDATE jobs SET status='running'       │            │             │
 │             │              │◄───────────┤             │            │             │
 │             │              │            │ send ocr.extract request  │             │
 │             │              │            │   over stdin              │             │
 │             │              │            ├────────────────────────►│             │
 │             │              │            │                          │ upload chunk│
 │             │              │            │                          ├────────────►│
 │             │              │            │                          │ stream gen  │
 │             │              │            │                          │◄──tokens────┤
 │             │              │            │ ← progress notif          │             │
 │             │              │            │◄─────────────────────────┤             │
 │             │              │ INSERT job_logs                       │             │
 │             │              │ UPDATE jobs SET progress=0.04          │             │
 │             │              │◄───────────┤             │            │             │
 │             │ (SSE poll picks up new log row, status, progress)    │             │
 │ data: {progress:0.04, log:"…"}                       │             │            │             │
 │◄────────────┤              │            │             │            │             │
 │             │              │            │                          │ … many more progress     │
 │             │              │            │                          │     notifs over ~10 min  │
 │             │              │            │                          │             │             │
 │             │              │            │ ← response (result)       │             │
 │             │              │            │◄─────────────────────────┤             │
 │             │              │ INSERT extractions row                 │             │
 │             │              │ UPDATE jobs SET status='completed',    │             │
 │             │              │                results=mirror          │             │
 │             │              │◄───────────┤             │            │             │
 │             │              │            │ release(W) │             │            │             │
 │             │              │            ├────────────►│ W -> IDLE  │             │
 │             │              │            │             │            │             │
 │             │ (SSE handler sees status terminal)      │             │            │             │
 │ data: {status:"completed"} \n\n                       │             │            │             │
 │◄────────────┤ close stream │            │             │            │             │
```

**Total wall clock**: ~10 minutes (dominated by Gemini's streaming). **Cold-start cost** (spawn + initialize): ~1–2 seconds, amortized to zero for jobs 2..N on the same warm worker.

### 2. Subsequent OCR job (warm path)

Same as above, except `SUP.acquire("ocr")` returns the now-IDLE worker without spawning. No `python3` startup. No Gemini SDK reload.

The HTTP `req_mutex` is held only for two brief windows: the initial `INSERT jobs` and the final `UPDATE jobs + INSERT extractions`. The 10 minutes of streaming happen entirely in agent + dispatcher land, never touching the HTTP path.

### 3. Five-prompt fan-out

Preconditions: all required slices for all 5 prompts have `extractions` rows. User clicks "Run all prompts."

```
UI            API           DB         DISP        SUP                W₁..W₅                MODEL
 │             │             │          │           │                  │                      │
 │ POST .../jobs/prompt/all  │          │           │                  │                      │
 ├────────────►│             │          │           │                  │                      │
 │             │ INSERT × 5 (one row per prompt_name, status='queued') │                      │
 │             ├────────────►│          │           │                  │                      │
 │             │ 201 {job_ids:[…]}      │           │                  │                      │
 │◄────────────┤             │          │           │                  │                      │
 │ GET .../projects/<id>/jobs/stream  (SSE on the project, not per-job)│                      │
 ├────────────►│             │          │           │                  │                      │
 │             │             │          │ tick: gate check passes for all 5                   │
 │             │             │          │   (LEFT JOIN: zero missing extractions)              │
 │             │             │          │ acquire('prompt') × 5  (warm: 5 IDLE workers exist?  │
 │             │             │          │                          if not, spawn up to cap=5)  │
 │             │             │          ├──────────►│                  │                      │
 │             │             │          │           │ returns W₁..W₅ (interleaved with spawns) │
 │             │             │          │◄──────────┤                  │                      │
 │             │             │          │ send prompt.run × 5  (one per worker, different     │
 │             │             │          │              prompt_name + slices map)              │
 │             │             │          ├──────────────────────────►│                         │
 │             │             │ UPDATE jobs SET status='running' × 5                           │
 │             │             │◄─────────┤           │                  │                      │
 │             │             │          │                              │ Anthropic calls run  │
 │             │             │          │                              │   in parallel        │
 │             │             │          │                              ├─────────────────────►│
 │             │             │          │                              │◄── streamed Markdown │
 │             │             │          │ ← progress notifs from all 5 (interleaved)           │
 │             │             │          │◄─────────────────────────┤                          │
 │             │             │ UPDATE jobs.progress × 5  +  INSERT job_logs                   │
 │             │             │◄─────────┤           │                  │                      │
 │             │             │          │                              │                      │
 │             │             │          │ ← response from W₃ (first to finish)                 │
 │             │             │          │◄─────────────────────────┤                          │
 │             │             │ INSERT prompt_outputs(prompt='time_chart', …)                 │
 │             │             │ UPDATE jobs SET status='completed'      │                      │
 │             │             │◄─────────┤           │ release(W₃) → IDLE                       │
 │             │             │          │ … same for W₁, W₂, W₄, W₅ as each finishes …         │
```

**Concurrency**: 5 simultaneous Anthropic streams. **Wall clock**: ≈ longest single prompt latency, not sum. **All 5 workers stay warm** after completion — second run of the same fan-out has no spawn cost.

### 4. Cancellation mid-job

User clicks "Cancel" on a running OCR job that's been going for 4 minutes.

```
UI            API            DB           DISP          SUP          W            MODEL
 │ POST .../jobs/<id>/cancel               │             │            │             │
 ├────────────►│              │            │             │            │             │
 │             │ dispatcher.cancelJob(<id>) — in-process call          │             │
 │             ├──────────────────────────►│             │            │             │
 │             │              │            │ find worker by job_id    │             │
 │             │              │            │ send notifications/cancelled            │
 │             │              │            │   {requestId, reason="user_requested"} │
 │             │              │            ├────────────────────────►│             │
 │             │              │            │                          │ aborts stream│
 │             │              │            │                          │ deletes Gemini Files API resource │
 │             │              │            │                          ├─DELETE──────►│
 │             │              │            │ ← error response          │             │
 │             │              │            │   {code:-32099, msg:"canceled"}        │
 │             │              │            │◄─────────────────────────┤             │
 │             │              │ UPDATE jobs SET status='canceled',     │             │
 │             │              │                error='user_requested'  │             │
 │             │              │◄───────────┤             │            │             │
 │             │              │            │ release(W) → IDLE         │             │
 │             │ 202 Accepted │            │             │            │             │
 │◄────────────┤              │            │             │            │             │
 │ (SSE handler sees status='canceled')                 │             │            │             │
 │ data: {status:"canceled"} \n\n close stream          │             │            │             │
```

**Key invariants:**
- `cancelJob` is an in-process call (no DB write at request time) — the API handler returns 202 immediately.
- The agent's response (with error -32099) is the trigger for the DB status update — single writer, no race.
- **Worker stays alive** for the next request. Only the in-flight upstream resource (Gemini Files API upload) is cleaned up.

### 5. Worker crash mid-job

The Python agent crashes (segfault, OOM, unhandled exception). Worker's stdout pipe closes.

```
UI            API            DB           DISP          SUP          W            MODEL
 │             │              │            │ tick: drain responses    │             │
 │             │              │            │ ← {worker_id, .dead}     │             │
 │             │              │            │◄─────────────────────────┤ (EOF)       │
 │             │              │            │ retry_attempts[job_id]?  │             │
 │             │              │            │   key absent → first attempt           │
 │             │              │            │ retry_attempts[job_id] = 1              │
 │             │              │            │ markDead(worker)         │             │
 │             │              │            ├────────────►│ count-=1   │             │
 │             │              │ UPDATE jobs SET status='queued', error=NULL          │
 │             │              │   (re-enqueue, same job_id, same payload)            │
 │             │              │◄───────────┤             │            │             │
 │             │              │            │                          │             │
 │             │              │            │ next tick: dispatchable again           │
 │             │              │            │ acquire('ocr') → spawn fresh worker     │
 │             │              │            │             │ (cold start, 1-2s)        │
 │             │              │            ├────────────►│ spawn      │             │
 │             │              │            │             │            │ initialize  │
 │             │              │            │             │◄───────────┤             │
 │             │              │            │ send same ocr.extract request again    │
 │             │              │            ├────────────────────────►│             │
 │             │              │            │                          │ resumes from scratch     │
 │             │              │            │                          ├────────────►│
```

**Retry policy:**
- First crash → re-queue (`retry_attempts` in dispatcher's memory).
- Second crash on the same `job_id` → mark `status='failed'`, `error='worker_died: 2 attempts'`. UI shows failure, user can manually retry.
- `retry_attempts` map is in-memory only, lost on daemon restart. Daemon restart with any `running` jobs marks them `failed` with `error='daemon_restarted'` (see _Error handling_).

**No state lost**: jobs are designed to be idempotent. Re-running the same OCR job overwrites the `extractions` row + the `.md` / `.meta.json` files at deterministic paths. The user pays for Gemini twice, but gets a successful run.

### Composition properties

These walkthroughs together demonstrate:
- **No HTTP request blocks on agent work.** All long-running operations happen in the dispatcher loop + worker processes; HTTP returns 201/202 in milliseconds.
- **No DB write happens outside `req_mutex`.** The dispatcher acquires it for brief windows the same way HTTP handlers do.
- **Single writer to the agent process per worker** (dispatcher's `sendRequest`). The reader thread is read-only on the pipe.
- **Agent processes outlive jobs.** Crashes reset just one worker; the pool self-heals.
- **All terminal job states are observable via SSE**, so the UI never needs to poll the REST endpoints during a long-running operation.

---

## Error handling and recovery

### Guiding principles

1. **Fail fast for persistent errors, retry once for transient ones.** No loops, no exponential backoff trees. The user can always re-run from the UI; idempotent overwrites make this safe.
2. **Single writer always wins.** Job state transitions happen in the dispatcher when it receives a response (or detects a pipe death). The API never writes a terminal status directly.
3. **Log enough to diagnose without enabling debug mode.** Every error path writes a `job_logs` row at `level='error'` and populates `jobs.error` with a one-line summary; the full context goes into stderr captured to the worker's log file.
4. **Job artifacts on disk are the source of truth.** A successful re-run overwrites them; partial artifacts from a failed run can be left in place — the next successful run will overwrite cleanly.

### Failure-mode catalog

| Failure | Where detected | Recovery (v1) | DB result | User-facing |
|---|---|---|---|---|
| **Agent crashes (pipe EOF)** | dispatcher reader-thread | re-queue once via in-memory `retry_attempts`; second crash → fail | first: `status='queued'`; second: `status='failed', error='worker_died: 2 attempts'` | SSE shows brief blip then "failed"; user clicks re-run |
| **Upstream 4xx (Gemini/Anthropic)** | agent (`-32001` to host) | mark job failed, surface body in `jobs.error` | `status='failed'` | UI shows the upstream error message verbatim |
| **Upstream 429 rate limit** | agent (`-32002` with `retry_after_s`) | dispatcher sleeps `retry_after_s` then retries same job, **up to once**; second 429 → fail | first attempt: `status` returns to `'queued'` briefly; second: `'failed'` | UI shows "rate limited, retrying in Ns…" then either success or fail |
| **Output truncated (max tokens)** | OCR agent self-detects via `finish_reason != STOP` | mark failed (not retried — same input will hit same cap) | `status='failed', error='max_tokens'` | UI suggests slicing into smaller chunks before retry |
| **Missing/corrupt slice PDF** | agent on file read (`-32003`) | fail immediately | `status='failed', error='input_invalid: …'` | UI shows which file is missing; user re-runs slicing first |
| **Missing API key / auth** | agent on first upstream call (`-32005`) | fail immediately; subsequent jobs to that agent will hit the same wall | `status='failed', error='auth_missing: GEMINI_API_KEY'` | UI banner: "Configure your Gemini API key in settings" |
| **Disk full / write failure** | agent on `write_text` (`-32603` Internal error) | fail immediately | `status='failed', error='disk_write: ENOSPC'` | UI shows the error; user frees disk and re-runs |
| **JSON-RPC parse error from agent** | dispatcher's decode | log warning, discard line; do NOT terminate the worker | (no DB change) | nothing visible; warning in daemon stderr |
| **Worker startup fails (binary missing, init crashes)** | supervisor.acquire() on first spawn | mark the just-assigned job failed; subsequent acquires keep trying (config might be fixed) | `status='failed', error='spawn_failed: ENOENT python3'` | UI shows the error; user fixes `agents.json` |
| **Daemon restart with running jobs** | startup migration step | mark all `running` jobs `failed`, `error='daemon_restarted'` before opening the HTTP server | `status='failed'` for all in-flight | UI shows these as failed on next load; user clicks re-run |
| **Schema migration v1→v2 fails partway** | `Db.open` migration runner | abort startup, do NOT touch v1 data; print actionable error | (no change; v1 schema preserved) | logos refuses to start; user reads error, reports bug |
| **Agent config file malformed** | `agent_config.load` at startup | abort startup with path + parse-error line/col | n/a | logos refuses to start; user fixes `agents.json` |
| **Prompt's required slices not yet extracted** | dispatcher gate query | leave job `queued`; check again next tick | `status='queued'` (unchanged) | UI shows "waiting on OCR for annexure-iii"; auto-progresses |
| **Soft-check warning on prompt output** | prompt_agent | save the markdown anyway with warnings populated | `prompt_outputs.warnings = ["…"]`; `status='completed'` | UI shows a yellow banner over the rendered Markdown |

### Subsections worth calling out

**Daemon restart with running jobs.** On startup, after `Db.open` but before binding the HTTP port (and before starting the dispatcher), run:

```sql
UPDATE jobs SET status='failed',
                error='daemon_restarted',
                updated_at=?
WHERE  status='running' OR status='queued';
```

This is heavy-handed — `queued` jobs would have run if logos hadn't restarted. We mark them failed anyway because we don't know which were already mid-stream on an agent and which were untouched. The user re-runs from the UI; idempotency makes this safe.

A more surgical recovery (only fail `running`; keep `queued`) is possible once we have an idempotency token on the agent side (so a re-sent request to a fresh worker doesn't duplicate the Gemini/Anthropic call). Out of scope for v1.

**Schema migration v1→v2 failure.** The migration in `Db.open` runs as a single SQLite transaction (`BEGIN; … ; COMMIT;` wrapping all the DDL). If any step fails, SQLite rolls back automatically, leaving the v1 schema intact. The startup code surfaces the error like:

```
ERROR: failed to migrate database from schema v1 to v2.
       step: rebuild jobs table
       reason: SQLITE_CONSTRAINT: CHECK constraint failed: type IN ('slice', …)
       file: <data_dir>/data.db (v1 schema preserved)
       refusing to start. report this at <issue tracker>.
```

logos exits non-zero. No half-migrated state ever reaches the running daemon.

**Rate limiting (-32002).** The agent receives a 429 from the upstream, parses `retry-after` header (or response body's `retry_after_s` for Anthropic), and returns:

```json
{"jsonrpc":"2.0","id":<n>,"error":{"code":-32002,"message":"rate limited",
 "data":{"retry_after_s":30,"upstream":"anthropic.messages.create"}}}
```

Dispatcher behavior on receipt:
- If `retry_after_s` ≤ 60: sleep that long, then re-send the same request to the same warm worker. Increment a per-job `rate_retry_attempts` (in-memory).
- If `retry_after_s` > 60 OR `rate_retry_attempts >= 1`: mark the job failed with `error='rate_limited (retry_after_s=N, attempts=K)'`. User can re-run later.

Rationale: a single-user local tool that rate-limits more than once on a single job is probably hitting a quota wall, not a transient burst. Better to fail loudly than silently delay.

**Daemon-level errors that should NEVER happen.** If any of these are observed, it's a bug:
- Two `INSERT extractions` for the same `(project_id, slice_filename)` racing — the PK enforces single-writer; if SQLite reports a constraint violation, there's a logic bug in the dispatcher.
- A worker in BUSY state with no `current_job_id` set, or vice versa — invariant violation in `worker.zig`.
- A response arriving for a `job_id` not in `jobs` table — same.

These should log loudly and crash the daemon in debug builds; in release, log and try to recover (mark the orphan job failed and drop the response).

### Observability surface

Three places to look when something's wrong:

1. **`jobs.error`** — one-line summary per failed job. Visible in UI.
2. **`job_logs`** — all `notifications/log` from agents during the run. Visible in UI per job.
3. **Worker stderr log files** — `<data_dir>/<project_id>/logs/job-<id>.log` (or `<data_dir>/agent-stderr/<worker_id>.log` for daemon-level errors before a job is assigned). Plaintext, tail-able from terminal. Never parsed by logos.

Three corresponding levels of investigation: glance, replay, deep-dive.

---

## Observability: tokens, cost, and usage stats

Every agent run already returns `input_tokens`, `output_tokens`, `latency_s`, and `model` in its response (designed in the JSON-RPC protocol section). Those land in `extractions` and `prompt_outputs`. This section is about making them **queryable as rollups** so the UI can show "how much did this project cost?" / "which agent kind is eating the most tokens?" / "show me the slowest jobs."

### Per-job metadata already persisted

| Column | Source | Where |
|---|---|---|
| `model` | agent's response | `extractions.model`, `prompt_outputs.model` |
| `input_tokens` | upstream usage metadata (nullable on partial runs) | both |
| `output_tokens` | upstream usage metadata | both |
| `latency_s` | wall-clock measured by agent | both |
| `pages`, `page_markers_found` | OCR-specific | `extractions` only |
| `warnings` | soft-check JSON array | `prompt_outputs` only |
| `created_at` | dispatcher write time | both |

Plus per-line agent logs in `job_logs` (used for live status, replayable per job).

### Cost computation: hardcoded pricing + write-time denormalization

`extractions` and `prompt_outputs` carry two nullable cost columns (`input_cost_usd`, `output_cost_usd`) defined in their `CREATE TABLE` in v2.sql. Pricing lives in `src/agents/pricing.zig` as a static lookup (model → (input_per_million_usd, output_per_million_usd)). Seeded for v1 with the models we ship:

```zig
pub const PRICING = .{
    .{ "gemini-2.5-flash",  0.30,  2.50 },
    .{ "claude-sonnet-4-6", 3.00, 15.00 },
    // add rows as new models are introduced
};
```

**At write time**, the dispatcher computes:

```
input_cost_usd  = input_tokens  * PRICING[model].input_per_million  / 1_000_000
output_cost_usd = output_tokens * PRICING[model].output_per_million / 1_000_000
```

…and stores both alongside the row. Why denormalize: pricing changes over time. Storing the cost at the time of the run preserves historical accuracy even if we update the constants in a later release. Unknown models (`PRICING` miss) land `NULL` cost — the stats endpoint surfaces them as "uncosted" rather than erroring out.

**Why USD as the storage currency**: that's what upstream APIs publish their pricing in. UI converts to INR (or the user's chosen display currency) using a configurable rate (default 83 INR/USD; settable from the UI settings page). Keeping the DB currency-stable means historical totals don't shift if the rate changes.

### Stats queries

```sql
-- Lifetime totals across all projects, broken down by agent kind
SELECT 'ocr' AS kind,
       count(*) AS runs,
       sum(input_tokens) AS in_tokens,
       sum(output_tokens) AS out_tokens,
       sum(input_cost_usd + output_cost_usd) AS cost_usd,
       avg(latency_s) AS avg_latency_s
FROM extractions
UNION ALL
SELECT 'prompt' AS kind, count(*), sum(input_tokens), sum(output_tokens),
       sum(input_cost_usd + output_cost_usd), avg(latency_s)
FROM prompt_outputs;

-- Per-model breakdown (useful when you have multiple OCR models or per-prompt model overrides later)
SELECT model, count(*) AS runs, sum(input_tokens) AS in_tok,
       sum(output_tokens) AS out_tok,
       sum(input_cost_usd + output_cost_usd) AS cost_usd
FROM (
  SELECT model, input_tokens, output_tokens, input_cost_usd, output_cost_usd FROM extractions
  UNION ALL
  SELECT model, input_tokens, output_tokens, input_cost_usd, output_cost_usd FROM prompt_outputs
)
GROUP BY model
ORDER BY cost_usd DESC;

-- Per-project totals (used by the project dashboard)
SELECT
  (SELECT coalesce(sum(input_cost_usd + output_cost_usd), 0) FROM extractions    WHERE project_id=?) AS ocr_cost,
  (SELECT coalesce(sum(input_cost_usd + output_cost_usd), 0) FROM prompt_outputs WHERE project_id=?) AS prompt_cost,
  (SELECT coalesce(sum(input_tokens),  0) FROM extractions    WHERE project_id=?) +
  (SELECT coalesce(sum(input_tokens),  0) FROM prompt_outputs WHERE project_id=?) AS total_in_tokens,
  (SELECT coalesce(sum(output_tokens), 0) FROM extractions    WHERE project_id=?) +
  (SELECT coalesce(sum(output_tokens), 0) FROM prompt_outputs WHERE project_id=?) AS total_out_tokens;

-- Slowest jobs (for diagnosing degraded performance / quota issues)
SELECT 'extraction' AS kind, project_id, slice_filename AS subject, model, latency_s, input_tokens + output_tokens AS total_tokens, created_at
FROM extractions
UNION ALL
SELECT 'prompt' AS kind, project_id, prompt_name AS subject, model, latency_s, input_tokens + output_tokens AS total_tokens, created_at
FROM prompt_outputs
ORDER BY latency_s DESC
LIMIT 20;

-- Daily time series for the stats chart
SELECT date(created_at) AS day,
       sum(input_tokens)  AS in_tokens,
       sum(output_tokens) AS out_tokens,
       sum(input_cost_usd + output_cost_usd) AS cost_usd
FROM (
  SELECT created_at, input_tokens, output_tokens, input_cost_usd, output_cost_usd FROM extractions
  UNION ALL
  SELECT created_at, input_tokens, output_tokens, input_cost_usd, output_cost_usd FROM prompt_outputs
)
GROUP BY day
ORDER BY day DESC;
```

All of these run on the existing tables — no new tables required beyond the cost columns.

### New HTTP routes

| Method | Path | Returns |
|---|---|---|
| `GET` | `/api/v1/stats` | Lifetime totals: per-kind, per-model, top-cost projects |
| `GET` | `/api/v1/stats/project/:id` | Per-project totals + per-slice / per-prompt drilldown |
| `GET` | `/api/v1/stats/timeseries?from=YYYY-MM-DD&to=YYYY-MM-DD` | Daily series for the chart |
| `GET` | `/api/v1/stats/slow?limit=20` | Slowest jobs (latency desc) |

Add to the route table in `src/api/router.zig`; handlers live in `src/api/handlers_stats.zig`.

### UI surfacing

Two places the SPA renders stats:

1. **Per-project panel** on the existing project page — total cost, total tokens, agent breakdown for this project only. Calls `/api/v1/stats/project/:id`.
2. **Dedicated `/stats` page** — global usage, model breakdown, daily chart, slow-jobs table. Calls the four stats endpoints.

INR conversion is a UI-side concern (settings page stores `display_currency_rate` in localStorage, default `83.0`). DB stays in USD.

### Pricing maintenance

The pricing constants live in code, not config. When upstream prices change:

1. Update `src/agents/pricing.zig` with a new row (do NOT modify the existing row — old jobs reference historical pricing through their stored `*_cost_usd` columns; new jobs use the new constants).
2. Bump logos's patch version.
3. Optionally annotate the changelog with the effective date for users to know which rate their future jobs will see.

Since we store cost at write time, historical rollups are accurate even after pricing changes. No backfill, no migration.

---

## Testing strategy

### Five layers

| Layer | Scope | Runner | Network? | Cost |
|---|---|---|---|---|
| **1. Pure unit** | individual functions (codec, regex, schema parsing) | `zig build test`, `pytest -m unit` | no | free |
| **2. Component** | one module with mocks at its boundaries (supervisor + mock agent; DB module against in-memory SQLite; HTTP handler with fake DB) | `zig build test`, `pytest` | no | free |
| **3. Protocol conformance** | the full JSON-RPC dance against each real agent binary | `pytest -m protocol` | no (mocked upstreams via `responses` lib) | free |
| **4. End-to-end mocked** | full pipeline (slice → OCR → prompt) with Gemini/Anthropic stubbed | `pytest -m e2e` | no | free |
| **5. End-to-end live** | same as 4 but against real Gemini/Anthropic | `pytest -m live` (opt-in via env var, gated in CI) | yes | a few rupees per run |

Layers 1–4 run in CI on every commit. Layer 5 runs manually before release, or via a scheduled nightly that touches a small fixture chargesheet.

### The mock agent (`tests/mock_agent.py`)

A minimal stand-in that speaks `lambe-haath/1` and is used by **both** the Zig supervisor/dispatcher tests and the Python protocol harness. Behaviour controlled by env vars:

| Env var | Effect |
|---|---|
| `MOCK_CAPABILITIES` (JSON) | what to return in the `initialize` response |
| `MOCK_LATENCY_S` | sleep this long inside each method handler before responding |
| `MOCK_PROGRESS_TICKS` (int) | emit N `notifications/progress` events between request and response |
| `MOCK_FAIL_AFTER_N` (int) | crash with `os._exit(1)` after handling N requests |
| `MOCK_HANG_AFTER_N` (int) | stop reading stdin after N requests (simulates wedge) |
| `MOCK_PARSE_GARBAGE_AFTER_N` | emit a non-JSON line on stdout (tests codec robustness) |

This is the workhorse for testing every state machine edge. We can verify:
- Pool grows from 0 → cap as jobs arrive (multiple `MOCK_LATENCY_S` mocks blocking the queue)
- Crash → re-queue → success path (`MOCK_FAIL_AFTER_N=1`)
- Crash → re-queue → crash → fail (`MOCK_FAIL_AFTER_N=0` permanent)
- Cancellation aborts mid-progress (`MOCK_PROGRESS_TICKS=50`, cancel after tick 5)
- Parse-error tolerance (`MOCK_PARSE_GARBAGE_AFTER_N=1`)

The mock agent is **not** a Python implementation detail of testing — it's a deliverable artifact, committed and supported, so a future Go or Rust agent author can run the same protocol-conformance harness against their binary.

### Test inventory by component

**`src/agents/jsonrpc.zig`** (codec)
- Round-trip every message shape (request / response / notification, with and without params, with and without `_meta`).
- Reject lines with embedded `\n` in string fields (must be escaped).
- Decode `error` responses with `code` + `data` populated.
- Decode notifications correctly (no `id` field).
- Parser robustness on malformed input — returns error, doesn't panic.

**`src/agents/worker.zig`** (state machine)
- Spawn → initialize → IDLE transition (against mock agent with `MOCK_CAPABILITIES`).
- IDLE → BUSY on `assign(job)`; BUSY → IDLE on response.
- Pipe EOF transitions to DEAD; `current_count_by_kind` decrements.
- Reader thread posts the correct event types (`response`, `notification`, `dead`) to the channel.

**`src/agents/supervisor.zig`** (pool)
- Lazy spawn: pool starts at 0, first `acquire('ocr')` spawns one.
- Cap enforcement: 3rd `acquire` returns null when cap=2 and both busy.
- Respawn on death: after `markDead`, next `acquire` spawns a fresh worker.
- `shutdownAll` waits for in-flight responses or hits the 5 s SIGKILL deadline.

**`src/agents/dispatcher.zig`** (dispatch loop)
- Queued OCR job → assigned to idle worker → status transitions → extractions row written.
- Prompt job with unmet preconditions stays queued; becomes dispatchable after extractions appear.
- Crash mid-job + re-queue once → success on second attempt; both attempts visible in `job_logs`.
- Two crashes on same job → `status='failed'`, retry_attempts cleared.
- Cancellation via `cancelJob` — outstanding worker receives the notification; response with `-32099` transitions job to `'canceled'`.

**`src/db/migrations.zig`** (migration v1→v2)
- Open a v1 fixture DB → run migration → assert all v2 tables and indexes exist, v1 row data is preserved (projects, slices, jobs).
- Inject a constraint violation into the migration → assert v1 schema is intact after rollback (transaction wrapper works).
- Backfill kind/kind_key from existing slice filenames (regex match correct).

**`src/db/extractions.zig` / `prompt_outputs.zig` / `job_logs.zig`**
- Insert → select round-trip with all field types.
- Re-insert on conflict → row is updated, not duplicated (idempotency invariant).
- FK cascade: deleting a slice removes its extraction; deleting a project removes everything.

**`src/api/handlers_ocr.zig` / `handlers_prompts.zig`**
- POST `/jobs/ocr` enqueues a row and returns the `job_id`.
- POST `/jobs/ocr/all` enqueues N rows where N = slices without extractions.
- POST `/jobs/prompt/all` enqueues exactly 5 prompt jobs.
- GET `/extractions/:slice_filename` 404s if the extraction doesn't exist.

**`src/api/handlers_stats.zig`**
- GET `/stats` returns per-kind, per-model, and top-cost-project rollups against a fixture DB with known rows.
- Per-project endpoint sums correctly when some rows have `NULL` cost (uncosted models).
- Time-series endpoint groups by day correctly across timezone boundaries (DB stores ISO UTC).
- Slow-jobs endpoint orders by latency desc and respects the `limit` query param.

**`src/agents/pricing.zig`**
- Lookup returns expected `(input, output)` rates for known models.
- Lookup for an unknown model returns `null` (cost columns stay NULL on write).
- Round-trip: write-time computation matches manual `(tokens * rate / 1e6)` for known cases.

**`src/api/sse.zig`** (SSE)
- Open connection → receive an event for each new `job_logs` row.
- Connection closes when job reaches terminal state.
- Closing the client connection cleans up the polling timer.

**`agents/ocr_agent`** (Python)
- `--once` mode produces `.md` + `.meta.json` from a 5-page fixture PDF (mocked Gemini).
- `--once` exits non-zero on missing input file.
- Server mode: protocol-conformance test from `tests/mock_host.py` (drives the agent through initialize → ocr.extract → shutdown).
- Soft-check warnings populated on synthetic edge cases (empty model response, no markdown headings).

**`agents/prompt_agent`** (Python)
- `--once` runs one prompt on a fixture markdown bundle, writes `.md`.
- Each of the 5 prompts loads correctly from `prompts/*.md` at startup.
- `prompt.run` with unknown `prompt_name` returns `-32602` Invalid params.
- Required-slice mismatch (missing key in `slices` map) returns `-32003`.

### Fixtures

```
tests/
  fixtures/
    sample-5p.pdf            # 5-page extract from a real chargesheet, redacted
    sample-5p.md             # pre-OCR'd version of the above
    chargesheet-mini/        # full E2E fixture
      chargesheet.pdf        # ~30 pages, 1 of each annexure + 2 RUDs
      expected-slices.json   # how the slicing job is expected to split it
    db/
      v1-populated.db        # SQLite file at schema v1 with sample data
      v1-empty.db
  mock_agent.py
  mock_host.py
  pytest.ini
```

The `sample-5p.pdf` we already have from today's diagnostic work (Sandeep Goel Memo first 5 pages) can be redacted and reused. The `chargesheet-mini` fixture is small enough that a Layer 5 live run costs a fraction of a rupee.

### What is intentionally NOT tested in v1

- **Performance / load.** Not relevant for a single-user local tool. If a job takes 30 minutes that's fine; no SLA.
- **Multiple concurrent users.** Not a feature.
- **Browser compatibility.** The Svelte UI already exists; testing existing UI flows is out of scope for this design.
- **Long-running stability (memory leaks over days).** Observe in real use; revisit if it shows up.
- **Filesystem GC** (orphaned `.md` files after slice deletion). Tracked in _Future work_; no test yet.
- **Mutation testing or coverage targets.** Track coverage informally; don't gate CI on a number.

### CI

GitHub Actions (or whatever the user prefers) runs Layers 1–4 on every push. Layer 5 runs nightly on `main` and gated behind a manual `workflow_dispatch` for PRs that touch prompt or upstream-integration code.

Test runtime budget: Layers 1–4 must complete in under 2 minutes on a clean macOS runner. If they grow past that, the slow tests get moved to a "slow" mark, run only on `main`.

---

## Future work (explicitly deferred)

- **RAG layer.** Embed `extractions/*/*.md` per page (page markers make page-level chunking trivial); store vectors in a sidecar SQLite (`sqlite-vec`) or duckdb. Adds an `embed` agent and a `retrieve` agent.
- **Cross-document case profile.** A higher-level agent (`case.profile`) that takes outputs from multiple slices and synthesizes a single case summary.
- **Evaluator-optimizer loop** for the prompt outputs (Anthropic's 5th canonical pattern).
- **Remote agents.** Run heavyweight agents on a separate machine via the same protocol over a socket / SSH tunnel.

---

## Open questions

Genuinely undecided — these need answers before or during implementation:

- **`notifications/log` persistence policy.** Always persist every log line, or only persist if the job ends in `failed`/`canceled`? Always-persist is simpler but DB grows; failure-only loses context when a successful run was actually surprising.
- **Eager vs lazy agent warm-up.** Current design is lazy (spawn on first job). Cold start is ~1–2 s, invisible to OCR (10 min job) but visible to the user clicking "Run prompt" for the first time. Decide whether logos should pre-spawn `min_idle = 1` worker per kind at startup.
- **`prompt.run` batching granularity.** Current design: one HTTP call per prompt, dispatcher fans out across the worker pool. Alternative: a single `prompt.run` request that batches multiple prompts in one round-trip to an agent. Batching saves serialization overhead but couples parallelism to the agent's internals.

Already-decided (kept here as breadcrumbs, not as questions):

- `evidence_audit` vs `objection_brief`: **keep separate** in v1; revisit after first real run.
- RUDs for prompts 04/05: **full OCR'd text passed in** in v1; optimize to metadata-only if input tokens become painful.
- Non-conforming slice names: **warning + proceed**, marked `kind='other'`, skipped by the prompt dispatcher.
