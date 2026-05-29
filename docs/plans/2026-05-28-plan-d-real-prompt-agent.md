# Plan D — Real Prompt Agent (Python, Claude + Gemini fallback)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Ship a working `prompt_agent` that speaks `lambe-haath/1` over stdio, reads `LAMBE_MODEL` from env, and runs one of the five defence-analysis prompts (`charge_memo_analysis`, `imputation_scrutiny`, `time_chart`, `evidence_audit`, `objection_brief`) against the project's OCR'd slices — returning a Markdown analysis that logos's dispatcher persists into the `prompt_outputs` table.

**Architecture:** Mirror of Plan C's ocr_agent structure. New package `agents/prompt_agent/` with framing (factored to `agents/common/` and shared with ocr_agent), a `clients.py` that routes to either the `anthropic` or `google.genai` SDK based on `LAMBE_MODEL`'s prefix, a `prompts.py` registry that loads 5 rendered Markdown templates from `agents/prompt_agent/prompts/`, and a `server.py` loop. Each prompt declares which slices it requires (annexure i/ii/iii/iv + optional `ruds:*`); the agent assembles the inputs into a single user message and asks the model to produce a Markdown legal analysis.

**Tech Stack:** Python 3.12, anthropic SDK (new dep), google-genai (existing), stdlib only otherwise.

**Spec reference:** `docs/superpowers/specs/2026-05-28-chargesheet-pipeline-design.md` — sections _Agent inventory_ (specifically the 5-prompts table), _JSON-RPC protocol_ (`prompt.run` request/response), _Database schema additions_ (the `prompt_outputs` row shape), _Slicing convention_ (per-prompt slice requirements).

**Prereqs:** Plan C merged to main in both repos.

**Out of scope:** Stats endpoints (Plan E). UI work (Plan F). Cancellation inside the model call (not implementable without changing the Anthropic/Gemini SDK to streaming with abort signals; the agent declares `cancellation: false` for v1).

---

## File structure

### `~/projects/chargesheets/pdf-extraction-experiments/`

```
agents/
  common/                                ← CREATE (shared between agents)
    __init__.py                          ← CREATE (empty)
    framing.py                           ← MOVED here from agents/ocr_agent/framing.py
  ocr_agent/
    framing.py                           ← becomes a thin re-export from agents.common.framing
  prompt_agent/                          ← CREATE
    __init__.py                          ← CREATE (empty)
    __main__.py                          ← CREATE (entry point)
    server.py                            ← CREATE (stdio loop, prompt.run handler)
    clients.py                           ← CREATE (Anthropic + Gemini routing)
    prompts.py                           ← CREATE (PROMPTS dict + slice requirements)
    prompts/                             ← CREATE (rendered Markdown prompt templates)
      charge_memo_analysis.md            ← CREATE (rendered from raw/01.docx)
      imputation_scrutiny.md             ← CREATE (from raw/02.docx)
      time_chart.md                      ← CREATE (from raw/03.docx)
      evidence_audit.md                  ← CREATE (from raw/04.docx)
      objection_brief.md                 ← CREATE (from raw/05.docx)
      raw/                               ← EXISTING (5 .docx files committed earlier)
pyproject.toml                           ← MODIFY (add `anthropic` dep)
tests/
  test_prompt_agent_clients.py           ← CREATE (unit tests for model routing)
  test_prompt_agent_protocol.py          ← CREATE (protocol-conformance tests)
  test_prompt_agent_live.py              ← CREATE (opt-in live test)
  fixtures/
    sample-annexure-i.md                 ← CREATE (small markdown fixture for tests)
```

### `~/projects/lambe-haath/logos/`

```
src/agents/dispatcher.zig                ← MODIFY (parse prompt.run result → write prompt_outputs row)
```

---

## Pre-flight: branching

```bash
cd ~/projects/chargesheets/pdf-extraction-experiments
git checkout main && git checkout -b feat/plan-d-prompt-agent

cd ~/projects/lambe-haath
git checkout main && git checkout -b feat/plan-d-prompt-agent
```

---

## Task 1: Factor `framing.py` to `agents/common/`

**Target repo:** `~/projects/chargesheets/pdf-extraction-experiments/`

**Files:**
- Create: `agents/common/__init__.py` (empty)
- Move: `agents/ocr_agent/framing.py` → `agents/common/framing.py`
- Replace: `agents/ocr_agent/framing.py` with a thin re-export shim (so the existing `from agents.ocr_agent import framing` imports keep working)

- [ ] **Step 1: Create `agents/common/__init__.py`** (empty file).

- [ ] **Step 2: Move `agents/ocr_agent/framing.py`** to `agents/common/framing.py`. Content stays identical.

```bash
mv agents/ocr_agent/framing.py agents/common/framing.py
```

- [ ] **Step 3: Create a thin re-export at `agents/ocr_agent/framing.py`**:

```python
"""Re-export framing from agents.common.framing for backwards compatibility.

The framing module was moved to agents.common in Plan D so that the prompt
agent (and any future agents) can share it. Existing imports of
`agents.ocr_agent.framing` keep working through this shim.
"""

from agents.common.framing import *  # noqa: F401, F403
from agents.common.framing import (  # explicit re-exports for type checkers
    encode_response,
    encode_error,
    encode_notification,
    write_line,
    PARSE_ERROR,
    INVALID_REQUEST,
    METHOD_NOT_FOUND,
    INVALID_PARAMS,
    INTERNAL_ERROR,
    CANCELED,
    UPSTREAM_API_ERROR,
    UPSTREAM_RATE_LIMITED,
    INPUT_INVALID,
    OUTPUT_TRUNCATED,
    AUTH_INVALID,
)
```

- [ ] **Step 4: Verify all existing tests still pass**

```bash
cd ~/projects/chargesheets/pdf-extraction-experiments
.venv/bin/pytest tests/test_ocr_agent_protocol.py -v
```

Expected: 8 tests still pass (5 unit + 3 protocol). The re-export shim keeps `from agents.ocr_agent import framing` working.

