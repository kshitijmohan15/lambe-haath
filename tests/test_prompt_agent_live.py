"""Live prompt test — opt-in via LAMBE_LIVE_TESTS=1.

Uses Gemini (default) because the user doesn't have an Anthropic key.
Cost: roughly ₹2-5 per run.
"""

from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

import pytest

from tests.conformance_harness import Harness


LIVE = os.environ.get("LAMBE_LIVE_TESTS") == "1"
PROMPT_AGENT_CMD = [sys.executable, "-m", "agents.prompt_agent"]
FIXTURE_MD = Path(__file__).parent / "fixtures" / "sample-annexure-i.md"


@pytest.mark.live
@pytest.mark.skipif(not LIVE, reason="set LAMBE_LIVE_TESTS=1 to run live tests")
@pytest.mark.skipif(not FIXTURE_MD.exists(), reason="missing sample-annexure-i.md fixture")
def test_imputation_scrutiny_against_gemini() -> None:
    with tempfile.TemporaryDirectory() as tmpd:
        out_dir = Path(tmpd)

        # imputation_scrutiny requires annexure-i and annexure-ii.
        # Use the same fixture for both — the model will produce some output either way.
        slices_map = {
            "annexure-i":  {
                "markdown_path": str(FIXTURE_MD),
                "meta_path": str(FIXTURE_MD) + ".meta.json",
            },
            "annexure-ii": {
                "markdown_path": str(FIXTURE_MD),
                "meta_path": str(FIXTURE_MD) + ".meta.json",
            },
        }

        env = {**os.environ}
        # Force Gemini even if ANTHROPIC_API_KEY is set, since we want a deterministic
        # routing path regardless of which keys are configured.
        env["LAMBE_MODEL"] = env.get("LAMBE_MODEL", "gemini-2.5-flash")

        with Harness(PROMPT_AGENT_CMD, env=env, read_timeout_s=180.0) as h:
            caps = h.initialize()
            assert "prompt.run" in caps["methods"]

            resp, notifs = h.call("prompt.run", {
                "prompt_name": "imputation_scrutiny",
                "slices": slices_map,
                "ruds": [],
                "output_dir": str(out_dir),
            }, progress_token="t1")

            assert "result" in resp, f"expected result, got: {resp}"
            result = resp["result"]
            assert Path(result["markdown_path"]).exists()
            md = Path(result["markdown_path"]).read_text()
            assert len(md) > 100, "model produced suspiciously short output"
            assert result["model"].startswith("gemini-") or result["model"].startswith("claude-")
            assert result["latency_s"] > 0
            assert any(
                n["method"] == "notifications/progress"
                for n in notifs
            )

            h.shutdown()
