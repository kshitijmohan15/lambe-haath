"""Newline-delimited JSON-RPC 2.0 codec for the lambe-haath/1 protocol.

Mirrors the host-side codec in logos/src/agents/jsonrpc.zig. Pure functions,
no I/O — server.py owns stdin/stdout.
"""

from __future__ import annotations

import json
import sys
from typing import Any


def encode_response(id_: int, result: Any) -> str:
    """Serialize a successful response. Returns a single newline-terminated line."""
    return json.dumps(
        {"jsonrpc": "2.0", "id": id_, "result": result},
        separators=(",", ":"),
    ) + "\n"


def encode_error(id_: int, code: int, message: str, data: dict | None = None) -> str:
    err: dict[str, Any] = {"code": code, "message": message}
    if data is not None:
        err["data"] = data
    return json.dumps(
        {"jsonrpc": "2.0", "id": id_, "error": err},
        separators=(",", ":"),
    ) + "\n"


def encode_notification(method: str, params: dict | None = None) -> str:
    msg: dict[str, Any] = {"jsonrpc": "2.0", "method": method}
    if params is not None:
        msg["params"] = params
    return json.dumps(msg, separators=(",", ":")) + "\n"


# Standard JSON-RPC error codes
PARSE_ERROR = -32700
INVALID_REQUEST = -32600
METHOD_NOT_FOUND = -32601
INVALID_PARAMS = -32602
INTERNAL_ERROR = -32603

# lambe-haath domain-specific codes (matches logos/src/agents/jsonrpc.zig)
CANCELED = -32099
UPSTREAM_API_ERROR = -32001
UPSTREAM_RATE_LIMITED = -32002
INPUT_INVALID = -32003
OUTPUT_TRUNCATED = -32004
AUTH_INVALID = -32005


def write_line(line: str) -> None:
    """Write a single framed line to stdout and flush. Always use this — never raw print."""
    sys.stdout.write(line)
    sys.stdout.flush()
