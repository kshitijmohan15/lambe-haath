"""Live OCR test — opt-in via LAMBE_LIVE_TESTS=1.

This test makes a real Gemini API call and costs roughly ₹2-3 per run.
Run only when validating the real OCR pipeline end-to-end.
"""

from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

import pytest

from tests.conformance_harness import Harness


LIVE = os.environ.get("LAMBE_LIVE_TESTS") == "1"
SAMPLE_PDF = Path(__file__).parent / "fixtures" / "sample-5p.pdf"
OCR_AGENT_CMD = [sys.executable, "-m", "agents.ocr_agent"]


@pytest.mark.live
@pytest.mark.skipif(not LIVE, reason="set LAMBE_LIVE_TESTS=1 to run live tests")
@pytest.mark.skipif(not SAMPLE_PDF.exists(), reason="missing sample-5p.pdf fixture")
def test_ocr_extract_against_real_gemini() -> None:
    with tempfile.TemporaryDirectory() as tmpd:
        out_dir = Path(tmpd) / "out"
        out_dir.mkdir()

        # 5 minutes is generous; the 5-page sample should finish in ~30 seconds.
        with Harness(OCR_AGENT_CMD, read_timeout_s=300.0) as h:
            caps = h.initialize()
            assert "ocr.extract" in caps["methods"]

            resp, notifs = h.call(
                "ocr.extract",
                {
                    "slice_path": str(SAMPLE_PDF),
                    "output_dir": str(out_dir),
                },
                progress_token="t1",
            )

            assert "result" in resp, f"expected result, got: {resp}"
            result = resp["result"]

            # Verify result shape (what logos's dispatcher will parse).
            assert Path(result["markdown_path"]).exists()
            assert Path(result["meta_path"]).exists()
            assert result["pages"] == 5
            assert result["model"].startswith("gemini-")
            assert result["latency_s"] > 0
            # We should have received at least one progress notification.
            assert any(
                n["method"] == "notifications/progress"
                for n in notifs
            ), "expected at least one notifications/progress event"

            h.shutdown()
