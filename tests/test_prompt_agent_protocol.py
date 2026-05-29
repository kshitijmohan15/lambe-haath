"""Protocol-conformance tests for the prompt agent.

These tests exercise the JSON-RPC lifecycle and error paths without making
real API calls — they hit only the "early return on validation failure" paths
in _handle_prompt_run.
"""

from __future__ import annotations

import os
import sys
import pytest

from tests.conformance_harness import Harness


PROMPT_AGENT_CMD = [sys.executable, "-m", "agents.prompt_agent"]


@pytest.mark.protocol
def test_initialize_advertises_prompt_run_with_capabilities() -> None:
    with Harness(PROMPT_AGENT_CMD) as h:
        caps = h.initialize()
        assert "prompt.run" in caps["methods"]
        assert "prompts" in caps
        # All 5 prompts must be advertised
        assert "evidence_audit" in caps["prompts"]
        # Per-prompt requires must be present
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
