#!/usr/bin/env python3
"""
Mock agent for the lambe-haath/1 JSON-RPC protocol.

Reads newline-delimited JSON-RPC requests from stdin, writes responses + notifications
to stdout. Behavior is controlled by environment variables so tests can simulate every
edge of the agent state machine.

Env vars:
    MOCK_CAPABILITIES    JSON string returned in initialize response's `capabilities`.
                         Default: {"methods": ["mock.echo"], "progress": true, "cancellation": true}
    MOCK_LATENCY_S       float; sleep this many seconds before responding to each method call.
    MOCK_PROGRESS_TICKS  int; emit N notifications/progress events between request and response.
    MOCK_FAIL_AFTER_N    int; after handling N method calls, call os._exit(1) to simulate crash.
                         Special: MOCK_FAIL_AFTER_N=0 means crash on the *first* call.
    MOCK_HANG_AFTER_N    int; after handling N method calls, stop reading stdin (simulates wedge).
    MOCK_PARSE_GARBAGE_AFTER_N  int; after handling N calls, emit a non-JSON line on stdout
                                 (tests host codec robustness).

This script has *no third-party deps* — stdlib only. That keeps it portable and
makes it useful as a polyglot test fixture for future Go/Rust/Zig agents.
"""

from __future__ import annotations

import json
import os
import sys
import time


def emit(obj: dict) -> None:
    """Write a single JSON-RPC message as one newline-terminated line to stdout."""
    sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def emit_garbage() -> None:
    sys.stdout.write("this is not json at all\n")
    sys.stdout.flush()


def get_int_env(name: str) -> int | None:
    v = os.environ.get(name)
    if v is None:
        return None
    try:
        return int(v)
    except ValueError:
        return None


def main() -> None:
    method_calls_handled = 0
    fail_after = get_int_env("MOCK_FAIL_AFTER_N")
    hang_after = get_int_env("MOCK_HANG_AFTER_N")
    garbage_after = get_int_env("MOCK_PARSE_GARBAGE_AFTER_N")
    latency_s = float(os.environ.get("MOCK_LATENCY_S", "0") or "0")
    progress_ticks = int(os.environ.get("MOCK_PROGRESS_TICKS", "0") or "0")
    capabilities = json.loads(
        os.environ.get(
            "MOCK_CAPABILITIES",
            '{"methods":["mock.echo"],"progress":true,"cancellation":true}',
        )
    )

    initialized = False

    for raw_line in sys.stdin:
        line = raw_line.rstrip("\n").rstrip("\r")
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            # Malformed input from host. Per protocol, we ignore (host bug).
            continue

        method = msg.get("method")
        msg_id = msg.get("id")
        is_notification = "id" not in msg

        if is_notification:
            # Host -> agent notifications. We handle 'notifications/initialized'
            # and 'notifications/cancelled'. Otherwise ignore.
            if method == "notifications/initialized":
                initialized = True
            # Cancellation is a no-op for the mock; tests assert observable effects elsewhere.
            continue

        if method == "initialize":
            emit({
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": {
                    "protocolVersion": "lambe-haath/1",
                    "agentInfo": {"name": "mock_agent", "version": "0.1.0"},
                    "capabilities": capabilities,
                },
            })
            continue

        if method == "shutdown":
            emit({"jsonrpc": "2.0", "id": msg_id, "result": None})
            # Host will send notifications/exit next; we exit then.
            continue

        # Any other method call: run our mock behavior
        method_calls_handled += 1

        if fail_after is not None and method_calls_handled > fail_after:
            # Simulate crash. Note: fail_after=0 means "crash on first method call".
            os._exit(1)

        if hang_after is not None and method_calls_handled > hang_after:
            # Stop reading stdin to simulate a wedged process.
            while True:
                time.sleep(60)

        if garbage_after is not None and method_calls_handled > garbage_after:
            emit_garbage()
            continue

        # Emit progress ticks if requested.
        params = msg.get("params", {}) or {}
        progress_token = (params.get("_meta") or {}).get("progressToken")
        if progress_token and progress_ticks > 0:
            for i in range(progress_ticks):
                emit({
                    "jsonrpc": "2.0",
                    "method": "notifications/progress",
                    "params": {
                        "progressToken": progress_token,
                        "progress": (i + 1) / progress_ticks,
                        "message": f"mock tick {i+1}/{progress_ticks}",
                    },
                })

        if latency_s > 0:
            time.sleep(latency_s)

        # Echo the params back as the result. This is the mock's "work product".
        emit({
            "jsonrpc": "2.0",
            "id": msg_id,
            "result": {"echo": params, "call_index": method_calls_handled},
        })


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
