# Plan C — Real OCR Agent (Python)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Replace the mock OCR agent with a real Python agent that speaks `lambe-haath/1` over stdio, reads `LAMBE_MODEL` from env, calls Gemini, and returns extraction results that logos's dispatcher populates into the `extractions` table.

**Architecture:** Restructure today's `main.py` into `agents/ocr_agent/` package with three layers — a thin JSON-RPC framing module, a server loop that maps protocol methods to handlers, and the existing `extract_and_save` extraction logic with progress callbacks added. Logos's dispatcher gets one small extension: when an `ocr.extract` response arrives with the right shape, write an `extractions` row.

**Tech Stack:** Python 3.12 + google-genai + pypdf + stdlib (json, sys, threading optional).

**Spec reference:** `docs/superpowers/specs/2026-05-28-chargesheet-pipeline-design.md` — sections _Agent inventory_, _JSON-RPC protocol_, _Database schema additions_ (the `extractions` row shape).

**Prereqs:** Plan B merged to main in both repos.

**Out of scope:** Real prompt agent (Plan D). Stats endpoints (Plan E). UI work (Plan F).

---

## File structure

### `~/projects/chargesheets/pdf-extraction-experiments/`

```
agents/                                ← CREATE
  __init__.py                          ← CREATE (empty)
  ocr_agent/
    __init__.py                        ← CREATE (empty)
    __main__.py                        ← CREATE (entry point: python -m agents.ocr_agent)
    framing.py                         ← CREATE (JSON-RPC line codec)
    server.py                          ← CREATE (stdio loop, method dispatch)
    extract.py                         ← MOVED from main.py (extract_and_save + helpers)
main.py                                ← shim that calls agents.ocr_agent.extract directly for legacy CLI use, or DELETED if no longer needed
tests/
  test_ocr_agent_extract.py            ← CREATE (unit tests for extract.py, no network)
  test_ocr_agent_protocol.py           ← CREATE (server-mode protocol tests via conformance harness)
  fixtures/
    sample-5p.pdf                      ← (existing or new — 5-page redacted PDF for live test)
```

### `~/projects/lambe-haath/logos/`

```
src/agents/dispatcher.zig              ← MODIFY (parse ocr.extract result → write extractions row)
src/agents/dispatcher.zig tests        ← MODIFY (add test that result with right shape populates extractions)
```

---

## Pre-flight: branching

```bash
cd ~/projects/chargesheets/pdf-extraction-experiments
git checkout main && git checkout -b feat/plan-c-ocr-agent

cd ~/projects/lambe-haath
git checkout main && git checkout -b feat/plan-c-ocr-agent
```

---

## Task 1: Bootstrap `agents/ocr_agent/` package + restructure main.py into extract.py

**Target repo:** `~/projects/chargesheets/pdf-extraction-experiments/`

**Files:**
- Create: `agents/__init__.py` (empty)
- Create: `agents/ocr_agent/__init__.py` (empty)
- Create: `agents/ocr_agent/extract.py` (move from main.py)
- Delete or shrink: `main.py` (becomes a one-line shim or is removed)

- [ ] **Step 1: Create `agents/__init__.py` and `agents/ocr_agent/__init__.py`** as empty files.

- [ ] **Step 2: Move `main.py` contents to `agents/ocr_agent/extract.py`**

The existing `main.py` contains `extract_and_save` plus helpers (`_chunk_pdf`, `_extract_chunk`, etc.). Move all of it to `agents/ocr_agent/extract.py` verbatim. Update the module-level `client = genai.Client()` to be lazy (instantiate inside `extract_and_save` instead of at module load) so importing the module doesn't require `GEMINI_API_KEY`.

The signature of `extract_and_save` stays the same: `(pdf_path: Path, output_dir: Path) -> dict`.

Add a new module-level constant:
```python
from os import environ

DEFAULT_MODEL = "gemini-2.5-flash"

def get_model() -> str:
    return environ.get("LAMBE_MODEL", DEFAULT_MODEL)
```

In `extract_and_save`, replace the hardcoded `MODEL = "gemini-2.5-flash"` with `MODEL = get_model()` so the agent respects `LAMBE_MODEL`.

- [ ] **Step 3: Update `main.py`** to a thin shim (optional — if you'd rather delete it, that's fine, but keep CLI parity):

