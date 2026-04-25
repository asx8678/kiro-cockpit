"""Tests for callbacks_handler.py — filesystem and terminal operations.

No subprocess needed; exercises the handler functions directly.
"""

from __future__ import annotations

import asyncio
import os
from pathlib import Path
from typing import Any

import pytest

from kiro_acp.acp_client import AcpRpcError
from kiro_acp.callbacks_handler import (
    _handle_fs_read_text_file,
    _handle_fs_write_text_file,
    _handle_terminal_create,
    _handle_terminal_kill,
    _handle_terminal_output,
    _handle_terminal_release,
    _handle_terminal_wait_for_exit,
)

pytestmark = pytest.mark.asyncio


# ---------------------------------------------------------------------------
# Filesystem tests
# ---------------------------------------------------------------------------


async def test_fs_read_relative_path_rejected() -> None:
    """Relative paths must be rejected with -32602."""
    with pytest.raises(AcpRpcError) as exc_info:
        await _handle_fs_read_text_file({"path": "relative/path.txt"})
    assert exc_info.value.code == -32602
    assert "absolute" in exc_info.value.message.lower()


async def test_fs_read_returns_content(tmp_path: Path) -> None:
    """Read a temp file and verify content matches."""
    target = tmp_path / "hello.txt"
    target.write_text("Hello, world!\nLine two.\n", encoding="utf-8")

    result = await _handle_fs_read_text_file({"path": str(target)})
    assert result["content"] == "Hello, world!\nLine two.\n"


async def test_fs_read_with_line_limit(tmp_path: Path) -> None:
    """Line/limit slicing works correctly (1-based indexing)."""
    target = tmp_path / "lines.txt"
    target.write_text("one\ntwo\nthree\nfour\nfive\n", encoding="utf-8")

    # Read lines 2-3 (limit=2 starting from line 2).
    result = await _handle_fs_read_text_file(
        {"path": str(target), "line": 2, "limit": 2}
    )
    assert result["content"] == "two\nthree\n"


async def test_fs_read_missing_file_raises(tmp_path: Path) -> None:
    """Reading a non-existent file raises -32000."""
    with pytest.raises(AcpRpcError) as exc_info:
        await _handle_fs_read_text_file(
            {"path": str(tmp_path / "does_not_exist.txt")}
        )
    assert exc_info.value.code == -32000


async def test_fs_write_creates_parent_dirs(tmp_path: Path) -> None:
    """Writing to a nested path creates parent directories."""
    target = tmp_path / "a" / "b" / "c" / "output.txt"
    await _handle_fs_write_text_file(
        {"path": str(target), "content": "nested write"}
    )
    assert target.read_text(encoding="utf-8") == "nested write"
    assert target.parent.is_dir()


async def test_fs_write_overwrites_existing(tmp_path: Path) -> None:
    """Writing over an existing file replaces content."""
    target = tmp_path / "overwrite.txt"
    target.write_text("old", encoding="utf-8")

    await _handle_fs_write_text_file(
        {"path": str(target), "content": "new"}
    )
    assert target.read_text(encoding="utf-8") == "new"


async def test_fs_write_missing_params_raises() -> None:
    """Missing path or content raises -32602."""
    with pytest.raises(AcpRpcError) as exc_info:
        await _handle_fs_write_text_file({"content": "x"})
    assert exc_info.value.code == -32602

    with pytest.raises(AcpRpcError) as exc_info:
        await _handle_fs_write_text_file({"path": "/tmp/x"})
    assert exc_info.value.code == -32602


# ---------------------------------------------------------------------------
# Terminal tests
# ---------------------------------------------------------------------------


async def test_terminal_create_then_release() -> None:
    """Create a terminal running echo, drain output, release."""
    result = await _handle_terminal_create(
        {"command": "/bin/echo", "args": ["hello terminal"]}
    )
    term_id = result["terminalId"]
    assert term_id.startswith("term_")

    # Wait for the process to exit.
    exit_result = await _handle_terminal_wait_for_exit({"terminalId": term_id})
    assert exit_result["exitCode"] == 0

    # Read output.
    out = await _handle_terminal_output({"terminalId": term_id})
    assert "hello terminal" in out["output"]
    assert out["exitStatus"]["exitCode"] == 0

    # Release cleans up.
    await _handle_terminal_release({"terminalId": term_id})


async def test_terminal_kill_then_release() -> None:
    """Create a long-running terminal, kill it, then release."""
    result = await _handle_terminal_create(
        {"command": "/bin/sleep", "args": ["300"]}
    )
    term_id = result["terminalId"]

    # Kill the process.
    await _handle_terminal_kill({"terminalId": term_id})

    # Wait briefly for kill to take effect.
    await asyncio.sleep(0.1)

    # Verify it's dead.
    exit_result = await _handle_terminal_wait_for_exit({"terminalId": term_id})
    # Killed processes return negative signal on POSIX or specific exit code.
    assert exit_result["exitCode"] != 0 or exit_result["signal"] is not None

    # Release cleans up.
    await _handle_terminal_release({"terminalId": term_id})


async def test_terminal_unknown_id_raises() -> None:
    """Requesting an unknown terminal id raises -32000."""
    with pytest.raises(AcpRpcError) as exc_info:
        await _handle_terminal_output({"terminalId": "term_nonexistent"})
    assert exc_info.value.code == -32000


async def test_terminal_missing_id_raises() -> None:
    """Missing terminalId raises -32602."""
    with pytest.raises(AcpRpcError) as exc_info:
        await _handle_terminal_output({})
    assert exc_info.value.code == -32602


async def test_terminal_bad_command_raises() -> None:
    """A non-existent command raises -32000."""
    with pytest.raises(AcpRpcError) as exc_info:
        await _handle_terminal_create(
            {"command": "/nonexistent/binary/that/does/not/exist"}
        )
    assert exc_info.value.code == -32000