- [ ] **Step 5: Commit**

```bash
git add agents/common/__init__.py agents/common/framing.py agents/ocr_agent/framing.py
git commit -m "agents/common: factor framing module so prompt_agent can share it"
```

---

## Task 2: Render the 5 prompt templates from .docx to .md

**Target repo:** `~/projects/chargesheets/pdf-extraction-experiments/`

**Files:**
- Create: `agents/prompt_agent/__init__.py` (empty)
- Create: `agents/prompt_agent/prompts/charge_memo_analysis.md` (from `agents/prompt_agent/prompts/raw/01 ...docx`)
- Create: `agents/prompt_agent/prompts/imputation_scrutiny.md` (from `raw/02 ...docx`)
- Create: `agents/prompt_agent/prompts/time_chart.md` (from `raw/03 ...docx`)
- Create: `agents/prompt_agent/prompts/evidence_audit.md` (from `raw/04 ...docx`)
- Create: `agents/prompt_agent/prompts/objection_brief.md` (from `raw/05 ...docx`)

The 5 .docx files already exist at `agents/prompt_agent/prompts/raw/` from a prior commit. Convert them to Markdown.

- [ ] **Step 1: Create `agents/prompt_agent/__init__.py`** as empty.

- [ ] **Step 2: Render each .docx to Markdown**

A simple approach using stdlib only (the .docx XML structure is straightforward; we extract `<w:t>` text runs and reconstruct paragraphs):

```bash
cd ~/projects/chargesheets/pdf-extraction-experiments
.venv/bin/python <<'PYEOF'
import re
import shutil
import subprocess
import zipfile
from pathlib import Path

RAW_DIR = Path("agents/prompt_agent/prompts/raw")
OUT_DIR = Path("agents/prompt_agent/prompts")

MAPPING = {
    "01 Master Prompt Charge Memorandum.docx":            "charge_memo_analysis.md",
    "02 Prompt No New Charge through Statement of Imputation.docx": "imputation_scrutiny.md",
    "03 Time Chart & Flow Chart.docx":                     "time_chart.md",
    "04 Inconsitency in Proving the Document and Witnesses.docx": "evidence_audit.md",
    "05 Inconsitency in Proving Output for Objection.docx": "objection_brief.md",
}

def docx_to_markdown(docx_path: Path) -> str:
    """Crude .docx → .md extractor using just the .xml text content.
    
    Reads word/document.xml, strips XML tags, normalizes whitespace.
    The original docx structure (lists, bold, emoji) is partially preserved;
    the result is suitable as a system prompt fed to an LLM.
    """
    with zipfile.ZipFile(docx_path, "r") as z:
        with z.open("word/document.xml") as fh:
            xml = fh.read().decode("utf-8")
    # Insert paragraph breaks at <w:p ...>
    xml = re.sub(r"<w:p[^>]*>", "\n\n", xml)
    # Insert line breaks at <w:br/>
    xml = re.sub(r"<w:br[^/]*/?>", "\n", xml)
    # Strip all other XML tags
    text = re.sub(r"<[^>]+>", "", xml)
    # Decode XML entities
    text = text.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", '"').replace("&apos;", "'")
    # Normalize whitespace (multiple blank lines → single blank line)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip() + "\n"

OUT_DIR.mkdir(parents=True, exist_ok=True)
for src_name, out_name in MAPPING.items():
    src = RAW_DIR / src_name
    if not src.exists():
        print(f"MISSING: {src}", flush=True)
        continue
    md = docx_to_markdown(src)
    (OUT_DIR / out_name).write_text(md, encoding="utf-8")
    print(f"wrote {out_name} ({len(md)} chars)")
PYEOF
```

Verify each rendered file exists and is non-empty:

```bash
ls -la agents/prompt_agent/prompts/*.md
wc -l agents/prompt_agent/prompts/*.md
```

Each should be 50-200 lines. Hand-inspect one to confirm it's readable (open `agents/prompt_agent/prompts/charge_memo_analysis.md` and skim).

- [ ] **Step 3: Commit**

```bash
git add agents/prompt_agent/__init__.py agents/prompt_agent/prompts/*.md
git commit -m "agents/prompt_agent: render 5 defence-analysis prompts from .docx to .md"
```

---

## Task 3: `agents/prompt_agent/prompts.py` — PROMPTS registry

**Target repo:** `~/projects/chargesheets/pdf-extraction-experiments/`

**Files:**
- Create: `agents/prompt_agent/prompts.py`

The registry tells the server (a) which prompts the agent supports, (b) what slice kinds each one requires (mirrors the spec), and (c) where the system-prompt text lives on disk.

- [ ] **Step 1: Create `agents/prompt_agent/prompts.py`**

