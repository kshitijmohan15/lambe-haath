"""Unit tests for the cache-hit system_prompt embedding in server._run_one_prompt.

These tests verify Option B: when a cache is in play, server.py MUST embed
the system_prompt into the user_prompt and MUST pass an empty
effective_system_prompt to clients.run_completion — so Gemini never receives
both cached_content and system_instruction in the same call.
"""

from __future__ import annotations

import pytest
from pathlib import Path
from unittest.mock import MagicMock, patch

from agents.prompt_agent import clients, server


@pytest.fixture()
def mock_completion():
    return clients.CompletionResult(
        markdown="## Analysis\n\nResult here.",
        input_tokens=100,
        output_tokens=50,
        latency_s=1.5,
        finish_reason="STOP",
    )


@pytest.mark.unit
def test_cache_hit_embeds_system_prompt_into_user_message(tmp_path, mock_completion):
    """When cache_name is non-None, system_prompt MUST be folded into user_prompt
    and effective_system_prompt MUST be empty on the clients.run_completion call."""
    system_prompt_text = "You are an expert analyst. Output structured markdown."

    with (
        patch("agents.prompt_agent.server.prompts.load_system_prompt", return_value=system_prompt_text),
        patch("agents.prompt_agent.server.cache_mod.get_or_create_cache", return_value="cachedContents/abc123"),
        patch("agents.prompt_agent.server.clients.run_completion", return_value=mock_completion) as mock_run,
    ):
        server._run_one_prompt(
            prompt_name="evidence_audit",
            slices_map={"annexure-i": {"markdown_path": "/tmp/fake.md"}},
            ruds_list=[],
            output_dir=tmp_path,
            on_progress=lambda p, m: None,
            on_log=lambda l, m: None,
        )

    mock_run.assert_called_once()
    call_kwargs = mock_run.call_args[1]

    # effective_system_prompt MUST be empty — no system_instruction sent to Gemini
    assert call_kwargs["system_prompt"] == "", (
        "expected empty system_prompt when cache is active, got: "
        f"{call_kwargs['system_prompt']!r}"
    )

    # user_prompt MUST contain the full system_prompt text as a prefix
    assert system_prompt_text in call_kwargs["user_prompt"], (
        "expected system_prompt text embedded in user_prompt, but it was absent"
    )

    # cached_content MUST be forwarded
    assert call_kwargs["cached_content"] == "cachedContents/abc123"


@pytest.mark.unit
def test_no_cache_uses_system_prompt_normally(tmp_path, mock_completion):
    """When cache_name is None, system_prompt MUST be passed as-is and
    user_prompt MUST NOT contain the system prompt text."""
    system_prompt_text = "You are an expert analyst. Output structured markdown."
    assembled_user = "## Annexure I\n\nContent here."

    with (
        patch("agents.prompt_agent.server.prompts.load_system_prompt", return_value=system_prompt_text),
        patch("agents.prompt_agent.server.cache_mod.get_or_create_cache", return_value=None),
        patch("agents.prompt_agent.server._assemble_user_prompt", return_value=assembled_user),
        patch("agents.prompt_agent.server.clients.run_completion", return_value=mock_completion) as mock_run,
    ):
        server._run_one_prompt(
            prompt_name="evidence_audit",
            slices_map={},
            ruds_list=[],
            output_dir=tmp_path,
            on_progress=lambda p, m: None,
            on_log=lambda l, m: None,
        )

    mock_run.assert_called_once()
    call_kwargs = mock_run.call_args[1]

    # system_prompt MUST be passed through unchanged
    assert call_kwargs["system_prompt"] == system_prompt_text

    # cached_content MUST be None (no cache)
    assert call_kwargs["cached_content"] is None


@pytest.mark.unit
def test_clients_gemini_omits_system_instruction_when_empty():
    """_run_gemini MUST NOT include system_instruction in config when system_prompt is empty.

    This is the defensive guard in clients.py: an empty string MUST result in
    system_instruction being absent from the GenerateContentConfig kwargs.
    """
    from google.genai import types

    captured_config: list[types.GenerateContentConfig] = []

    def fake_generate_content(model, contents, config):
        captured_config.append(config)
        fake_response = MagicMock()
        fake_response.text = "## Output"
        fake_response.usage_metadata = None
        fake_response.candidates = []
        return fake_response

    mock_client = MagicMock()
    mock_client.models.generate_content.side_effect = fake_generate_content

    with patch("google.genai.Client", return_value=mock_client):
        clients._run_gemini(
            model="gemini-2.5-flash",
            system_prompt="",          # empty — cache-hit path
            user_prompt="Do the thing.",
            on_log=None,
            cached_content="cachedContents/xyz",
        )

    assert len(captured_config) == 1
    cfg = captured_config[0]
    # system_instruction MUST be absent (not set) when system_prompt is empty
    assert not getattr(cfg, "system_instruction", None), (
        f"expected no system_instruction in config, got: {cfg.system_instruction!r}"
    )
    # cached_content MUST be forwarded
    assert cfg.cached_content == "cachedContents/xyz"
