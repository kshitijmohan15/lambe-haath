"""Tests for the OCR agent's JSON-RPC framing.

Task 3 will append server-mode protocol-conformance tests to this file.
"""

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
    line = framing.encode_error(
        42,
        framing.UPSTREAM_RATE_LIMITED,
        "rate limited",
        {"retry_after_s": 30},
    )
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
    assert parsed["params"]["progressToken"] == "j1"


@pytest.mark.unit
def test_error_code_constants() -> None:
    # Standard codes
    assert framing.PARSE_ERROR == -32700
    assert framing.METHOD_NOT_FOUND == -32601
    # Domain codes
    assert framing.CANCELED == -32099
    assert framing.UPSTREAM_API_ERROR == -32001
    assert framing.AUTH_INVALID == -32005


# ---- Protocol-conformance tests (server mode) ----

import sys as _sys
from tests.conformance_harness import Harness


OCR_AGENT_CMD = [_sys.executable, "-m", "agents.ocr_agent"]


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
        assert resp["error"]["code"] == -32601  # METHOD_NOT_FOUND
        h.shutdown()