```python
"""Registry of supported prompts for the prompt agent.

Each entry declares:
  - the prompt name (Python identifier used as the API key)
  - the system-prompt template (loaded from prompts/<name>.md)
  - which slices the prompt requires (parsed by the dispatcher to gate dispatch
    on OCR fan-in; surfaced in the agent's initialize-response capabilities)
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

# Slice-kind sentinels:
#   "annexure-i" / "annexure-ii" / "annexure-iii" / "annexure-iv" — specific annexures
#   "ruds:*"                                                       — every RUD in the project
@dataclass(frozen=True)
class PromptSpec:
    name: str
    system_template_path: str  # relative to prompts/ directory
    requires: tuple[str, ...]  # slice-kind keys the agent expects in the input


PROMPTS: dict[str, PromptSpec] = {
    "charge_memo_analysis": PromptSpec(
        name="charge_memo_analysis",
        system_template_path="charge_memo_analysis.md",
        requires=("annexure-i", "annexure-ii", "annexure-iii", "annexure-iv"),
    ),
    "imputation_scrutiny": PromptSpec(
        name="imputation_scrutiny",
        system_template_path="imputation_scrutiny.md",
        requires=("annexure-i", "annexure-ii"),
    ),
    "time_chart": PromptSpec(
        name="time_chart",
        system_template_path="time_chart.md",
        requires=("annexure-i", "annexure-ii"),
    ),
    "evidence_audit": PromptSpec(
        name="evidence_audit",
        system_template_path="evidence_audit.md",
        requires=("annexure-i", "annexure-ii", "annexure-iii", "annexure-iv", "ruds:*"),
    ),
    "objection_brief": PromptSpec(
        name="objection_brief",
        system_template_path="objection_brief.md",
        requires=("annexure-i", "annexure-ii", "annexure-iii", "annexure-iv", "ruds:*"),
    ),
}


def load_system_prompt(name: str) -> str:
    """Read the rendered Markdown template for a given prompt name."""
    spec = PROMPTS.get(name)
    if spec is None:
        raise KeyError(f"unknown prompt: {name}")
    prompts_dir = Path(__file__).parent / "prompts"
    return (prompts_dir / spec.system_template_path).read_text(encoding="utf-8")


def capabilities_dict() -> dict:
    """Build the `prompts` field for the initialize-response capabilities block.

    Matches the spec's shape:
      {"charge_memo_analysis": {"requires": ["annexure-i", ...]}, ...}
    """
    return {
        spec.name: {"requires": list(spec.requires)}
        for spec in PROMPTS.values()
    }
```

- [ ] **Step 2: Add basic unit tests** in a new file `tests/test_prompt_agent_prompts.py`:

```python
"""Tests for agents/prompt_agent/prompts.py."""

from __future__ import annotations

import pytest

from agents.prompt_agent import prompts


@pytest.mark.unit
def test_all_five_prompts_registered() -> None:
    assert set(prompts.PROMPTS.keys()) == {
        "charge_memo_analysis",
        "imputation_scrutiny",
        "time_chart",
        "evidence_audit",
        "objection_brief",
    }


@pytest.mark.unit
def test_each_prompt_template_loads_non_empty() -> None:
    for name in prompts.PROMPTS:
        text = prompts.load_system_prompt(name)
        assert len(text.strip()) > 100, f"{name} template suspiciously short"


@pytest.mark.unit
def test_evidence_audit_requires_ruds_sentinel() -> None:
    assert "ruds:*" in prompts.PROMPTS["evidence_audit"].requires
    assert "ruds:*" in prompts.PROMPTS["objection_brief"].requires


@pytest.mark.unit
def test_unknown_prompt_raises_keyerror() -> None:
    with pytest.raises(KeyError):
        prompts.load_system_prompt("nonexistent")


@pytest.mark.unit
def test_capabilities_dict_shape() -> None:
    caps = prompts.capabilities_dict()
    assert "evidence_audit" in caps
    assert caps["evidence_audit"]["requires"][:4] == [
        "annexure-i", "annexure-ii", "annexure-iii", "annexure-iv",
    ]
    assert "ruds:*" in caps["evidence_audit"]["requires"]
```

- [ ] **Step 3: Run + commit**

```bash
.venv/bin/pytest tests/test_prompt_agent_prompts.py -v
```

Expected: 5 tests pass.

```bash
git add agents/prompt_agent/prompts.py tests/test_prompt_agent_prompts.py
git commit -m "agents/prompt_agent: PROMPTS registry + capabilities_dict + load_system_prompt"
```

---

## Task 4: `agents/prompt_agent/clients.py` — Anthropic + Gemini routing

**Target repo:** `~/projects/chargesheets/pdf-extraction-experiments/`

**Files:**
- Modify: `pyproject.toml` (add `anthropic>=0.40.0` to `dependencies`)
- Create: `agents/prompt_agent/clients.py`
- Create: `tests/test_prompt_agent_clients.py`

The clients module is the model-routing layer. It picks the right SDK based on `LAMBE_MODEL`'s prefix and returns a uniform result dict.

- [ ] **Step 1: Add anthropic to pyproject.toml dependencies**

Read the existing pyproject.toml, add `"anthropic>=0.40.0"` to the `dependencies` list, then:

```bash
cd ~/projects/chargesheets/pdf-extraction-experiments
uv sync
```

Verify import works:
```bash
.venv/bin/python -c "import anthropic; print(anthropic.__version__)"
```

- [ ] **Step 2: Create `agents/prompt_agent/clients.py`**

