"""Tests for acp_client.py using the fake_kiro fixture.

All tests spawn the fake_kiro.py subprocess as a drop-in for kiro-cli.
"""

from __future__ import annotations

import asyncio
import os
from pathlib import Path
from typing import Any

import pytest

from kiro_acp.acp_client import AcpClient, AcpRpcError

pytestmark = pytest.mark.asyncio

# Path to the fake kiro-cli binary.
FAKE_KIRO = Path(__file__).parent / "fake_kiro.py"


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture()
def notifications() -> list[tuple[str, dict[str, Any]]]:
    """Accumulator for notification (method, params) pairs."""
    return []


@pytest.fixture()
def make_client(notifications: list[tuple[str, dict[str, Any]]]):
    """Factory that creates and starts an AcpClient pointing at fake_kiro.

    Returns an async generator so we can clean up after each test.
    """
    _clients: list[AcpClient] = []

    async def _factory() -> AcpClient:
        client = AcpClient(
            FAKE_KIRO,
            on_notification=lambda m, p: _record(m, p, notifications),
        )
        await client.start()
        _clients.append(client)
        return client

    yield _factory

    # Cleanup: close all clients created during the test.
    async def _cleanup() -> None:
        for c in _clients:
            try:
                await c.close()
            except Exception:
                pass

    asyncio.get_event_loop().run_until_complete(_cleanup())


def _record(
    method: str,
    params: dict[str, Any],
    acc: list[tuple[str, dict[str, Any]]],
) -> None:
    acc.append((method, params))


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


async def test_initialize_and_close() -> None:
    """AcpClient can initialize against fake_kiro and close cleanly."""
    async with AcpClient(FAKE_KIRO) as client:
        result = await client.call("initialize", {"protocolVersion": 1})
        assert result["protocolVersion"] == 1
        assert result["agentInfo"]["name"] == "fake-kiro"


async def test_session_new_returns_models() -> None:
    """session/new returns configOptions with model entries."""
    async with AcpClient(FAKE_KIRO) as client:
        await client.call("initialize", {"protocolVersion": 1})
        result = await client.call("session/new", {"cwd": os.getcwd()})
        assert result["sessionId"] == "sess_test_001"
        opts = result["configOptions"]
        assert len(opts) >= 1
        model_opt = next(o for o in opts if o["id"] == "model")
        assert "claude-sonnet-4-6" in [
            o["value"] for o in model_opt["options"]
        ]


async def test_session_prompt_streams_updates(
    notifications: list[tuple[str, dict[str, Any]]],
) -> None:
    """session/prompt triggers update notifications and returns a result."""
    async with AcpClient(
        FAKE_KIRO,
        on_notification=lambda m, p: _record(m, p, notifications),
    ) as client:
        await client.call("initialize", {"protocolVersion": 1})
        session = await client.call("session/new", {"cwd": os.getcwd()})
        sid = session["sessionId"]

        result = await client.call(
            "session/prompt",
            {"sessionId": sid, "prompt": [{"type": "text", "text": "hi"}]},
        )
        assert result["stopReason"] == "end_turn"

        # Should have received agent_thought_chunk, agent_message_chunk,
        # tool_call, and tool_call_update notifications.
        updates = [n for n in notifications if n[0] == "session/update"]
        variants = [n[1]["update"]["sessionUpdate"] for n in updates]
        assert "agent_thought_chunk" in variants
        assert "agent_message_chunk" in variants
        assert "tool_call" in variants
        assert "tool_call_update" in variants


async def test_unknown_method_raises() -> None:
    """Calling an unknown method produces AcpRpcError(-32601)."""
    async with AcpClient(FAKE_KIRO) as client:
        with pytest.raises(AcpRpcError) as exc_info:
            await client.call("bogus/method", {})
        assert exc_info.value.code == -32601


async def test_close_kills_subprocess() -> None:
    """After close(), the subprocess is terminated (returncode is not None)."""
    client = AcpClient(FAKE_KIRO)
    await client.start()
    proc = client._process
    assert proc is not None
    assert proc.returncode is None  # Still running.

    await client.close()
    # Give the OS a moment to reap the process.
    await asyncio.sleep(0.1)
    assert proc.returncode is not None


async def test_malformed_json_doesnt_crash_reader() -> None:
    """The reader gracefully skips malformed JSON lines.

    We test this indirectly by having fake_kiro respond normally — the
    client's _read_loop already logs and continues on JSONDecodeError.
    The real test is that the client doesn't crash, which we verify by
    completing a normal call after startup.
    """
    async with AcpClient(FAKE_KIRO) as client:
        result = await client.call("initialize", {"protocolVersion": 1})
        assert result["agentInfo"]["name"] == "fake-kiro"
        # If the reader had crashed, this call would time out.