```python
"""Backwards-compatible CLI shim.

`python main.py <pdf>` still works. For the real agent (stdio JSON-RPC),
use `python -m agents.ocr_agent`.
"""

import logging
import sys
from pathlib import Path
from agents.ocr_agent.extract import extract_and_save

if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    if len(sys.argv) < 2:
        print("usage: python main.py <pdf_path> [output_dir]", file=sys.stderr)
        sys.exit(2)
    pdf = Path(sys.argv[1])
    out = Path(sys.argv[2]) if len(sys.argv) > 2 else Path("out")
    result = extract_and_save(pdf, out)
    print(f"markdown: {result['markdown_path']}")
    print(f"meta:     {result['meta_path']}")
```

- [ ] **Step 4: Verify import + CLI still work**

```bash
cd ~/projects/chargesheets/pdf-extraction-experiments
.venv/bin/python -c "from agents.ocr_agent.extract import extract_and_save; print('OK')"
```

Expected: `OK` printed, no `GEMINI_API_KEY` error (because client is lazy).

- [ ] **Step 5: Commit**

```bash
git add agents/ main.py
git commit -m "refactor: restructure main.py into agents/ocr_agent/extract.py + lazy genai client"
```

---

## Task 2: JSON-RPC framing module

**Target repo:** `~/projects/chargesheets/pdf-extraction-experiments/`

**Files:**
- Create: `agents/ocr_agent/framing.py`

This mirrors the Zig codec in `logos/src/agents/jsonrpc.zig` (newline-delimited JSON-RPC 2.0). Keeping it small and tested means the server loop in Task 3 stays focused on dispatch logic.

- [ ] **Step 1: Create `agents/ocr_agent/framing.py`**

```python
"""Newline-delimited JSON-RPC 2.0 codec for the lambe-haath/1 protocol.

Mirrors the host-side codec in logos/src/agents/jsonrpc.zig. Pure functions,
no I/O — server.py owns stdin/stdout.
"""

from __future__ import annotations

import json
import sys
from typing import Any


def encode_response(id_: int, result: Any) -> str:
    """Serialize a successful response. Returns a single newline-terminated line."""
    return json.dumps(
        {"jsonrpc": "2.0", "id": id_, "result": result},
        separators=(",", ":"),
    ) + "\n"


def encode_error(id_: int, code: int, message: str, data: dict | None = None) -> str:
    err: dict[str, Any] = {"code": code, "message": message}
    if data is not None:
        err["data"] = data
    return json.dumps(
        {"jsonrpc": "2.0", "id": id_, "error": err},
        separators=(",", ":"),
    ) + "\n"


def encode_notification(method: str, params: dict | None = None) -> str:
    msg: dict[str, Any] = {"jsonrpc": "2.0", "method": method}
    if params is not None:
        msg["params"] = params
    return json.dumps(msg, separators=(",", ":")) + "\n"


# Standard JSON-RPC error codes
PARSE_ERROR = -32700
INVALID_REQUEST = -32600
METHOD_NOT_FOUND = -32601
INVALID_PARAMS = -32602
INTERNAL_ERROR = -32603

# lambe-haath domain-specific codes (matches logos/src/agents/jsonrpc.zig)
CANCELED = -32099
UPSTREAM_API_ERROR = -32001
UPSTREAM_RATE_LIMITED = -32002
INPUT_INVALID = -32003
OUTPUT_TRUNCATED = -32004
AUTH_INVALID = -32005


def write_line(line: str) -> None:
    """Write a single framed line to stdout and flush. Always use this — never raw print."""
    sys.stdout.write(line)
    sys.stdout.flush()
```

