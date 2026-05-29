"""Re-export framing from agents.common.framing for backwards compatibility.

The framing module was moved to agents.common in Plan D so that the prompt
agent (and any future agents) can share it. Existing imports of
`agents.ocr_agent.framing` keep working through this shim.
"""

from agents.common.framing import *  # noqa: F401, F403
from agents.common.framing import (  # explicit re-exports for type checkers
    encode_response,
    encode_error,
    encode_notification,
    write_line,
    PARSE_ERROR,
    INVALID_REQUEST,
    METHOD_NOT_FOUND,
    INVALID_PARAMS,
    INTERNAL_ERROR,
    CANCELED,
    UPSTREAM_API_ERROR,
    UPSTREAM_RATE_LIMITED,
    INPUT_INVALID,
    OUTPUT_TRUNCATED,
    AUTH_INVALID,
)