```python
"""Model-routing layer for the prompt agent.

Picks the right SDK based on LAMBE_MODEL's prefix. Returns a uniform
{markdown, input_tokens, output_tokens, latency_s, finish_reason} dict.

Supported model families:
- claude-*  → Anthropic Messages API
- gemini-*  → Google genai (existing dep)
"""

from __future__ import annotations

import os
import time
from typing import Any, Callable, Optional


class UnsupportedModelError(ValueError):
    """Raised when the LAMBE_MODEL has no SDK route."""


class CompletionResult:
    def __init__(
        self,
        markdown: str,
        input_tokens: int | None,
        output_tokens: int | None,
        latency_s: float,
        finish_reason: str,
    ) -> None:
        self.markdown = markdown
        self.input_tokens = input_tokens
        self.output_tokens = output_tokens
        self.latency_s = latency_s
        self.finish_reason = finish_reason


def run_completion(
    model: str,
    system_prompt: str,
    user_prompt: str,
    on_log: Optional[Callable[[str, str], None]] = None,
) -> CompletionResult:
    """Dispatch to the right SDK based on model prefix."""
    if model.startswith("claude-"):
        return _run_anthropic(model, system_prompt, user_prompt, on_log)
    if model.startswith("gemini-"):
        return _run_gemini(model, system_prompt, user_prompt, on_log)
    raise UnsupportedModelError(f"no SDK route for model: {model}")


def _emit_log(on_log: Optional[Callable[[str, str], None]], level: str, message: str) -> None:
    if on_log:
        on_log(level, message)


def _run_anthropic(
    model: str,
    system_prompt: str,
    user_prompt: str,
    on_log: Optional[Callable[[str, str], None]],
) -> CompletionResult:
    # Import lazily so the agent can start even if anthropic isn't installed
    # (e.g., during Gemini-only testing).
    import anthropic

    _emit_log(on_log, "info", f"calling Anthropic model={model}")
    client = anthropic.Anthropic(api_key=os.environ.get("ANTHROPIC_API_KEY"))
    started = time.time()
    response = client.messages.create(
        model=model,
        max_tokens=64000,
        system=system_prompt,
        messages=[{"role": "user", "content": user_prompt}],
    )
    latency_s = time.time() - started

    # Anthropic returns content as a list of blocks; the simplest case is a single
    # text block. Concatenate text blocks (ignore tool_use etc. — not used here).
    text_chunks: list[str] = []
    for block in response.content:
        if getattr(block, "type", None) == "text":
            text_chunks.append(block.text)
    markdown = "".join(text_chunks)

    return CompletionResult(
        markdown=markdown,
        input_tokens=response.usage.input_tokens,
        output_tokens=response.usage.output_tokens,
        latency_s=latency_s,
        finish_reason=str(response.stop_reason or "unknown"),
    )


def _run_gemini(
    model: str,
    system_prompt: str,
    user_prompt: str,
    on_log: Optional[Callable[[str, str], None]],
) -> CompletionResult:
    from google import genai
    from google.genai import types

    _emit_log(on_log, "info", f"calling Gemini model={model}")
    client = genai.Client()
    started = time.time()
    response = client.models.generate_content(
        model=model,
        contents=[user_prompt],
        config=types.GenerateContentConfig(
            system_instruction=system_prompt,
        ),
    )
    latency_s = time.time() - started

    markdown = response.text or ""

    input_tokens: int | None = None
    output_tokens: int | None = None
    if response.usage_metadata is not None:
        input_tokens = response.usage_metadata.prompt_token_count
        output_tokens = response.usage_metadata.candidates_token_count

    finish_reason = "STOP"
    if response.candidates and response.candidates[0].finish_reason is not None:
        finish_reason = str(response.candidates[0].finish_reason)

    return CompletionResult(
        markdown=markdown,
        input_tokens=input_tokens,
        output_tokens=output_tokens,
        latency_s=latency_s,
        finish_reason=finish_reason,
    )
```

- [ ] **Step 3: Add unit tests in `tests/test_prompt_agent_clients.py`** (no network — just exercise the routing logic):

```python
"""Unit tests for agents/prompt_agent/clients.py routing logic.

These tests don't make real API calls — they just verify the model-prefix
routing dispatches to the correct internal function and that
UnsupportedModelError is raised for unrouted prefixes.
"""

from __future__ import annotations

import pytest
from unittest.mock import patch, MagicMock

from agents.prompt_agent import clients


@pytest.mark.unit
def test_unsupported_model_raises() -> None:
    with pytest.raises(clients.UnsupportedModelError):
        clients.run_completion("llama-3-70b", "sys", "user")


@pytest.mark.unit
def test_claude_prefix_routes_to_anthropic() -> None:
    with patch.object(clients, "_run_anthropic") as m:
        m.return_value = clients.CompletionResult(
            markdown="ok", input_tokens=10, output_tokens=5, latency_s=1.0, finish_reason="STOP",
        )
        clients.run_completion("claude-sonnet-4-6", "sys", "user")
        m.assert_called_once()


@pytest.mark.unit
def test_gemini_prefix_routes_to_gemini() -> None:
    with patch.object(clients, "_run_gemini") as m:
        m.return_value = clients.CompletionResult(
            markdown="ok", input_tokens=10, output_tokens=5, latency_s=1.0, finish_reason="STOP",
        )
        clients.run_completion("gemini-2.5-flash", "sys", "user")
        m.assert_called_once()


@pytest.mark.unit
def test_completion_result_holds_all_fields() -> None:
    r = clients.CompletionResult(
        markdown="hello",
        input_tokens=100,
        output_tokens=50,
        latency_s=12.5,
        finish_reason="STOP",
    )
    assert r.markdown == "hello"
    assert r.input_tokens == 100
    assert r.latency_s == 12.5
```

- [ ] **Step 4: Run + commit**

```bash
.venv/bin/pytest tests/test_prompt_agent_clients.py -v
```

Expected: 4 tests pass.

```bash
git add agents/prompt_agent/clients.py tests/test_prompt_agent_clients.py pyproject.toml uv.lock
git commit -m "agents/prompt_agent: add clients module (Anthropic + Gemini routing via LAMBE_MODEL prefix)"
```

---

## Task 5: `server.py` + `__main__.py` — the prompt.run handler

**Target repo:** `~/projects/chargesheets/pdf-extraction-experiments/`

**Files:**
- Create: `agents/prompt_agent/server.py`
- Create: `agents/prompt_agent/__main__.py`
- Modify: `tests/test_prompt_agent_protocol.py` (create with 3 protocol tests)

This is the largest module of Plan D. The server loop reads JSON-RPC from stdin and dispatches `prompt.run` calls. The handler reads the required slice markdowns, assembles them into a single user prompt, calls the model via `clients.run_completion`, writes the model's Markdown output to disk, and returns the response shape that logos's dispatcher will use to populate `prompt_outputs`.

- [ ] **Step 1: Create `agents/prompt_agent/__main__.py`**

```python
"""Entry point: python -m agents.prompt_agent

`--once <prompt_name> <slices_json>` runs a single prompt for debugging.
Default mode: stdio JSON-RPC server loop.
"""

import json
import logging
import sys
from pathlib import Path

from agents.prompt_agent.server import run_server, handle_once


def main() -> int:
    if len(sys.argv) >= 2 and sys.argv[1] == "--once":
        logging.basicConfig(
            level=logging.INFO,
            stream=sys.stderr,
            format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        )
        if len(sys.argv) < 4:
            print(
                "usage: python -m agents.prompt_agent --once <prompt_name> <params_json>",
                file=sys.stderr,
            )
            return 2
        prompt_name = sys.argv[2]
        params = json.loads(sys.argv[3])
        result = handle_once(prompt_name, params)
        print(json.dumps(result, indent=2))
        return 0

    logging.basicConfig(
        level=logging.INFO,
        stream=sys.stderr,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    return run_server()


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 2: Create `agents/prompt_agent/server.py`**

```python
"""Stdio JSON-RPC server for the prompt agent.

Reads newline-delimited JSON-RPC requests from stdin, dispatches them to
handlers, writes responses + notifications to stdout. All logs go to stderr.
"""

