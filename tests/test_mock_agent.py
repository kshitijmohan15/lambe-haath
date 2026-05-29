"""Tests for tests/mock_agent.py — the polyglot protocol stub itself."""

from __future__ import annotations

import os
import sys
import pytest

from tests.conformance_harness import Harness, ProtocolError

MOCK_AGENT = [sys.executable, "tests/mock_agent.py"]


@pytest.mark.protocol
def test_initialize_returns_default_capabilities() -> None:
    with Harness(MOCK_AGENT) as h:
        caps = h.initialize()
        assert caps["methods"] == ["mock.echo"]
        assert caps["progress"] is True
        assert caps["cancellation"] is True
        h.shutdown()


@pytest.mark.protocol
def test_method_call_echoes_params() -> None:
    with Harness(MOCK_AGENT) as h:
        h.initialize()
        resp, notifs = h.call("mock.echo", {"hello": "world", "n": 42})
        assert resp["result"]["echo"] == {"hello": "world", "n": 42}
        assert resp["result"]["call_index"] == 1
        assert notifs == []
        h.shutdown()


@pytest.mark.protocol
def test_progress_notifications_emit_when_progress_token_passed() -> None:
    with Harness(MOCK_AGENT, env={**os.environ, "MOCK_PROGRESS_TICKS": "3"}) as h:
        h.initialize()
        resp, notifs = h.call("mock.echo", {"hi": 1}, progress_token="tok1")
        assert "result" in resp
        assert len(notifs) == 3
        for i, n in enumerate(notifs):
            assert n["method"] == "notifications/progress"
            assert n["params"]["progressToken"] == "tok1"
            assert n["params"]["progress"] == pytest.approx((i + 1) / 3)
        h.shutdown()


@pytest.mark.protocol
def test_capabilities_override_via_env() -> None:
    custom_caps = '{"methods":["ocr.extract","prompt.run"],"progress":true,"cancellation":false}'
    with Harness(MOCK_AGENT, env={**os.environ, "MOCK_CAPABILITIES": custom_caps}) as h:
        caps = h.initialize()
        assert caps["methods"] == ["ocr.extract", "prompt.run"]
        assert caps["cancellation"] is False
        h.shutdown()


@pytest.mark.protocol
def test_crash_on_first_call_via_fail_after() -> None:
    with Harness(MOCK_AGENT, env={**os.environ, "MOCK_FAIL_AFTER_N": "0"}) as h:
        h.initialize()
        with pytest.raises(ProtocolError):
            # The call will start; agent crashes; harness times out waiting for response.
            h.call("mock.echo", {"x": 1})


@pytest.mark.protocol
def test_crash_after_two_calls() -> None:
    with Harness(MOCK_AGENT, env={**os.environ, "MOCK_FAIL_AFTER_N": "2"}) as h:
        h.initialize()
        r1, _ = h.call("mock.echo", {"i": 1})
        assert "result" in r1
        r2, _ = h.call("mock.echo", {"i": 2})
        assert "result" in r2
        with pytest.raises(ProtocolError):
            h.call("mock.echo", {"i": 3})


@pytest.mark.protocol
def test_garbage_output_after_n_calls() -> None:
    with Harness(MOCK_AGENT, env={**os.environ, "MOCK_PARSE_GARBAGE_AFTER_N": "1"}) as h:
        h.initialize()
        # First call: clean response.
        r1, _ = h.call("mock.echo", {})
        assert "result" in r1
        # Second call: agent emits garbage; harness raises ProtocolError on JSON parse.
        with pytest.raises(ProtocolError):
            h.call("mock.echo", {})
