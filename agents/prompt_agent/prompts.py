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


# Slice-kind sentinels in `requires`:
#   "annexure-i" / "annexure-ii" / "annexure-iii" / "annexure-iv" — specific annexures
#   "ruds:*"                                                       — every RUD in the project
@dataclass(frozen=True)
class PromptSpec:
    name: str
    system_template_path: str  # relative to prompts/ directory
    requires: tuple[str, ...]  # slice-kind keys the agent expects in the input
    model: str | None = None   # override LAMBE_MODEL; None → use env default


PROMPTS: dict[str, PromptSpec] = {
    "charge_memo_analysis": PromptSpec(
        name="charge_memo_analysis",
        system_template_path="charge_memo_analysis.md",
        requires=("annexure-i", "annexure-ii", "annexure-iii", "annexure-iv"),
        model="gemini-3.5-flash",
    ),
    "imputation_scrutiny": PromptSpec(
        name="imputation_scrutiny",
        system_template_path="imputation_scrutiny.md",
        requires=("annexure-i", "annexure-ii"),
        model="gemini-3.5-flash",
    ),
    "time_chart": PromptSpec(
        name="time_chart",
        system_template_path="time_chart.md",
        requires=("annexure-i", "annexure-ii"),
        model="gemini-3.5-flash",
    ),
    "evidence_audit": PromptSpec(
        name="evidence_audit",
        system_template_path="evidence_audit.md",
        requires=("annexure-i", "annexure-ii", "annexure-iii", "annexure-iv", "ruds:*"),
        model="gemini-3.5-flash",
    ),
    "objection_brief": PromptSpec(
        name="objection_brief",
        system_template_path="objection_brief.md",
        requires=("annexure-i", "annexure-ii", "annexure-iii", "annexure-iv", "ruds:*"),
        model="gemini-3.5-flash",
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