- [ ] **Step 2: Add tests** at `tests/test_ocr_agent_protocol.py` (we'll add server-mode tests here too in Task 4; for now just framing-level tests):

```python
"""Tests for tests/test_ocr_agent_protocol.py — the agent's JSON-RPC framing."""

from __future__ import annotations

import json
import pytest

from agents.ocr_agent import framing


@pytest.mark.unit
def test_encode_response_round_trips() -> None:
    line = framing.encode_response(17, {"foo": 42})
    assert line.endswith("\n")
    parsed = json.loads(line)
    assert parsed["jsonrpc"] == "2.0"
    assert parsed["id"] == 17
    assert parsed["result"] == {"foo": 42}


@pytest.mark.unit
def test_encode_error_with_data() -> None:
    line = framing.encode_error(42, framing.UPSTREAM_RATE_LIMITED, "rate limited", {"retry_after_s": 30})
    parsed = json.loads(line)
    assert parsed["error"]["code"] == -32002
    assert parsed["error"]["message"] == "rate limited"
    assert parsed["error"]["data"]["retry_after_s"] == 30


@pytest.mark.unit
def test_encode_notification_no_params() -> None:
    line = framing.encode_notification("notifications/exit")
    parsed = json.loads(line)
    assert "id" not in parsed
    assert "params" not in parsed
    assert parsed["method"] == "notifications/exit"


@pytest.mark.unit
def test_encode_notification_with_params() -> None:
    line = framing.encode_notification(
        "notifications/progress",
        {"progressToken": "j1", "progress": 0.5},
    )
    parsed = json.loads(line)
    assert parsed["params"]["progress"] == 0.5


@pytest.mark.unit
def test_error_code_constants() -> None:
    # Standard codes
    assert framing.PARSE_ERROR == -32700
    assert framing.METHOD_NOT_FOUND == -32601
    # Domain codes
    assert framing.CANCELED == -32099
    assert framing.UPSTREAM_API_ERROR == -32001
    assert framing.AUTH_INVALID == -32005
```

- [ ] **Step 3: Run + commit**

```bash
cd ~/projects/chargesheets/pdf-extraction-experiments
.venv/bin/pytest tests/test_ocr_agent_protocol.py -v
```

Expected: 5 tests pass.

```bash
git add agents/ocr_agent/framing.py tests/test_ocr_agent_protocol.py
git commit -m "agents/ocr_agent: add framing module (JSON-RPC line codec + error codes)"
```

---

## Task 3: Server loop — initialize, ocr.extract, shutdown

**Target repo:** `~/projects/chargesheets/pdf-extraction-experiments/`

**Files:**
- Create: `agents/ocr_agent/server.py`
- Create: `agents/ocr_agent/__main__.py`

- [ ] **Step 1: Create `agents/ocr_agent/__main__.py`**

```python
"""Entry point: python -m agents.ocr_agent

If LAMBE_MODE=once is set in env, run a single OCR job from CLI args (debug mode).
Otherwise, run the stdio JSON-RPC server loop (production: spawned by logos).
"""

import json
import logging
import os
import sys
from pathlib import Path

from agents.ocr_agent.extract import extract_and_save
from agents.ocr_agent.server import run_server


def main() -> int:
    # --once mode: single CLI invocation, exit. Used for local debugging.
    if len(sys.argv) >= 2 and sys.argv[1] == "--once":
        # Configure logging to stderr so it doesn't corrupt the stdout JSON-RPC stream.
        logging.basicConfig(
            level=logging.INFO,
            stream=sys.stderr,
            format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        )
        if len(sys.argv) < 4:
            print(
                "usage: python -m agents.ocr_agent --once <pdf_path> <output_dir>",
                file=sys.stderr,
            )
            return 2
        pdf = Path(sys.argv[2])
        out_dir = Path(sys.argv[3])
        result = extract_and_save(pdf, out_dir)
        # In --once mode, dump the full result dict to stdout as JSON.
        print(json.dumps({k: str(v) if hasattr(v, "__fspath__") else v for k, v in result.items()}, indent=2))
        return 0

    # Server mode (default): JSON-RPC over stdio.
    # Critical: send all log output to stderr so stdout stays a clean RPC channel.
    logging.basicConfig(
        level=logging.INFO,
        stream=sys.stderr,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    return run_server()


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 2: Create `agents/ocr_agent/server.py`**

```python
"""Stdio JSON-RPC server for the OCR agent.

Reads newline-delimited JSON-RPC requests from stdin, dispatches them to handlers,
writes responses + notifications to stdout. Logs go to stderr.
"""

from __future__ import annotations

import json
import logging
import os
import sys
from pathlib import Path
from typing import Any

from agents.ocr_agent import framing
from agents.ocr_agent.extract import extract_and_save, get_model

log = logging.getLogger("ocr_agent")

AGENT_NAME = "ocr_agent"
AGENT_VERSION = "0.1.0"
PROTOCOL_VERSION = "lambe-haath/1"


def run_server() -> int:
    """Read from stdin, dispatch, write to stdout. Returns process exit code."""
    log.info("ocr_agent starting (model=%s)", get_model())
    for raw_line in sys.stdin:
        line = raw_line.rstrip("\n").rstrip("\r")
        if not line:
            continue

        try:
            msg = json.loads(line)
        except json.JSONDecodeError as e:
            log.warning("dropping malformed line (no recovery): %s", e)
            continue

        method = msg.get("method")
        msg_id = msg.get("id")
        params = msg.get("params") or {}
        is_notification = "id" not in msg

        if method == "initialize":
            framing.write_line(framing.encode_response(msg_id, _initialize_result()))
            continue

        if method == "notifications/initialized":
            log.info("host: initialized")
            continue

        if method == "notifications/exit":
            log.info("host: exit notification received; shutting down")
            return 0

        if method == "shutdown":
            framing.write_line(framing.encode_response(msg_id, None))
            # Don't exit yet — wait for notifications/exit (per LSP convention).
            continue

        if is_notification:
            # Unknown notifications are ignored per JSON-RPC 2.0.
            log.debug("ignoring unknown notification: %s", method)
            continue

        if method == "ocr.extract":
            _handle_ocr_extract(msg_id, params)
            continue

        # Unknown method, return method-not-found error.
        framing.write_line(framing.encode_error(
            msg_id, framing.METHOD_NOT_FOUND, f"unknown method: {method}",
        ))

    # stdin closed — exit cleanly
    log.info("stdin EOF; exiting")
    return 0


def _initialize_result() -> dict[str, Any]:
    return {
        "protocolVersion": PROTOCOL_VERSION,
        "agentInfo": {"name": AGENT_NAME, "version": AGENT_VERSION},
        "capabilities": {
            "methods": ["ocr.extract"],
            "progress": True,
            "cancellation": False,  # v1: cancellation not implemented inside extract_and_save
        },
    }


def _handle_ocr_extract(msg_id: int, params: dict) -> None:
    """Process an ocr.extract request.

    Params shape (from logos's dispatcher):
        {
          "slice_path": "/path/to/slice.pdf",
          "output_dir": "/path/to/output_dir",
          "_meta": {"progressToken": "j17"}  # optional
        }
    """
    slice_path = params.get("slice_path")
    output_dir = params.get("output_dir")
    if not slice_path or not output_dir:
        framing.write_line(framing.encode_error(
            msg_id, framing.INVALID_PARAMS, "slice_path and output_dir are required",
        ))
        return

    pdf = Path(slice_path)
    out = Path(output_dir)

    if not pdf.exists():
        framing.write_line(framing.encode_error(
            msg_id, framing.INPUT_INVALID, f"slice not found: {slice_path}",
        ))
        return

    progress_token = (params.get("_meta") or {}).get("progressToken")

    def on_progress(progress: float, message: str) -> None:
        if progress_token is None:
            return
        framing.write_line(framing.encode_notification(
            "notifications/progress",
            {"progressToken": progress_token, "progress": progress, "message": message},
        ))

    def on_log(level: str, message: str) -> None:
        framing.write_line(framing.encode_notification(
            "notifications/log",
            {"level": level, "logger": AGENT_NAME, "message": message},
        ))

    try:
        result = extract_and_save(pdf, out, on_progress=on_progress, on_log=on_log)
    except Exception as exc:
        log.exception("ocr.extract failed")
        framing.write_line(framing.encode_error(
            msg_id, framing.INTERNAL_ERROR, str(exc),
        ))
        return

    # The result dict from extract_and_save returns Path objects; convert for JSON.
    payload = {
        "markdown_path": str(result["markdown_path"]),
        "meta_path": str(result["meta_path"]),
        "model": get_model(),
        "pages": result["metadata"]["source_pages"],
        "page_markers_found": result["metadata"]["page_markers_found"],
        "input_tokens": result["metadata"].get("total_input_tokens"),
        "output_tokens": result["metadata"].get("total_output_tokens"),
        "latency_s": result["metadata"]["total_latency_s"],
    }
    framing.write_line(framing.encode_response(msg_id, payload))
```

- [ ] **Step 3: Add `on_progress` and `on_log` callback support to `extract_and_save`**

In `agents/ocr_agent/extract.py`, change the signature to:

```python
def extract_and_save(
    pdf_path: Path,
    output_dir: Path,
    on_progress=None,   # Optional callable: (progress: float, message: str) -> None
    on_log=None,        # Optional callable: (level: str, message: str) -> None
) -> dict:
    ...
```

Replace existing `logger.info(...)` calls with both a log emission AND an optional `on_log("info", msg)` callback (defensive: if `on_log` is None, just log via the existing `logger`).

Inside the chunk loop, after each chunk completes, call `on_progress((idx+1) / len(chunks), f"chunk {idx+1}/{len(chunks)} done")`.

Inside the streaming-token heartbeat (`logger.info("  ...streaming...")`), also emit `on_progress` with the streaming fraction if you can compute it cheaply. Otherwise emit a coarse-grained progress on chunk completion only.

- [ ] **Step 4: Add an entry-point smoke test** to `tests/test_ocr_agent_protocol.py`:

```python
import sys
import pytest

from tests.conformance_harness import Harness


OCR_AGENT_CMD = [sys.executable, "-m", "agents.ocr_agent"]


@pytest.mark.protocol
def test_initialize_advertises_ocr_extract_method() -> None:
    with Harness(OCR_AGENT_CMD) as h:
        caps = h.initialize()
        assert "ocr.extract" in caps["methods"]
        assert caps["progress"] is True
        h.shutdown()


@pytest.mark.protocol
def test_ocr_extract_with_missing_slice_returns_input_invalid() -> None:
    with Harness(OCR_AGENT_CMD) as h:
        h.initialize()
        resp, _ = h.call("ocr.extract", {
            "slice_path": "/tmp/this-file-does-not-exist.pdf",
            "output_dir": "/tmp",
        })
        assert "error" in resp
        assert resp["error"]["code"] == -32003  # INPUT_INVALID
        h.shutdown()


@pytest.mark.protocol
def test_unknown_method_returns_method_not_found() -> None:
    with Harness(OCR_AGENT_CMD) as h:
        h.initialize()
        resp, _ = h.call("nonexistent.method", {})
        assert "error" in resp
        assert resp["error"]["code"] == -32601
        h.shutdown()
```

- [ ] **Step 5: Run + commit**

```bash
cd ~/projects/chargesheets/pdf-extraction-experiments
.venv/bin/pytest tests/test_ocr_agent_protocol.py -v
```

Expected: 8 tests pass (5 unit + 3 protocol).

```bash
git add agents/ocr_agent/server.py agents/ocr_agent/__main__.py agents/ocr_agent/extract.py tests/test_ocr_agent_protocol.py
git commit -m "agents/ocr_agent: stdio JSON-RPC server with initialize + ocr.extract + shutdown"
```

---

## Task 4: Update logos dispatcher to populate `extractions` table

**Target repo:** `~/projects/lambe-haath/logos/`

**Files:**
- Modify: `src/agents/dispatcher.zig` — extend `completeJob` (or whatever the success handler is named) to parse the result JSON when `j.type == .ocr` and INSERT/UPSERT an extractions row.

- [ ] **Step 1: Read `src/agents/dispatcher.zig`** — find the function that handles `result` responses (likely named `completeJob` or inside `handleResponse`).

The current behavior just stores `result_json` in `jobs.results`. We need to also write to the `extractions` table when `j.type == .ocr`.

- [ ] **Step 2: Add `parseExtractionResult` helper to `dispatcher.zig`**

The OCR agent's response shape (defined by Task 3 above):
```json
{
  "markdown_path": "/path/to/x.md",
  "meta_path": "/path/to/x.meta.json",
  "model": "gemini-2.5-flash",
  "pages": 176,
  "page_markers_found": 156,
  "input_tokens": 46154,
  "output_tokens": 136477,
  "latency_s": 617.0
}
```

Add a private helper that extracts these fields from the result_json:

```zig
const ExtractionFields = struct {
    markdown_path: []const u8,
    meta_path: []const u8,
    model: []const u8,
    pages: u32,
    page_markers_found: u32,
    input_tokens: ?i64,
    output_tokens: ?i64,
    latency_s: f64,
};

fn parseExtractionFields(gpa: Allocator, json_text: []const u8) !ExtractionFields {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, json_text, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidExtractionResult;
    const obj = parsed.value.object;

    // Required fields
    const md_v = obj.get("markdown_path") orelse return error.InvalidExtractionResult;
    const mp_v = obj.get("meta_path") orelse return error.InvalidExtractionResult;
    const mdl_v = obj.get("model") orelse return error.InvalidExtractionResult;
    const pages_v = obj.get("pages") orelse return error.InvalidExtractionResult;
    const pmf_v = obj.get("page_markers_found") orelse return error.InvalidExtractionResult;
    const lat_v = obj.get("latency_s") orelse return error.InvalidExtractionResult;
    if (md_v != .string or mp_v != .string or mdl_v != .string) return error.InvalidExtractionResult;
    if (pages_v != .integer or pmf_v != .integer) return error.InvalidExtractionResult;

    return .{
        .markdown_path = try gpa.dupe(u8, md_v.string),
        .meta_path = try gpa.dupe(u8, mp_v.string),
        .model = try gpa.dupe(u8, mdl_v.string),
        .pages = @intCast(pages_v.integer),
        .page_markers_found = @intCast(pmf_v.integer),
        .input_tokens = if (obj.get("input_tokens")) |v| (if (v == .integer) v.integer else null) else null,
        .output_tokens = if (obj.get("output_tokens")) |v| (if (v == .integer) v.integer else null) else null,
        .latency_s = switch (lat_v) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => return error.InvalidExtractionResult,
        },
    };
}
```

Each `gpa.dupe` allocation needs corresponding free at the call site after the upsert completes.

- [ ] **Step 3: Use the helper in the response handler**

In the success path (where `markCompletedAt` is currently called), if `j.type == .ocr`, also call `extractions_mod.upsert` with the parsed fields. Use `pricing.cost(model, in_tok, out_tok)` to compute the USD costs.

```zig
// (Inside the success branch of handleResponse, when j.type == .ocr)
if (parseExtractionFields(self.gpa, result_json)) |ef| {
    defer {
        self.gpa.free(ef.markdown_path);
        self.gpa.free(ef.meta_path);
        self.gpa.free(ef.model);
    }
    const costs = pricing.cost(ef.model, ef.input_tokens orelse 0, ef.output_tokens orelse 0);
    const slice_filename = parseSliceFilenameFromPayload(self.gpa, j.payload) catch null;
    if (slice_filename) |sf| {
        defer self.gpa.free(sf);
        const now_e = try db_mod.nowIso8601(self.gpa);
        defer self.gpa.free(now_e);
        try extractions_mod.upsert(self.db, self.gpa, .{
            .project_id = j.project_id,
            .slice_filename = sf,
            .markdown_path = ef.markdown_path,
            .meta_path = ef.meta_path,
            .model = ef.model,
            .pages = ef.pages,
            .page_markers_found = ef.page_markers_found,
            .input_tokens = ef.input_tokens,
            .output_tokens = ef.output_tokens,
            .input_cost_usd = if (costs) |c| c.input else null,
            .output_cost_usd = if (costs) |c| c.output else null,
            .latency_s = ef.latency_s,
            .created_at = now_e,
        });
    }
} else |err| {
    std.log.warn("ocr result JSON didn't parse as ExtractionFields: {s}", .{@errorName(err)});
}
```

And `parseSliceFilenameFromPayload`:

```zig
fn parseSliceFilenameFromPayload(gpa: Allocator, payload_json: []const u8) ![]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, payload_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidPayload;
    const sf_v = parsed.value.object.get("slice_filename") orelse return error.InvalidPayload;
    if (sf_v != .string) return error.InvalidPayload;
    return try gpa.dupe(u8, sf_v.string);
}
```

(Payload was set by `handlers_ocr.postEnqueueOcr` to `{"slice_filename":"..."}` — that's the source.)

- [ ] **Step 4: Add a test in `src/agents/dispatcher.zig`**

```zig
test "OCR completion with valid result populates extractions row" {
    var db = try Db.open(":memory:");
    defer db.close();
    const gpa = std.testing.allocator;
    var mu: Io.Mutex = .init;
    var ch = event_channel_mod.EventChannel.init(gpa, std.testing.io);
    defer ch.deinit();

    var specs = [_]config_mod.AgentSpec{};
    var cfg = config_mod.AgentConfig{ .agents = &specs };
    var sup = supervisor_mod.Supervisor.init(std.testing.io, gpa, &cfg, &ch);
    defer sup.deinit();

    var disp = Dispatcher.init(std.testing.io, gpa, &db, &mu, &sup, &ch);
    defer disp.deinit();

    // Seed: project, slice, queued OCR job
    try test_helpers.insertProject(&db, "p1");
    try db.conn.exec(
        \\INSERT INTO slices (project_id, filename, start_page, end_page, size_bytes, kind, kind_key, created_at)
        \\VALUES ('p1', 'annexure-i.pdf', 1, 1, 1, 'annexure', 'i', '2026-05-28T00:00:00Z')
    , .{});

    // Manually invoke parseExtractionFields → upsert path
    const result_json =
        \\{"markdown_path":"/x.md","meta_path":"/x.json","model":"gemini-2.5-flash",
        \\ "pages":5,"page_markers_found":5,"input_tokens":100,"output_tokens":500,"latency_s":12.5}
    ;
    // The dispatcher would call this internally on a real OCR response. We'll invoke
    // the helper directly to verify the parsing + upsert wiring.
    // (Adapt to whatever helper visibility you ended up with.)

    var ef = try parseExtractionFields(gpa, result_json);
    defer {
        gpa.free(ef.markdown_path);
        gpa.free(ef.meta_path);
        gpa.free(ef.model);
    }

    try extractions_mod.upsert(&db, gpa, .{
        .project_id = "p1",
        .slice_filename = "annexure-i.pdf",
        .markdown_path = ef.markdown_path,
        .meta_path = ef.meta_path,
        .model = ef.model,
        .pages = ef.pages,
        .page_markers_found = ef.page_markers_found,
        .input_tokens = ef.input_tokens,
        .output_tokens = ef.output_tokens,
        .input_cost_usd = null,
        .output_cost_usd = null,
        .latency_s = ef.latency_s,
        .created_at = "2026-05-28T00:01:00Z",
    });

    var got = (try extractions_mod.getByKey(&db, gpa, "p1", "annexure-i.pdf")).?;
    defer got.deinit(gpa);
    try std.testing.expectEqualStrings("/x.md", got.markdown_path);
    try std.testing.expectEqual(@as(u32, 5), got.pages);
}
```

Make `parseExtractionFields` `pub` if needed for the test, or move the test to be `_internal` style within the dispatcher's own test block.

- [ ] **Step 5: Run + commit**

```bash
cd ~/projects/lambe-haath/logos
export LAMBE_MOCK_AGENT_PATH="$HOME/projects/chargesheets/pdf-extraction-experiments/tests/mock_agent.py"
zig build test --summary all 2>&1 | tail -5
```

Expected: 148 → 149+ passing.

```bash
git add src/agents/dispatcher.zig
git commit -m "agents/dispatcher: populate extractions row from OCR result payload"
```

---

## Task 5: End-to-end live OCR test (opt-in)

**Target repo:** `~/projects/chargesheets/pdf-extraction-experiments/`

**Files:**
- Create: `tests/test_ocr_agent_live.py`
- Create or reuse: `tests/fixtures/sample-5p.pdf` (the 5-page sample we already used during diagnostics — re-extract from `~/Downloads/Sandeep Goel Memo.pdf` if not committed)

This test is marked `@pytest.mark.live` and skipped unless `LAMBE_LIVE_TESTS=1`. It runs the full agent end-to-end against the real Gemini API and verifies the result shape.

- [ ] **Step 1: Create the fixture**

```bash
cd ~/projects/chargesheets/pdf-extraction-experiments
mkdir -p tests/fixtures
.venv/bin/python -c "
from pypdf import PdfReader, PdfWriter
src = '/Users/user/Downloads/Sandeep Goel Memo.pdf'
r = PdfReader(src)
w = PdfWriter()
for p in r.pages[:5]:
    w.add_page(p)