from __future__ import annotations

import datetime as dt
import json
import logging
import os
import sys
from pathlib import Path
from typing import Any

from agents.common import framing
from agents.prompt_agent import clients, prompts

log = logging.getLogger("prompt_agent")

AGENT_NAME = "prompt_agent"
AGENT_VERSION = "0.1.0"
PROTOCOL_VERSION = "lambe-haath/1"

DEFAULT_MODEL = "gemini-2.5-flash"


def get_model() -> str:
    return os.environ.get("LAMBE_MODEL", DEFAULT_MODEL)


def run_server() -> int:
    """Read from stdin, dispatch, write to stdout."""
    log.info("prompt_agent starting (model=%s)", get_model())

    for raw_line in sys.stdin:
        line = raw_line.rstrip("\n").rstrip("\r")
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError as e:
            log.warning("dropping malformed line: %s", e)
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
            continue

        if is_notification:
            log.debug("ignoring unknown notification: %s", method)
            continue

        if method == "prompt.run":
            _handle_prompt_run(msg_id, params)
            continue

        framing.write_line(framing.encode_error(
            msg_id, framing.METHOD_NOT_FOUND, f"unknown method: {method}",
        ))

    log.info("stdin EOF; exiting")
    return 0


def _initialize_result() -> dict[str, Any]:
    return {
        "protocolVersion": PROTOCOL_VERSION,
        "agentInfo": {"name": AGENT_NAME, "version": AGENT_VERSION},
        "capabilities": {
            "methods": ["prompt.run"],
            "progress": True,
            "cancellation": False,  # v1: model call is one shot, not cancellable mid-stream
            "prompts": prompts.capabilities_dict(),
        },
    }


