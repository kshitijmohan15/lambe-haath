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
def test_evidence_audit_and_objection_brief_require_ruds_sentinel() -> None:
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
    # Per-prompt: imputation_scrutiny needs only annexure-i + annexure-ii
    assert caps["imputation_scrutiny"]["requires"] == ["annexure-i", "annexure-ii"]
