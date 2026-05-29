"""Stdio JSON-RPC server for the prompt agent.

Reads newline-delimited JSON-RPC requests from stdin, dispatches them to
handlers, writes responses + notifications to stdout. All logs go to stderr.
"""

from __future__ import annotations

import json
import logging
import os
import sys
from pathlib import Path
from typing import Any

from agents.common import framing
from agents.prompt_agent import cache as cache_mod
from agents.prompt_agent import clients, prompts

log = logging.getLogger("prompt_agent")

AGENT_NAME = "prompt_agent"
AGENT_VERSION = "0.1.0"
PROTOCOL_VERSION = "lambe-haath/1"

DEFAULT_MODEL = "gemini-2.5-flash"


def get_model() -> str:
    return os.environ.get("LAMBE_MODEL", DEFAULT_MODEL)


def _resolve_model(spec) -> str:
    """Prefer the prompt's per-prompt model; fall back to the LAMBE_MODEL env var."""
    return spec.model or get_model()


def run_server() -> int:
    """Read from stdin, dispatch, write to stdout."""
    log.info("prompt_agent starting (model=%s)", get_model())

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
            continue

        if is_notification:
            log.debug("ignoring unknown notification: %s", method)
            continue

        if method == "prompt.run":
            _handle_prompt_run(msg_id, params)
            continue

        framing.write_line(framing.encode_error(
            msg_id, framing.METHOD_NOT_FOUND, f"unknown method: {method}",
        ))

    log.info("stdin EOF; exiting")
    return 0


def _initialize_result() -> dict[str, Any]:
    return {
        "protocolVersion": PROTOCOL_VERSION,
        "agentInfo": {"name": AGENT_NAME, "version": AGENT_VERSION},
        "capabilities": {
            "methods": ["prompt.run"],
            "progress": True,
            "cancellation": False,  # v1: model call is one shot, not cancellable mid-stream
            "prompts": prompts.capabilities_dict(),
        },
    }


def _handle_prompt_run(msg_id: int, params: dict) -> None:
    """Process a prompt.run request."""
    prompt_name = params.get("prompt_name")
    if not prompt_name or prompt_name not in prompts.PROMPTS:
        framing.write_line(framing.encode_error(
            msg_id, framing.INVALID_PARAMS,
            f"unknown or missing prompt_name: {prompt_name}",
        ))
        return

    slices_map = params.get("slices") or {}
    ruds_list = params.get("ruds") or []
    output_dir = params.get("output_dir")
    if not output_dir:
        framing.write_line(framing.encode_error(
            msg_id, framing.INVALID_PARAMS, "output_dir is required",
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
        result = _run_one_prompt(
            prompt_name=prompt_name,
            slices_map=slices_map,
            ruds_list=ruds_list,
            output_dir=Path(output_dir),
            on_progress=on_progress,
            on_log=on_log,
        )
    except FileNotFoundError as e:
        framing.write_line(framing.encode_error(
            msg_id, framing.INPUT_INVALID, str(e),
        ))
        return
    except clients.UnsupportedModelError as e:
        framing.write_line(framing.encode_error(
            msg_id, framing.AUTH_INVALID, str(e),
        ))
        return
    except Exception as exc:
        log.exception("prompt.run failed")
        framing.write_line(framing.encode_error(
            msg_id, framing.INTERNAL_ERROR, str(exc),
        ))
        return

    framing.write_line(framing.encode_response(msg_id, result))


def _run_one_prompt(
    prompt_name: str,
    slices_map: dict[str, dict],
    ruds_list: list[dict],
    output_dir: Path,
    on_progress,
    on_log,
) -> dict:
    """Read inputs from disk, call model, save markdown, return result dict."""
    spec = prompts.PROMPTS[prompt_name]
    system_prompt = prompts.load_system_prompt(prompt_name)
    model = _resolve_model(spec)

    on_progress(0.05, "reading slice markdowns")

    cache_name = cache_mod.get_or_create_cache(
        model=model,
        slices_map=slices_map,
        ruds_list=ruds_list,
        on_log=on_log,
    )

    if cache_name:
        # Cache hit or freshly created — user message becomes a minimal pointer;
        # the full chargesheet content is already in the Gemini cache resource.
        user_prompt = "Now perform the analysis described in the system instructions, using the cached chargesheet content above."
    else:
        # Cache unavailable (non-Gemini model, content too small, SDK error, etc.)
        # — fall back to existing inline assembly.
        user_prompt = _assemble_user_prompt(spec, slices_map, ruds_list, on_log)

    on_progress(0.20, f"calling {model}")
    completion = clients.run_completion(
        model=model,
        system_prompt=system_prompt,
        user_prompt=user_prompt,
        on_log=on_log,
        cached_content=cache_name,
    )

    on_progress(0.90, "writing output markdown")
    output_dir.mkdir(parents=True, exist_ok=True)
    markdown_path = output_dir / f"{prompt_name}.md"
    markdown_path.write_text(completion.markdown, encoding="utf-8")

    warnings: list[str] = []
    if not completion.markdown.strip():
        warnings.append("empty_output")
    if "#" not in completion.markdown and "##" not in completion.markdown:
        warnings.append("no_markdown_headings")
    if completion.finish_reason not in ("STOP", "FinishReason.STOP", "end_turn"):
        warnings.append(f"finish_reason:{completion.finish_reason}")

    on_progress(1.0, "done")

    return {
        "markdown_path": str(markdown_path),
        "model": model,
        "input_tokens": completion.input_tokens,
        "output_tokens": completion.output_tokens,
        "latency_s": completion.latency_s,
        "warnings": warnings,
    }


def _assemble_user_prompt(
    spec,
    slices_map: dict[str, dict],
    ruds_list: list[dict],
    on_log,
) -> str:
    """Read the required slice markdowns + RUDs and concatenate into one user message."""
    parts: list[str] = []

    for req in spec.requires:
        if req == "ruds:*":
            if not ruds_list:
                on_log("warning", "prompt requires ruds:* but none provided")
                continue
            parts.append("\n\n# Relied Upon Documents (RUDs)\n")
            for rud in ruds_list:
                rud_id = rud.get("id", "RUD-??")
                md_path = rud.get("markdown_path")
                if not md_path:
                    continue
                p = Path(md_path)
                if not p.exists():
                    raise FileNotFoundError(f"RUD markdown missing: {md_path}")
                parts.append(f"\n\n## {rud_id}\n\n{p.read_text(encoding='utf-8')}")
        else:
            slice_info = slices_map.get(req)
            if not slice_info:
                raise FileNotFoundError(f"required slice missing: {req}")
            md_path = slice_info.get("markdown_path")
            if not md_path:
                raise FileNotFoundError(f"slice {req} has no markdown_path")
            p = Path(md_path)
            if not p.exists():
                raise FileNotFoundError(f"slice markdown missing: {md_path}")
            label = req.replace("-", " ").upper()
            parts.append(f"\n\n# {label}\n\n{p.read_text(encoding='utf-8')}")

    return "\n".join(parts).lstrip()


def handle_once(prompt_name: str, params: dict) -> dict:
    """Synchronous run for `--once` debug mode."""
    slices_map = params.get("slices") or {}
    ruds_list = params.get("ruds") or []
    output_dir = Path(params.get("output_dir", "/tmp/prompt_out"))

    return _run_one_prompt(
        prompt_name=prompt_name,
        slices_map=slices_map,
        ruds_list=ruds_list,
        output_dir=output_dir,
        on_progress=lambda p, m: None,
        on_log=lambda l, m: None,
    )
