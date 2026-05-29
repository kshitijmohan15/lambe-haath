"""
Conformance harness for the lambe-haath/1 protocol.

Drives any agent binary through:
    1. initialize  -> initialize-result
    2. notifications/initialized
    3. one or more method calls -> responses (and notifications)
    4. shutdown -> shutdown-result
    5. notifications/exit
    6. agent exits cleanly

Used by:
    - tests/test_conformance.py  (validates mock_agent.py)
    - future plans: test the real ocr_agent and prompt_agent the same way

This module has no third-party deps. Implementers in any language can read it
to understand what a passing agent looks like in practice.
"""

from __future__ import annotations

import json
import subprocess
import threading
from queue import Queue, Empty
from typing import Any


class ProtocolError(RuntimeError):
    """Raised when an agent violates the lambe-haath/1 protocol."""


class Harness:
    """Driver around a single subprocess that speaks lambe-haath/1 over stdio.

    Usage:
        with Harness(["python3", "tests/mock_agent.py"]) as h:
            caps = h.initialize()
            result, notifs = h.call("mock.echo", {"hello": 1})
            h.shutdown()
    """

    def __init__(
        self,
        argv: list[str],
        env: dict[str, str] | None = None,
        read_timeout_s: float = 10.0,
    ):
        self._argv = argv
        self._env = env
        self._read_timeout_s = read_timeout_s
        self._proc: subprocess.Popen | None = None
        self._stdout_lines: Queue[str] = Queue()
        self._reader_thread: threading.Thread | None = None
        self._next_id = 1
        # Notifications queued up between calls; drained by .call().
        self._buffered_notifs: list[dict] = []

    # -- context manager --

    def __enter__(self) -> "Harness":
        self._proc = subprocess.Popen(
            self._argv,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,  # line-buffered
            env=self._env,
        )
        self._reader_thread = threading.Thread(target=self._read_stdout, daemon=True)
        self._reader_thread.start()
        return self

    def __exit__(self, *exc) -> None:
        if self._proc is None:
            return
        try:
            if self._proc.poll() is None:
                self._proc.kill()
        finally:
            self._proc.wait(timeout=5)

    # -- protocol --

    def initialize(self) -> dict:
        """Send initialize, return the capabilities dict from the response."""
        resp = self._request("initialize", {
            "protocolVersion": "lambe-haath/1",
            "hostInfo": {"name": "conformance_harness", "version": "0.1.0"},
            "capabilities": {"progress": True, "cancellation": True},
        })
        if "result" not in resp:
            raise ProtocolError(f"initialize did not return result: {resp}")
        result = resp["result"]
        if result.get("protocolVersion") != "lambe-haath/1":
            raise ProtocolError(f"agent protocolVersion mismatch: {result.get('protocolVersion')}")
        if "capabilities" not in result:
            raise ProtocolError("initialize result missing capabilities")
        # Send the initialized notification.
        self._send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        return result["capabilities"]

    def call(
        self,
        method: str,
        params: dict | None = None,
        progress_token: str | None = None,
    ) -> tuple[dict, list[dict]]:
        """Send a method call. Returns (response_message, [notifications received during the call])."""
        if params is None:
            params = {}
        if progress_token is not None:
            params = {**params, "_meta": {"progressToken": progress_token}}
        resp = self._request(method, params)
        notifs = self._buffered_notifs
        self._buffered_notifs = []
        return resp, notifs

    def notify(self, method: str, params: dict | None = None) -> None:
        """Send a notification to the agent (e.g., notifications/cancelled)."""
        msg = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            msg["params"] = params
        self._send(msg)

    def shutdown(self) -> None:
        """Send shutdown + exit notification + wait for the process to exit."""
        try:
            self._request("shutdown", {})
        except ProtocolError:
            pass  # agent may not implement shutdown; that's OK
        self._send({"jsonrpc": "2.0", "method": "notifications/exit"})
        # Close stdin so the agent's read loop hits EOF.
        try:
            self._proc.stdin.close()
        except Exception:
            pass

    # -- internals --

    def _next_request_id(self) -> int:
        rid = self._next_id
        self._next_id += 1
        return rid

    def _send(self, obj: dict) -> None:
        line = json.dumps(obj, separators=(",", ":")) + "\n"
        assert self._proc is not None and self._proc.stdin is not None
        self._proc.stdin.write(line)
        self._proc.stdin.flush()

    def _request(self, method: str, params: dict) -> dict:
        rid = self._next_request_id()
        self._send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        # Read until we get a response with this id; buffer any notifications.
        while True:
            msg = self._read_one()
            if "id" in msg and msg["id"] == rid:
                return msg
            elif "method" in msg and "id" not in msg:
                self._buffered_notifs.append(msg)
            else:
                # Unexpected; could be a stale response. Continue scanning.
                continue

    def _read_one(self) -> dict:
        try:
            line = self._stdout_lines.get(timeout=self._read_timeout_s)
        except Empty:
            raise ProtocolError(f"agent timed out (>{self._read_timeout_s}s) waiting for response")
        try:
            return json.loads(line)
        except json.JSONDecodeError as e:
            raise ProtocolError(f"agent emitted non-JSON line: {line!r} ({e})")

    def _read_stdout(self) -> None:
        assert self._proc is not None and self._proc.stdout is not None
        for raw in self._proc.stdout:
            line = raw.rstrip("\n")
            if not line:
                continue
            self._stdout_lines.put(line)
