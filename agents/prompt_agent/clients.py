"""Model-routing layer for the prompt agent.

Picks the right SDK based on LAMBE_MODEL's prefix. Returns a uniform
CompletionResult.

Supported model families:
- claude-*  → Anthropic Messages API
- gemini-*  → Google genai (existing dep)
"""

from __future__ import annotations

import os
import time
from typing import Callable, Optional


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
    cached_content: Optional[str] = None,
) -> CompletionResult:
    """Dispatch to the right SDK based on model prefix."""
    if model.startswith("claude-"):
        # cached_content is ignored for Anthropic — V0 doesn't implement Anthropic caching.
        return _run_anthropic(model, system_prompt, user_prompt, on_log)
    if model.startswith("gemini-"):
        return _run_gemini(model, system_prompt, user_prompt, on_log, cached_content)
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
    # Lazy import so a Gemini-only test environment doesn't need anthropic installed.
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

    # Anthropic returns content as a list of blocks; concatenate text blocks.
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
    cached_content: Optional[str] = None,
) -> CompletionResult:
    from google import genai
    from google.genai import types

    _emit_log(on_log, "info", f"calling Gemini model={model}" + (f" (cached_content={cached_content})" if cached_content else ""))
    client = genai.Client()
    started = time.time()

    config_kwargs: dict = {"system_instruction": system_prompt}
    if cached_content:
        config_kwargs["cached_content"] = cached_content

    response = client.models.generate_content(
        model=model,
        contents=[user_prompt],
        config=types.GenerateContentConfig(**config_kwargs),
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