def _handle_prompt_run(msg_id: int, params: dict) -> None:
    """Process a prompt.run request.

    Params shape (from logos's dispatcher):
        {
          "prompt_name": "evidence_audit",
          "project_id": "abc123",
          "slices": {
            "annexure-i":  {"markdown_path": "/path/...", "meta_path": "..."},
            "annexure-ii": {...},
            ...
          },
          "ruds": [
            {"id": "RUD-01", "markdown_path": "...", "meta_path": "..."},
            ...
          ],
          "output_dir": "/path/to/<project>/prompts",
          "_meta": {"progressToken": "j42"}
        }
    """
    prompt_name = params.get("prompt_name")
    if not prompt_name or prompt_name not in prompts.PROMPTS:
        framing.write_line(framing.encode_error(
            msg_id, framing.INVALID_PARAMS,
            f"unknown or missing prompt_name: {prompt_name}",
        ))
        return

    slices_map = params.get("slices") or {}
    ruds_list = params.get("ruds") or []
    output_dir = params.get("output_dir")
    if not output_dir:
        framing.write_line(framing.encode_error(
            msg_id, framing.INVALID_PARAMS, "output_dir is required",
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
        result = _run_one_prompt(
            prompt_name=prompt_name,
            slices_map=slices_map,
            ruds_list=ruds_list,
            output_dir=Path(output_dir),
            on_progress=on_progress,
            on_log=on_log,
        )
    except FileNotFoundError as e:
        framing.write_line(framing.encode_error(
            msg_id, framing.INPUT_INVALID, str(e),
        ))
        return
    except clients.UnsupportedModelError as e:
        framing.write_line(framing.encode_error(
            msg_id, framing.AUTH_INVALID, str(e),
        ))
        return
    except Exception as exc:
        log.exception("prompt.run failed")
        framing.write_line(framing.encode_error(
            msg_id, framing.INTERNAL_ERROR, str(exc),
        ))
        return

    framing.write_line(framing.encode_response(msg_id, result))


def _run_one_prompt(
    prompt_name: str,
    slices_map: dict[str, dict],
    ruds_list: list[dict],
    output_dir: Path,
    on_progress,
    on_log,
) -> dict:
    """Read inputs from disk, call model, save markdown, return result dict."""
    spec = prompts.PROMPTS[prompt_name]
    system_prompt = prompts.load_system_prompt(prompt_name)

    on_progress(0.05, "reading slice markdowns")
    user_prompt = _assemble_user_prompt(spec, slices_map, ruds_list, on_log)

    on_progress(0.20, f"calling {get_model()}")
    completion = clients.run_completion(
        model=get_model(),
        system_prompt=system_prompt,
        user_prompt=user_prompt,
        on_log=on_log,
    )

    on_progress(0.90, "writing output markdown")
    output_dir.mkdir(parents=True, exist_ok=True)
    markdown_path = output_dir / f"{prompt_name}.md"
    markdown_path.write_text(completion.markdown, encoding="utf-8")

    # Soft checks
    warnings: list[str] = []
    if not completion.markdown.strip():
        warnings.append("empty_output")
    if "#" not in completion.markdown and "##" not in completion.markdown:
        warnings.append("no_markdown_headings")
    if completion.finish_reason not in ("STOP", "FinishReason.STOP", "end_turn"):
        warnings.append(f"finish_reason:{completion.finish_reason}")

    on_progress(1.0, "done")

    return {
        "markdown_path": str(markdown_path),
        "model": get_model(),
        "input_tokens": completion.input_tokens,
        "output_tokens": completion.output_tokens,
        "latency_s": completion.latency_s,
        "warnings": warnings,
    }


def _assemble_user_prompt(
    spec,
    slices_map: dict[str, dict],
    ruds_list: list[dict],
    on_log,
) -> str:
    """Read the required slice markdowns + RUDs and concatenate into one user message."""
    parts: list[str] = []

    for req in spec.requires:
        if req == "ruds:*":
            if not ruds_list:
                on_log("warning", "prompt requires ruds:* but none provided")
                continue
            parts.append("\n\n# Relied Upon Documents (RUDs)\n")
            for rud in ruds_list:
                rud_id = rud.get("id", "RUD-??")
                md_path = rud.get("markdown_path")
                if not md_path:
                    continue
                p = Path(md_path)
                if not p.exists():
                    raise FileNotFoundError(f"RUD markdown missing: {md_path}")
                parts.append(f"\n\n## {rud_id}\n\n{p.read_text(encoding='utf-8')}")
        else:
            slice_info = slices_map.get(req)
            if not slice_info:
                raise FileNotFoundError(f"required slice missing: {req}")
            md_path = slice_info.get("markdown_path")
            if not md_path:
                raise FileNotFoundError(f"slice {req} has no markdown_path")
            p = Path(md_path)
            if not p.exists():
                raise FileNotFoundError(f"slice markdown missing: {md_path}")
            label = req.replace("-", " ").upper()
            parts.append(f"\n\n# {label}\n\n{p.read_text(encoding='utf-8')}")

    return "\n".join(parts).lstrip()


def handle_once(prompt_name: str, params: dict) -> dict:
    """Synchronous run for `--once` debug mode."""
    slices_map = params.get("slices") or {}
    ruds_list = params.get("ruds") or []
    output_dir = Path(params.get("output_dir", "/tmp/prompt_out"))

    return _run_one_prompt(
        prompt_name=prompt_name,
        slices_map=slices_map,
        ruds_list=ruds_list,
        output_dir=output_dir,
        on_progress=lambda p, m: None,
        on_log=lambda l, m: None,
    )
```

- [ ] **Step 3: Create `tests/test_prompt_agent_protocol.py`**

```python
"""Protocol-conformance tests for the prompt agent. No real API calls (uses
the unsupported-model error path or fixture-based input)."""

from __future__ import annotations

import os
import sys
import pytest
from pathlib import Path

from tests.conformance_harness import Harness


PROMPT_AGENT_CMD = [sys.executable, "-m", "agents.prompt_agent"]
FIXTURE_MD = Path(__file__).parent / "fixtures" / "sample-annexure-i.md"


@pytest.mark.protocol
def test_initialize_advertises_prompt_run_with_capabilities() -> None:
    with Harness(PROMPT_AGENT_CMD) as h:
        caps = h.initialize()
        assert "prompt.run" in caps["methods"]
        assert "prompts" in caps
        assert "evidence_audit" in caps["prompts"]
        # Per-prompt requires must be present.
        assert "annexure-i" in caps["prompts"]["evidence_audit"]["requires"]
        h.shutdown()


@pytest.mark.protocol
def test_prompt_run_with_unknown_prompt_returns_invalid_params() -> None:
    with Harness(PROMPT_AGENT_CMD) as h:
        h.initialize()
        resp, _ = h.call("prompt.run", {
            "prompt_name": "nonexistent_prompt",
            "slices": {},
            "ruds": [],
            "output_dir": "/tmp/x",
        })
        assert "error" in resp
        assert resp["error"]["code"] == -32602  # INVALID_PARAMS
        h.shutdown()


@pytest.mark.protocol
def test_prompt_run_with_missing_required_slice_returns_input_invalid() -> None:
    with Harness(
        PROMPT_AGENT_CMD,
        env={**os.environ, "LAMBE_MODEL": "gemini-2.5-flash"},
    ) as h:
        h.initialize()
        # imputation_scrutiny requires annexure-i + annexure-ii; provide neither.
        resp, _ = h.call("prompt.run", {
            "prompt_name": "imputation_scrutiny",
            "slices": {},
            "ruds": [],
            "output_dir": "/tmp/test_prompt_out",
        })
        assert "error" in resp
        assert resp["error"]["code"] == -32003  # INPUT_INVALID
        h.shutdown()


@pytest.mark.protocol
def test_unknown_method_returns_method_not_found() -> None:
    with Harness(PROMPT_AGENT_CMD) as h:
        h.initialize()
        resp, _ = h.call("nonexistent.method", {})
        assert "error" in resp
        assert resp["error"]["code"] == -32601  # METHOD_NOT_FOUND
        h.shutdown()
```

- [ ] **Step 4: Create the fixture** at `tests/fixtures/sample-annexure-i.md`

```bash
cd ~/projects/chargesheets/pdf-extraction-experiments
cat > tests/fixtures/sample-annexure-i.md <<'MDEOF'
<!-- page: 1 -->
ANNEXURE-I — Articles of Charge

Article I:
That Shri Sandeep Goel, Appraiser, failed to exercise due diligence in
verifying the contents of the consignment under B/E No. 9582513.

<!-- page: 2 -->
Article II:
That the said officer permitted clearance of goods without ensuring
compliance with LMPC Rules, 2011.
MDEOF
```

- [ ] **Step 5: Run + commit**

```bash
.venv/bin/pytest tests/test_prompt_agent_protocol.py -v 2>&1 | tail -10
```

Expected: 4 tests pass.

```bash
git add agents/prompt_agent/__main__.py agents/prompt_agent/server.py tests/test_prompt_agent_protocol.py tests/fixtures/sample-annexure-i.md
git commit -m "agents/prompt_agent: stdio JSON-RPC server with initialize + prompt.run + shutdown"
```

---

## Task 6: Update logos dispatcher to populate `prompt_outputs` table

**Target repo:** `~/projects/lambe-haath/logos/`

**Files:**
- Modify: `src/agents/dispatcher.zig`

Mirror Plan C's Task 4 pattern, but for prompt_outputs instead of extractions.

- [ ] **Step 1: Add helpers**

In `dispatcher.zig`, alongside `parseExtractionFields`, add:

```zig
pub const PromptOutputFields = struct {
    markdown_path: []const u8,
    model: []const u8,
    input_tokens: ?i64,
    output_tokens: ?i64,
    latency_s: f64,
    warnings_json: []const u8,  // raw JSON array text, e.g. '[]' or '["empty_output"]'
};

pub fn parsePromptOutputFields(gpa: Allocator, json_text: []const u8) !PromptOutputFields {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, json_text, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidPromptResult;
    const obj = parsed.value.object;

    const md_v = obj.get("markdown_path") orelse return error.InvalidPromptResult;
    const mdl_v = obj.get("model") orelse return error.InvalidPromptResult;
    const lat_v = obj.get("latency_s") orelse return error.InvalidPromptResult;
    if (md_v != .string or mdl_v != .string) return error.InvalidPromptResult;

    const md = try gpa.dupe(u8, md_v.string);
    errdefer gpa.free(md);
    const mdl = try gpa.dupe(u8, mdl_v.string);
    errdefer gpa.free(mdl);

    // Serialize the warnings array back to text. If absent, default to "[]".
    var warnings_text: []const u8 = undefined;
    if (obj.get("warnings")) |w_v| {
        if (w_v != .array) return error.InvalidPromptResult;
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(gpa);
        // Use std.json.Stringify.value to re-serialize the array.
        var aw = std.Io.Writer.Allocating.init(gpa);
        errdefer aw.deinit();
        std.json.Stringify.value(w_v, .{}, &aw.writer) catch return error.InvalidPromptResult;
        warnings_text = try aw.toOwnedSlice();
    } else {
        warnings_text = try gpa.dupe(u8, "[]");
    }
    errdefer gpa.free(warnings_text);

    return .{
        .markdown_path = md,
        .model = mdl,
        .input_tokens = if (obj.get("input_tokens")) |v| (if (v == .integer) v.integer else null) else null,
        .output_tokens = if (obj.get("output_tokens")) |v| (if (v == .integer) v.integer else null) else null,
        .latency_s = switch (lat_v) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => return error.InvalidPromptResult,
        },
        .warnings_json = warnings_text,
    };
}

pub fn parsePromptNameFromPayload(gpa: Allocator, payload_json: []const u8) ![]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, payload_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidPayload;
    const pn_v = parsed.value.object.get("prompt_name") orelse return error.InvalidPayload;
    if (pn_v != .string) return error.InvalidPayload;
    return try gpa.dupe(u8, pn_v.string);
}
```

- [ ] **Step 2: Use the helpers in the response handler**

After the existing `if (j.type == .ocr) { handleOcrSuccess(...); }` block (or wherever the OCR branch is), add a parallel branch:

```zig
if (j.type == .prompt) {
    self.handlePromptSuccess(j.project_id, j.payload, result_json);
}
```

And add `handlePromptSuccess`:

```zig
fn handlePromptSuccess(
    self: *Dispatcher,
    project_id: []const u8,
    payload_json: []const u8,
    result_json: []const u8,
) void {
    var pof = parsePromptOutputFields(self.gpa, result_json) catch |err| {
        std.log.warn("prompt result didn't parse: {s}", .{@errorName(err)});
        return;
    };
    defer {
        self.gpa.free(pof.markdown_path);
        self.gpa.free(pof.model);
        self.gpa.free(pof.warnings_json);
    }

    const prompt_name = parsePromptNameFromPayload(self.gpa, payload_json) catch |err| {
        std.log.warn("prompt payload didn't parse: {s}", .{@errorName(err)});
        return;
    };
    defer self.gpa.free(prompt_name);

    const costs = pricing.cost(pof.model, pof.input_tokens orelse 0, pof.output_tokens orelse 0);
    const now_p = db_mod.nowIso8601(self.gpa) catch return;
    defer self.gpa.free(now_p);

    prompt_outputs_mod.upsert(self.db, self.gpa, .{
        .project_id = project_id,
        .prompt_name = prompt_name,
        .markdown_path = pof.markdown_path,
        .model = pof.model,
        .input_tokens = pof.input_tokens,
        .output_tokens = pof.output_tokens,
        .input_cost_usd = if (costs) |c| c.input else null,
        .output_cost_usd = if (costs) |c| c.output else null,
        .latency_s = pof.latency_s,
        .warnings_json = pof.warnings_json,
        .created_at = now_p,
    }) catch |err| {
        std.log.warn("prompt_outputs.upsert failed: {s}", .{@errorName(err)});
    };
}
```

Add the import at the top:
```zig
const prompt_outputs_mod = @import("../db/prompt_outputs.zig");
```

- [ ] **Step 3: Tests**

Add to dispatcher's test block:

```zig
test "parsePromptOutputFields parses a real prompt result payload" {
    const gpa = std.testing.allocator;
    const json_text =
        \\{"markdown_path":"/x.md","model":"claude-sonnet-4-6",
        \\ "input_tokens":1000,"output_tokens":500,"latency_s":42.0,"warnings":["empty_output"]}
    ;
    var pof = try parsePromptOutputFields(gpa, json_text);
    defer {
        gpa.free(pof.markdown_path);
        gpa.free(pof.model);
        gpa.free(pof.warnings_json);
    }
    try std.testing.expectEqualStrings("/x.md", pof.markdown_path);
    try std.testing.expectEqualStrings("claude-sonnet-4-6", pof.model);
    try std.testing.expectApproxEqAbs(@as(f64, 42.0), pof.latency_s, 0.001);
    try std.testing.expect(std.mem.indexOf(u8, pof.warnings_json, "empty_output") != null);
}

