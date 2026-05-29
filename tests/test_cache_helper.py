"""Unit tests for agents/prompt_agent/cache.py.

These tests don't make real API calls — they verify the hash helpers
and the short-circuit logic for non-Gemini models.
"""

from __future__ import annotations

import pytest

from agents.prompt_agent.cache import _hash_content, get_or_create_cache


@pytest.mark.unit
def test_hash_is_stable() -> None:
    slices = {"annexure-i": {"markdown_path": "/tmp/nope.md"}}
    ruds = [{"id": "RUD-01", "markdown_path": "/tmp/nope2.md"}]
    h1 = _hash_content(slices, ruds)
    h2 = _hash_content(slices, ruds)
    assert h1 == h2


@pytest.mark.unit
def test_hash_differs_on_different_slice_key() -> None:
    slices_a = {"annexure-i": {"markdown_path": "/tmp/nope.md"}}
    slices_b = {"annexure-ii": {"markdown_path": "/tmp/nope.md"}}
    ruds: list = []
    assert _hash_content(slices_a, ruds) != _hash_content(slices_b, ruds)


@pytest.mark.unit
def test_hash_differs_on_different_rud_id() -> None:
    slices: dict = {}
    ruds_a = [{"id": "RUD-01", "markdown_path": "/tmp/a.md"}]
    ruds_b = [{"id": "RUD-02", "markdown_path": "/tmp/a.md"}]
    assert _hash_content(slices, ruds_a) != _hash_content(slices, ruds_b)


@pytest.mark.unit
def test_hash_is_order_independent_for_slices() -> None:
    """Slice iteration order MUST NOT affect the hash (we sort by key)."""
    slices_a = {"annexure-ii": {"markdown_path": "/tmp/b.md"}, "annexure-i": {"markdown_path": "/tmp/a.md"}}
    slices_b = {"annexure-i": {"markdown_path": "/tmp/a.md"}, "annexure-ii": {"markdown_path": "/tmp/b.md"}}
    ruds: list = []
    assert _hash_content(slices_a, ruds) == _hash_content(slices_b, ruds)


@pytest.mark.unit
def test_non_gemini_model_skips_caching() -> None:
    """get_or_create_cache MUST return None immediately for non-Gemini models."""
    result = get_or_create_cache("claude-sonnet-4-6", {}, [])
    assert result is None


@pytest.mark.unit
def test_anthropic_model_skips_caching() -> None:
    result = get_or_create_cache("claude-opus-4-5", {"s": {"markdown_path": "/tmp/x.md"}}, [])
    assert result is None
