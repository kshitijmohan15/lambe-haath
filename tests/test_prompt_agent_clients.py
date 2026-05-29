"""Unit tests for agents/prompt_agent/clients.py routing logic.

These tests don't make real API calls — they just verify the model-prefix
routing dispatches to the correct internal function and that
UnsupportedModelError is raised for unrouted prefixes.
"""

from __future__ import annotations

import pytest
from unittest.mock import patch

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
    assert r.finish_reason == "STOP"