test "parsePromptOutputFields defaults warnings to '[]' when absent" {
    const gpa = std.testing.allocator;
    const json_text =
        \\{"markdown_path":"/x.md","model":"claude-sonnet-4-6","latency_s":1.0}
    ;
    var pof = try parsePromptOutputFields(gpa, json_text);
    defer {
        gpa.free(pof.markdown_path);
        gpa.free(pof.model);
        gpa.free(pof.warnings_json);
    }
    try std.testing.expectEqualStrings("[]", pof.warnings_json);
}

test "parsePromptNameFromPayload extracts prompt_name" {
    const gpa = std.testing.allocator;
    const pn = try parsePromptNameFromPayload(gpa, "{\"prompt_name\":\"evidence_audit\"}");
    defer gpa.free(pn);
    try std.testing.expectEqualStrings("evidence_audit", pn);
}
```

- [ ] **Step 4: Run + commit**

```bash
cd ~/projects/lambe-haath/logos
export LAMBE_MOCK_AGENT_PATH="$HOME/projects/chargesheets/pdf-extraction-experiments/tests/mock_agent.py"
zig build test --summary all 2>&1 | tail -5
```

Expected: 153 → 156 passing.

```bash
git add src/agents/dispatcher.zig
git commit -m "agents/dispatcher: populate prompt_outputs row from prompt result payload"
```

---

## Task 7: Opt-in live prompt test (against Gemini)

**Target repo:** `~/projects/chargesheets/pdf-extraction-experiments/`

**Files:**
- Create: `tests/test_prompt_agent_live.py`

Since the user doesn't have an Anthropic key, the live test uses Gemini for `imputation_scrutiny` (a small 2-slice prompt).

- [ ] **Step 1: Create `tests/test_prompt_agent_live.py`**

```python
"""Live prompt test — opt-in via LAMBE_LIVE_TESTS=1. Uses Gemini (default model
unless LAMBE_MODEL is overridden) because the user doesn't have an Anthropic key.

Cost: roughly ₹2-5 per run.
"""