with open('tests/fixtures/sample-5p.pdf', 'wb') as fh:
    w.write(fh)
"
ls -la tests/fixtures/sample-5p.pdf
```

(If the user prefers a different source PDF, use that instead; the goal is a small <5 MB sample for live testing.)

- [ ] **Step 2: Create `tests/test_ocr_agent_live.py`**

```python
"""Live OCR test — opt-in via LAMBE_LIVE_TESTS=1.

This test makes real Gemini API calls and costs a few rupees per run.
Run only when validating the real OCR pipeline end-to-end.
"""

from __future__ import annotations

import os
import shutil
import sys
import tempfile
from pathlib import Path

import pytest

from tests.conformance_harness import Harness

LIVE = os.environ.get("LAMBE_LIVE_TESTS") == "1"
SAMPLE_PDF = Path(__file__).parent / "fixtures" / "sample-5p.pdf"

OCR_AGENT_CMD = [sys.executable, "-m", "agents.ocr_agent"]


@pytest.mark.live
@pytest.mark.skipif(not LIVE, reason="set LAMBE_LIVE_TESTS=1 to run live tests")
@pytest.mark.skipif(not SAMPLE_PDF.exists(), reason="missing sample-5p.pdf fixture")
def test_ocr_extract_against_real_gemini() -> None:
    with tempfile.TemporaryDirectory() as tmpd:
        out_dir = Path(tmpd) / "out"
        out_dir.mkdir()

        with Harness(OCR_AGENT_CMD, read_timeout_s=300.0) as h:
            caps = h.initialize()
            assert "ocr.extract" in caps["methods"]

            resp, notifs = h.call(
                "ocr.extract",
                {
                    "slice_path": str(SAMPLE_PDF),
                    "output_dir": str(out_dir),
                },
                progress_token="t1",
            )
            assert "result" in resp, f"unexpected error: {resp}"
            result = resp["result"]
            assert Path(result["markdown_path"]).exists()
            assert Path(result["meta_path"]).exists()
            assert result["pages"] == 5
            assert result["model"].startswith("gemini-")
            assert result["latency_s"] > 0
            # We should have received at least one progress notification.
            assert any(n["method"] == "notifications/progress" for n in notifs)

            h.shutdown()
