"""Stdio JSON-RPC server for the OCR agent.

Reads newline-delimited JSON-RPC requests from stdin, dispatches them to
handlers, writes responses + notifications to stdout. All logs go to stderr.
"""

from __future__ import annotations

import json
import logging
import sys
from pathlib import Path
from typing import Any

from agents.ocr_agent import framing
from agents.ocr_agent.extract import extract_and_save, get_model

log = logging.getLogger("ocr_agent")

AGENT_NAME = "ocr_agent"
AGENT_VERSION = "0.1.0"
PROTOCOL_VERSION = "lambe-haath/1"


def run_server() -> int:
    """Read from stdin, dispatch, write to stdout. Returns process exit code."""
    log.info("ocr_agent starting (model=%s)", get_model())

    for raw_line in sys.stdin:
        line = raw_line.rstrip("\n").rstrip("\r")
        if not line:
            continue

        try:
            msg = json.loads(line)
        except json.JSONDecodeError as e:
            log.warning("dropping malformed line: %s", e)
            continue

        method = msg.get("method")
        msg_id = msg.get("id")
        params = msg.get("params") or {}
        is_notification = "id" not in msg

        if method == "initialize":
            framing.write_line(framing.encode_response(msg_id, _initialize_result()))
            continue

        if method == "notifications/initialized":
            log.info("host: initialized")
            continue

        if method == "notifications/exit":
            log.info("host: exit notification received; shutting down")
            return 0

        if method == "shutdown":
            framing.write_line(framing.encode_response(msg_id, None))
            # Don't exit yet — wait for notifications/exit (per LSP convention).
            continue

        if is_notification:
            # Unknown notifications are ignored per JSON-RPC 2.0.
            log.debug("ignoring unknown notification: %s", method)
            continue

        if method == "ocr.extract":
            _handle_ocr_extract(msg_id, params)
            continue

        # Unknown method.
        framing.write_line(framing.encode_error(
            msg_id, framing.METHOD_NOT_FOUND, f"unknown method: {method}",
        ))

    # stdin closed (EOF) — exit cleanly.
    log.info("stdin EOF; exiting")
    return 0


def _initialize_result() -> dict[str, Any]:
    return {
        "protocolVersion": PROTOCOL_VERSION,
        "agentInfo": {"name": AGENT_NAME, "version": AGENT_VERSION},
        "capabilities": {
            "methods": ["ocr.extract"],
            "progress": True,
            "cancellation": False,  # v1: cancellation not implemented inside extract_and_save
        },
    }


def _handle_ocr_extract(msg_id: int, params: dict) -> None:
    """Process an ocr.extract request.

    Params shape (from logos's dispatcher):
        {
          "slice_path": "/path/to/slice.pdf",
          "output_dir": "/path/to/output_dir",
          "start_page": 70,                  # optional; absolute page number of
                                             # the slice's first page within the
                                             # original chargesheet. Defaults to 1.
          "_meta": {"progressToken": "j17"}  # optional
        }
    """
    slice_path = params.get("slice_path")
    output_dir = params.get("output_dir")
    if not slice_path or not output_dir:
        framing.write_line(framing.encode_error(
            msg_id, framing.INVALID_PARAMS,
            "slice_path and output_dir are required",
        ))
        return

    start_page_raw = params.get("start_page", 1)
    try:
        start_page = int(start_page_raw)
        if start_page < 1:
            start_page = 1
    except (TypeError, ValueError):
        start_page = 1

    pdf = Path(slice_path)
    out = Path(output_dir)

    if not pdf.exists():
        framing.write_line(framing.encode_error(
            msg_id, framing.INPUT_INVALID,
            f"slice not found: {slice_path}",
        ))
        return

    progress_token = (params.get("_meta") or {}).get("progressToken")

    def on_progress(progress: float, message: str) -> None:
        if progress_token is None:
            return
        framing.write_line(framing.encode_notification(
            "notifications/progress",
            {"progressToken": progress_token, "progress": progress, "message": message},
        ))

    def on_log(level: str, message: str) -> None:
        framing.write_line(framing.encode_notification(
            "notifications/log",
            {"level": level, "logger": AGENT_NAME, "message": message},
        ))

    try:
        result = extract_and_save(pdf, out, on_progress=on_progress, on_log=on_log, start_page=start_page)
    except Exception as exc:
        log.exception("ocr.extract failed")
        framing.write_line(framing.encode_error(
            msg_id, framing.INTERNAL_ERROR, str(exc),
        ))
        return

    # Build the response payload that logos's dispatcher will parse and write
    # into the extractions table.
    payload = {
        "markdown_path": str(result["markdown_path"]),
        "meta_path": str(result["meta_path"]),
        "model": get_model(),
        "pages": result["metadata"]["source_pages"],
        "page_markers_found": result["metadata"]["page_markers_found"],
        "input_tokens": result["metadata"].get("total_input_tokens"),
        "output_tokens": result["metadata"].get("total_output_tokens"),
        "latency_s": result["metadata"]["total_latency_s"],
    }
    framing.write_line(framing.encode_response(msg_id, payload))
