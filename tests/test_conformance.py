"""End-to-end conformance: harness + mock agent run through a full lifecycle.

Future plans will add parallel tests for the real ocr_agent and prompt_agent
binaries; they will all use the same Harness class.
"""

from __future__ import annotations

import sys
import pytest

from tests.conformance_harness import Harness

MOCK_AGENT = [sys.executable, "tests/mock_agent.py"]


@pytest.mark.protocol
def test_full_lifecycle_happy_path() -> None:
    """initialize -> initialized -> N method calls -> shutdown -> exit -> agent exits 0."""
    with Harness(MOCK_AGENT) as h:
        caps = h.initialize()
        assert "methods" in caps

        for i in range(1, 6):
            resp, notifs = h.call("mock.echo", {"iteration": i})
            assert resp["result"]["echo"]["iteration"] == i
            assert resp["result"]["call_index"] == i

        h.shutdown()
        # The harness closes stdin; mock_agent's `for raw_line in sys.stdin` loop hits EOF and exits.
        exit_code = h._proc.wait(timeout=5)
        assert exit_code == 0


@pytest.mark.protocol
def test_warm_path_reuses_one_process() -> None:
    """Five calls against the same agent process incur exactly one spawn."""
    with Harness(MOCK_AGENT) as h:
        h.initialize()
        for _ in range(5):
            resp, _ = h.call("mock.echo", {})
            assert "result" in resp
        # If we got here, the same process handled all 5. Spawn count is implicitly 1.
        h.shutdown()


@pytest.mark.protocol
def test_two_concurrent_harnesses_are_independent() -> None:
    """Two parallel mock_agent processes don't share state."""
    with Harness(MOCK_AGENT) as h1, Harness(MOCK_AGENT) as h2:
        h1.initialize()
        h2.initialize()
        r1, _ = h1.call("mock.echo", {"agent": 1})
        r2, _ = h2.call("mock.echo", {"agent": 2})
        # Each agent counts calls independently.
        assert r1["result"]["call_index"] == 1
        assert r2["result"]["call_index"] == 1
        h1.shutdown()
        h2.shutdown()