```

- [ ] **Step 3: Add `live` marker to `pyproject.toml`**

In the `[tool.pytest.ini_options]` section's markers list, add:
```toml
"live: opt-in tests that hit real upstream APIs (cost real money; LAMBE_LIVE_TESTS=1 to run)",
```

- [ ] **Step 4: Run + commit**

Default test run (without LAMBE_LIVE_TESTS) should skip the live test:

```bash
.venv/bin/pytest tests/ -v 2>&1 | tail -10
```

Live run:
```bash
LAMBE_LIVE_TESTS=1 .venv/bin/pytest tests/test_ocr_agent_live.py -v
```

Expected: live test passes, takes ~30 s.

```bash
git add tests/test_ocr_agent_live.py tests/fixtures/sample-5p.pdf pyproject.toml
git commit -m "test: opt-in live OCR test against real Gemini API"
```

---

## Task 6: Configure logos to use the real OCR agent

**Target repo:** Both — but mainly a config + docs update.

For the daemon to use the real OCR agent instead of the mock, the `agents.json` must point at `python3 -m agents.ocr_agent`. This is per-deployment configuration, not source code.

- [ ] **Step 1: Update the `agents.json` default in `src/agents/config.zig`**

The default config (used when no `agents.json` exists) currently has:
```
{"kind": "ocr", "command": "python3", "args": ["-m", "agents.ocr_agent"], "max_workers": 2, "model": "gemini-2.5-flash"}
```

That's already correct! But verify by reading the file. If the args are different, update them.

The daemon will fail to find `agents.ocr_agent` unless run from the directory containing `agents/` — verify by adding a comment in the config noting the expected `cwd` setting.

- [ ] **Step 2: Document the setup in a top-level README addition** (`~/projects/chargesheets/pdf-extraction-experiments/README.md`):

Add a "Running with logos" section explaining:
1. Set `GEMINI_API_KEY` in logos's environment
2. Start logos from inside `pdf-extraction-experiments/` (so `python -m agents.ocr_agent` resolves)
3. Or, set `cwd` in `agents.json` to the pdf-extraction-experiments path

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: how to run logos against the real OCR agent"
```

