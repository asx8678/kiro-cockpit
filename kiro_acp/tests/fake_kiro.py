#!/usr/bin/env python3
"""Fake kiro-cli ACP server for testing.

Reads JSON-RPC 2.0 messages from stdin (newline-delimited) and emits
scripted responses to stdout.  Used by test_acp_client.py as a drop-in
replacement for the real ``kiro-cli acp`` binary.

Protocol behaviours:
  - ``initialize``         → canned init response
  - ``session/new``        → session id + configOptions with two models
  - ``session/set_config_option`` → echo back updated configOptions
  - ``session/set_mode``   → echo back updated mode
  - ``session/prompt``     → two update notifications, then result
  - ``session/cancel``     → no response (notification, no id)
  - anything else          → -32601 Method not found
"""

from __future__ import annotations

import json
import sys
from typing import Any

# ---------------------------------------------------------------------------
# Canned data
# ---------------------------------------------------------------------------

_INIT_RESULT: dict[str, Any] = {
    "protocolVersion": 1,
    "agentInfo": {
        "name": "fake-kiro",
        "title": "Fake Kiro Agent",
        "version": "0.0.1-test",
    },
    "agentCapabilities": {
        "fs": {"readTextFile": True, "writeTextFile": True},
        "terminal": True,
    },
}

_SESSION_RESULT: dict[str, Any] = {
    "sessionId": "sess_test_001",
    "modes": {
        "currentModeId": "code",
        "availableModes": [
            {"id": "code", "name": "Code"},
            {"id": "ask", "name": "Ask"},
        ],
    },
    "configOptions": [
        {
            "id": "model",
            "currentValue": "claude-sonnet-4-6",
            "options": [
                {"value": "claude-sonnet-4-6", "label": "Claude Sonnet 4.6"},
                {"value": "claude-opus-4-7", "label": "Claude Opus 4.7"},
            ],
        },
    ],
}


def _write(obj: dict[str, Any]) -> None:
    """Write a single JSON-RPC message to stdout (newline-delimited)."""
    line = json.dumps(obj, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def _make_response(rid: int, result: Any) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": rid, "result": result}


def _make_error(rid: int, code: int, message: str) -> dict[str, Any]:
    return {
        "jsonrpc": "2.0",
        "id": rid,
        "error": {"code": code, "message": message},
    }


def _handle_request(rid: int, method: str, params: dict[str, Any]) -> None:
    """Dispatch a request and write the response."""
    if method == "initialize":
        _write(_make_response(rid, _INIT_RESULT))

    elif method == "session/new":
        _write(_make_response(rid, _SESSION_RESULT))

    elif method == "session/set_config_option":
        # Echo back a configOptions block reflecting the new value.
        cfg_id = params.get("configId", "")
        value = params.get("value", "")
        updated = {
            "configOptions": [
                {
                    "id": cfg_id,
                    "currentValue": value,
                    "options": _SESSION_RESULT["configOptions"][0]["options"],
                }
            ]
        }
        _write(_make_response(rid, updated))

    elif method == "session/set_mode":
        mode_id = params.get("modeId", "")
        _write(
            _make_response(
                rid,
                {
                    "modes": {
                        "currentModeId": mode_id,
                        "availableModes": _SESSION_RESULT["modes"][
                            "availableModes"
                        ],
                    }
                },
            )
        )

    elif method == "session/prompt":
        session_id = params.get("sessionId", "sess_test_001")

        # Emit two session/update notifications before the final response.
        _write(
            {
                "jsonrpc": "2.0",
                "method": "session/update",
                "params": {
                    "sessionId": session_id,
                    "update": {
                        "sessionUpdate": "agent_thought_chunk",
                        "content": {"text": "thinking..."},
                    },
                },
            }
        )
        _write(
            {
                "jsonrpc": "2.0",
                "method": "session/update",
                "params": {
                    "sessionId": session_id,
                    "update": {
                        "sessionUpdate": "agent_message_chunk",
                        "content": {"text": "Hello from fake kiro"},
                    },
                },
            }
        )
        # Also emit a tool_call + tool_call_update for completeness.
        _write(
            {
                "jsonrpc": "2.0",
                "method": "session/update",
                "params": {
                    "sessionId": session_id,
                    "update": {
                        "sessionUpdate": "tool_call",
                        "toolCallId": "tc_001",
                        "title": "read file",
                        "kind": "fs/read_text_file",
                    },
                },
            }
        )
        _write(
            {
                "jsonrpc": "2.0",
                "method": "session/update",
                "params": {
                    "sessionId": session_id,
                    "update": {
                        "sessionUpdate": "tool_call_update",
                        "toolCallId": "tc_001",
                        "status": "completed",
                    },
                },
            }
        )

        # Final response.
        _write(_make_response(rid, {"stopReason": "end_turn"}))

    else:
        _write(_make_error(rid, -32601, f"Method not found: {method}"))


def _handle_notification(method: str, params: dict[str, Any]) -> None:
    """Handle notifications (no response expected)."""
    # session/cancel is the only notification we care about — just ignore it.
    pass


def main() -> None:
    """Read JSON-RPC lines from stdin and dispatch."""
    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue

        try:
            msg: dict[str, Any] = json.loads(line)
        except json.JSONDecodeError:
            # Malformed JSON — silently skip (the real server would too).
            continue

        rid = msg.get("id")
        method = msg.get("method")
        params: dict[str, Any] = msg.get("params", {})

        if method is None:
            # Not a valid JSON-RPC request/notification — skip.
            continue

        if rid is not None:
            _handle_request(rid, method, params)
        else:
            _handle_notification(method, params)


if __name__ == "__main__":
    main()
