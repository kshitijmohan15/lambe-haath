# Lambe Haath

Chargesheet OCR + analysis pipeline. Local-first desktop app that ingests
police chargesheets (PDF), slices them, runs OCR + 5 defence-analysis
prompts via Gemini, and serves the results through a Svelte SPA.

## Architecture

Three layers, sharing one repo:

- **`logos/`** — Zig daemon. HTTP API server, job dispatcher, SQLite store,
  agent supervisor. Always running.
- **`agents/`** — Python agents (`ocr_agent`, `prompt_agent`). Spawned by
  the daemon as long-lived stdio JSON-RPC workers. One process per "kind"
  per slot; lazy-spawned up to `max_workers`.
- **`chargesheet-ui/`** — SvelteKit + Tailwind 4 SPA. Talks to the daemon
  over `/api/v1/...`. Builds to a static bundle the daemon can serve.

Supporting pieces:

- **`mupdf-zig/`** — Zig wrapper over MuPDF's C API for PDF slicing.
- **`docs/specs/`** — Design specs.
- **`docs/plans/`** — Implementation plans (historical record).

See `docs/specs/2026-05-28-chargesheet-pipeline-design.md` for the full
design.

## Setup

```bash
# Python deps (uses uv)
uv sync

# Zig daemon
cd logos && zig build

# UI dev deps
cd ../chargesheet-ui && yarn install
```

Copy `.env.example` to `.env` and fill in your Gemini API key first.

## Running locally (dev)

```bash
# Terminal 1: source secrets + start daemon
set -a && source .env && set +a
./logos/zig-out/bin/logos -p 7777

# Terminal 2: UI dev server (proxies /api -> localhost:7777)
cd chargesheet-ui && yarn dev
# open http://localhost:5173/
```

The daemon resolves the `agents/` directory automatically when launched from
the repo root. If launching from elsewhere, set `LAMBE_AGENTS_DIR=/path/to/lambe-haath/agents`.

## Tests

```bash
# Python
uv run pytest tests/ -x

# Zig
cd logos && zig build test

# UI
cd chargesheet-ui && yarn test
```

## Environment variables

See `.env.example` for the full list. Key vars:

| Variable | Purpose |
|---|---|
| `GEMINI_API_KEY` | Required. Gemini API key for OCR and prompt agents. |
| `LAMBE_MODEL` | Default model for agents (e.g. `gemini-2.5-flash`). |
| `CHARGESHEET_DATA_DIR` | Override the data directory (SQLite DB, slices, etc.). |
| `LAMBE_AGENTS_DIR` | Override the Python agents/ directory location. |
| `LAMBE_CACHE_TTL_SECONDS` | Gemini context cache TTL in seconds (default 3600). |