---

## Task 7: Final verification

- [ ] **Step 1: Zig + Python green**

```bash
cd ~/projects/lambe-haath/logos
export LAMBE_MOCK_AGENT_PATH="$HOME/projects/chargesheets/pdf-extraction-experiments/tests/mock_agent.py"
zig build test --summary all 2>&1 | tail -5

cd ~/projects/chargesheets/pdf-extraction-experiments
.venv/bin/pytest -v 2>&1 | tail -10
```

Expected: logos 149+ passing, Python 18+ passing (10 prior + 5 framing + 3 protocol).

- [ ] **Step 2: Manual live smoke test**

```bash
export LAMBE_LIVE_TESTS=1
cd ~/projects/chargesheets/pdf-extraction-experiments
set -a && source .env && set +a
.venv/bin/pytest tests/test_ocr_agent_live.py -v
```

Expected: live test passes within ~30 s.

- [ ] **Step 3: Verify branch ready for merge**

```bash
cd ~/projects/chargesheets/pdf-extraction-experiments
git log --oneline main..feat/plan-c-ocr-agent

cd ~/projects/lambe-haath
git log --oneline main..feat/plan-c-ocr-agent
```

---

## What's next (Plan D preview, not in this plan)

After Plan C is merged:

- **Plan D**: real prompt agent in Python, mirrors Plan C's structure. Five prompts (charge_memo_analysis, etc.), Anthropic SDK + Gemini fallback (via the `LAMBE_MODEL` env var pattern from Plan C), markdown output. Plus dispatcher update to populate `prompt_outputs` table from the response.

Plan C and Plan D are otherwise independent and could be developed in parallel by different teams; we're doing C first because it has a smaller delta over today's `main.py`.