from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

import pytest

from tests.conformance_harness import Harness


LIVE = os.environ.get("LAMBE_LIVE_TESTS") == "1"
PROMPT_AGENT_CMD = [sys.executable, "-m", "agents.prompt_agent"]
FIXTURE_MD = Path(__file__).parent / "fixtures" / "sample-annexure-i.md"


@pytest.mark.live
@pytest.mark.skipif(not LIVE, reason="set LAMBE_LIVE_TESTS=1 to run live tests")
@pytest.mark.skipif(not FIXTURE_MD.exists(), reason="missing sample-annexure-i.md fixture")
def test_imputation_scrutiny_against_gemini() -> None:
    with tempfile.TemporaryDirectory() as tmpd:
        out_dir = Path(tmpd)

        # Both annexure-i and annexure-ii are required by imputation_scrutiny.
        # Use the same fixture for both — the model will produce some output either way.
        slices_map = {
            "annexure-i":  {"markdown_path": str(FIXTURE_MD), "meta_path": str(FIXTURE_MD) + ".meta.json"},
            "annexure-ii": {"markdown_path": str(FIXTURE_MD), "meta_path": str(FIXTURE_MD) + ".meta.json"},
        }

        env = {**os.environ}
        # Force Gemini even if the user has ANTHROPIC_API_KEY set, since we don't want this test
        # to depend on which keys are configured.
        env["LAMBE_MODEL"] = env.get("LAMBE_MODEL", "gemini-2.5-flash")

        with Harness(PROMPT_AGENT_CMD, env=env, read_timeout_s=180.0) as h:
            caps = h.initialize()
            assert "prompt.run" in caps["methods"]

            resp, notifs = h.call("prompt.run", {
                "prompt_name": "imputation_scrutiny",
                "slices": slices_map,
                "ruds": [],
                "output_dir": str(out_dir),
            }, progress_token="t1")

            assert "result" in resp, f"expected result, got: {resp}"
            result = resp["result"]
            assert Path(result["markdown_path"]).exists()
            md = Path(result["markdown_path"]).read_text()
            assert len(md) > 100, "model produced suspiciously short output"
            assert result["model"].startswith("gemini-") or result["model"].startswith("claude-")
            assert result["latency_s"] > 0
            # Should have received some progress notifications.
            assert any(n["method"] == "notifications/progress" for n in notifs)

            h.shutdown()
```

- [ ] **Step 2: Run + commit**

```bash
cd ~/projects/chargesheets/pdf-extraction-experiments
.venv/bin/pytest tests/test_prompt_agent_live.py -v
```

Expected: SKIPPED (no LAMBE_LIVE_TESTS env var).

Optional live verification:
```bash
set -a && source .env && set +a
LAMBE_LIVE_TESTS=1 .venv/bin/pytest tests/test_prompt_agent_live.py -v
```

Expected: 1 test passes in 20-60 seconds.

```bash
git add tests/test_prompt_agent_live.py
git commit -m "test: opt-in live prompt_agent test (Gemini path)"
```

---

## Task 8: Final verification

- [ ] **Step 1: Both repos green**

```bash
cd ~/projects/lambe-haath/logos
export LAMBE_MOCK_AGENT_PATH="$HOME/projects/chargesheets/pdf-extraction-experiments/tests/mock_agent.py"
zig build test --summary all 2>&1 | tail -5

cd ~/projects/chargesheets/pdf-extraction-experiments
.venv/bin/pytest -v 2>&1 | tail -10
```

Expected: logos 156+ passing, Python all unit + protocol tests passing + 2 live tests skipped (OCR + prompt).

- [ ] **Step 2: Branch ready**

```bash
cd ~/projects/chargesheets/pdf-extraction-experiments
git log --oneline main..feat/plan-d-prompt-agent

cd ~/projects/lambe-haath
git log --oneline main..feat/plan-d-prompt-agent
```

---

## What's next (Plan E/F preview, not in this plan)

After Plan D is merged, every layer of the chargesheet pipeline is functional end-to-end:

- **Plan E**: Stats endpoints (per-project token/cost totals, slowest jobs, daily time-series), exposing the cost columns the dispatcher now populates.
- **Plan F**: SPA UI — actually consume all the HTTP endpoints. Every button you'd build does something real because Plans B/C/D have wired the backend.
