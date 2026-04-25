"""Agent→client callback handlers for the kiro ACP protocol.

This module implements all ``fs/*`` and ``terminal/*`` methods that
``kiro-cli acp`` may call back into us.  Exposes a single dispatcher
``handle_agent_request`` which the ``AcpClient`` invokes for every
inbound request from the agent subprocess.

Strategy A: kiro's tool calls run *inside* the sealed wrapper.  When
kiro asks ``fs/read_text_file`` we read the file ourselves and reply —
we never surface those as ``ToolCallPart``s to code-puppy.
"""

from __future__ import annotations

import asyncio
import logging
import os
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional

from .acp_client import AcpRpcError
from .config import autoapprove_fs_read, autoapprove_fs_write, autoapprove_terminal

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Terminal dataclass
# ---------------------------------------------------------------------------


@dataclass
class _RunningTerminal:
    """State for a spawned terminal process."""

    proc: asyncio.subprocess.Process
    stdout_buffer: bytearray = field(default_factory=bytearray)
    output_byte_limit: int = 1_048_576  # 1 MiB default
    truncated: bool = False
    released: bool = False
    read_task: Optional[asyncio.Task[None]] = None


# Module-level terminal registry.
_terminals: dict[str, _RunningTerminal] = {}


# ---------------------------------------------------------------------------
# Permission / safety gating helpers
# ---------------------------------------------------------------------------


async def _check_file_permission(path: str, operation: str) -> bool:
    """Ask code-puppy's file_permission callback chain whether to allow.

    Uses the public ``on_file_permission`` API.  Passes ``None`` for the
    ``context`` parameter since kiro operations don't have a pydantic-ai
    ``RunContext``.

    Returns:
        ``True`` if allowed (or no handler), ``False`` if denied.
    """
    try:
        from code_puppy.callbacks import on_file_permission

        results = on_file_permission(
            None,       # context (no RunContext for kiro)
            path,
            operation,
            None,       # preview (deprecated)
            None,       # message_group
            None,       # operation_data
        )
        # If any handler returned False, deny.
        for r in results:
            if r is False:
                return False
        return True
    except Exception as exc:
        logger.warning("file_permission callback chain failed: %s", exc)
        return True  # Fail open — user already opted into the plugin.


async def _check_shell_command(command: str, args: list[str]) -> bool:
    """Run pre_tool_call gating on a proposed terminal command.

    Uses the public ``on_pre_tool_call`` API.  Returns ``True`` if allowed,
    ``False`` if any handler blocks the call.
    """
    full_cmd = " ".join([command, *args])
    try:
        from code_puppy.callbacks import on_pre_tool_call

        results = await on_pre_tool_call(
            tool_name="run_shell_command",
            tool_args={"command": full_cmd},
            context=None,
        )
        # If any handler returned a dict with "blocked": True, deny.
        for r in results:
            if isinstance(r, dict) and r.get("blocked"):
                return False
        return True
    except Exception as exc:
        logger.warning("pre_tool_call callback chain failed: %s", exc)
        return True  # Fail open.


# ---------------------------------------------------------------------------
# Public dispatcher
# ---------------------------------------------------------------------------


async def handle_agent_request(
    method: str,
    params: dict[str, Any],
    *,
    session_id: str,
) -> Any:
    """Single dispatcher for all kiro→client requests.

    Routes by *method* name to a private handler.  Raises
    :class:`AcpRpcError` on protocol-level failures so that
    :class:`AcpClient` can translate to a JSON-RPC error response.

    Args:
        method: The JSON-RPC method name (e.g. ``"fs/read_text_file"``).
        params: The ``params`` object from the request.
        session_id: The active ACP session id (for logging / context).

    Returns:
        The result payload (will be wrapped in a JSON-RPC success response
        by ``AcpClient``).

    Raises:
        AcpRpcError: On any protocol-level failure.
    """
    logger.debug(
        "Agent request method=%s session=%s params_keys=%s",
        method,
        session_id,
        list(params.keys()),
    )

    handlers: dict[str, Any] = {
        "fs/read_text_file": _handle_fs_read_text_file,
        "fs/write_text_file": _handle_fs_write_text_file,
        "terminal/create": _handle_terminal_create,
        "terminal/output": _handle_terminal_output,
        "terminal/wait_for_exit": _handle_terminal_wait_for_exit,
        "terminal/kill": _handle_terminal_kill,
        "terminal/release": _handle_terminal_release,
    }

    handler = handlers.get(method)
    if handler is None:
        # Unknown methods (including _kiro.dev/*) get a -32601.
        raise AcpRpcError(-32601, f"Method not found: {method}")

    return await handler(params)


# ---------------------------------------------------------------------------
# Filesystem handlers
# ---------------------------------------------------------------------------


async def _handle_fs_read_text_file(params: dict[str, Any]) -> dict[str, str]:
    """Handle ``fs/read_text_file`` callback from the agent.

    Validates that *path* is absolute (per ACP spec §13).  Honours optional
    *line* (1-based) and *limit* parameters.

    Returns:
        ``{"content": "<file text>"}``

    Raises:
        AcpRpcError: On validation failure or I/O error.
    """
    path = params.get("path")
    if not path or not isinstance(path, str):
        raise AcpRpcError(-32602, "Missing required parameter: path")

    if not os.path.isabs(path):
        raise AcpRpcError(-32602, f"Path must be absolute: {path}")

    line: int | None = params.get("line")
    limit: int | None = params.get("limit")

    # Log for user visibility (even when auto-approved).
    try:
        from code_puppy.messaging import emit_info

        emit_info(f"kiro reading {path}")
    except Exception:
        logger.info("kiro reading %s", path)

    if not autoapprove_fs_read():
        allowed = await _check_file_permission(path, "read")
        if not allowed:
            raise AcpRpcError(-32001, f"Permission denied for read: {path}")

    try:
        # Preferred: use code-puppy's internal read helper if importable.
        # Fall back to plain pathlib for robustness.
        content = _read_file_with_fallback(path, line, limit)
    except FileNotFoundError:
        raise AcpRpcError(-32000, f"File not found: {path}")
    except PermissionError:
        raise AcpRpcError(-32000, f"Permission denied: {path}")
    except Exception as exc:
        raise AcpRpcError(-32000, f"Read failed: {exc}")

    return {"content": content}


def _read_file_with_fallback(
    path: str,
    line: int | None,
    limit: int | None,
) -> str:
    """Read a file, applying optional line/limit slicing.

    Tries ``utf-8`` first, then falls back to ``latin-1`` for binary-ish
    files.  Returns the content as a string.
    """
    file_path = Path(path)

    # Try UTF-8 first, then latin-1 as a lossless fallback.
    for encoding in ("utf-8", "latin-1"):
        try:
            content = file_path.read_text(encoding=encoding)
            break
        except UnicodeDecodeError:
            continue
    else:
        # Should never hit — latin-1 accepts everything.
        raise AcpRpcError(-32000, f"Could not decode file: {path}")

    # Apply line/limit slicing (ACP line numbers are 1-based).
    if line is not None or limit is not None:
        lines = content.splitlines(keepends=True)
        start_idx = max(0, (line or 1) - 1)
        end_idx = start_idx + limit if limit is not None else len(lines)
        content = "".join(lines[start_idx:end_idx])

    return content


async def _handle_fs_write_text_file(params: dict[str, Any]) -> None:
    """Handle ``fs/write_text_file`` callback from the agent.

    Validates that *path* is absolute.  Creates parent directories as needed.

    Returns:
        ``None`` (JSON-RPC ``result: null``).

    Raises:
        AcpRpcError: On validation failure or I/O error.
    """
    path = params.get("path")
    if not path or not isinstance(path, str):
        raise AcpRpcError(-32602, "Missing required parameter: path")

    if not os.path.isabs(path):
        raise AcpRpcError(-32602, f"Path must be absolute: {path}")

    content = params.get("content")
    if content is None:
        raise AcpRpcError(-32602, "Missing required parameter: content")

    if not autoapprove_fs_write():
        allowed = await _check_file_permission(path, "write")
        if not allowed:
            raise AcpRpcError(-32001, f"Permission denied for write: {path}")

    try:
        file_path = Path(path)
        file_path.parent.mkdir(parents=True, exist_ok=True)
        file_path.write_text(content, encoding="utf-8")

        try:
            from code_puppy.messaging import emit_success

            emit_success(f"kiro wrote {path}")
        except Exception:
            logger.info("kiro wrote %s", path)

    except PermissionError:
        raise AcpRpcError(-32000, f"Permission denied: {path}")
    except Exception as exc:
        raise AcpRpcError(-32000, f"Write failed: {exc}")


# ---------------------------------------------------------------------------
# Terminal handlers
# ---------------------------------------------------------------------------


async def _handle_terminal_create(params: dict[str, Any]) -> dict[str, str]:
    """Handle ``terminal/create`` callback from the agent.

    Spawns a subprocess and starts a background reader task that drains
    stdout into a bounded buffer.

    Returns:
        ``{"terminalId": "<id>"}``

    Raises:
        AcpRpcError: On validation failure or spawn error.
    """
    command = params.get("command")
    if not command or not isinstance(command, str):
        raise AcpRpcError(-32602, "Missing required parameter: command")

    args: list[str] = params.get("args") or []
    cwd: str | None = params.get("cwd")
    env_list: list[dict[str, str]] | None = params.get("env")
    output_byte_limit: int = params.get("outputByteLimit", 1_048_576)

    # Build environment: inherit current process env + merge agent-supplied vars.
    merged_env = dict(os.environ)
    if env_list:
        for entry in env_list:
            name = entry.get("name")
            value = entry.get("value")
            if name is not None and value is not None:
                merged_env[name] = value

    if not autoapprove_terminal():
        allowed = await _check_shell_command(command, args)
        if not allowed:
            raise AcpRpcError(-32001, f"Shell command denied: {command} {' '.join(args)}")

    try:
        proc = await asyncio.create_subprocess_exec(
            command,
            *args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
            cwd=cwd,
            env=merged_env,
        )
    except FileNotFoundError:
        raise AcpRpcError(-32000, f"Command not found: {command}")
    except Exception as exc:
        raise AcpRpcError(-32000, f"Failed to spawn process: {exc}")

    term_id = f"term_{uuid.uuid4().hex[:12]}"
    terminal = _RunningTerminal(
        proc=proc,
        output_byte_limit=output_byte_limit,
    )

    # Background task: drain stdout into the buffer until byte limit or EOF.
    terminal.read_task = asyncio.create_task(
        _drain_terminal_stdout(terminal),
        name=f"term-reader-{term_id}",
    )

    _terminals[term_id] = terminal
    logger.debug("Created terminal %s (pid=%s): %s %s", term_id, proc.pid, command, args)

    return {"terminalId": term_id}


async def _drain_terminal_stdout(terminal: _RunningTerminal) -> None:
    """Background coroutine that drains the process's stdout into the buffer."""
    assert terminal.proc.stdout is not None
    reader = terminal.proc.stdout

    try:
        while True:
            chunk = await reader.read(65_536)
            if not chunk:
                break
            remaining = terminal.output_byte_limit - len(terminal.stdout_buffer)
            if remaining <= 0:
                terminal.truncated = True
                # Keep reading to prevent pipe back-pressure, but discard.
                continue
            if len(chunk) > remaining:
                terminal.stdout_buffer.extend(chunk[:remaining])
                terminal.truncated = True
            else:
                terminal.stdout_buffer.extend(chunk)
    except asyncio.CancelledError:
        return
    except Exception as exc:
        logger.warning("Terminal drain error: %s", exc)


async def _handle_terminal_output(params: dict[str, Any]) -> dict[str, Any]:
    """Handle ``terminal/output`` callback from the agent.

    Returns a non-blocking snapshot of the terminal's output buffer.

    Returns:
        ``{"output": str, "truncated": bool, "exitStatus": dict | None}``

    Raises:
        AcpRpcError: If the terminal id is unknown.
    """
    term_id = params.get("terminalId")
    terminal = _get_terminal(term_id)

    output = terminal.stdout_buffer.decode("utf-8", errors="replace")

    exit_status: dict[str, Any] | None = None
    if terminal.proc.returncode is not None:
        rc = terminal.proc.returncode
        exit_status = {
            "exitCode": rc,
            "signal": -rc if rc < 0 else None,
        }

    return {
        "output": output,
        "truncated": terminal.truncated,
        "exitStatus": exit_status,
    }


async def _handle_terminal_wait_for_exit(params: dict[str, Any]) -> dict[str, Any]:
    """Handle ``terminal/wait_for_exit`` callback from the agent.

    Blocks until the terminal process exits.

    Returns:
        ``{"exitCode": int, "signal": int | None}``

    Raises:
        AcpRpcError: If the terminal id is unknown.
    """
    term_id = params.get("terminalId")
    terminal = _get_terminal(term_id)

    rc = await terminal.proc.wait()

    return {
        "exitCode": rc,
        "signal": -rc if rc < 0 else None,
    }


async def _handle_terminal_kill(params: dict[str, Any]) -> None:
    """Handle ``terminal/kill`` callback from the agent.

    Sends SIGKILL to the process.  The terminal remains valid for
    reading buffered output.

    Returns:
        ``None``

    Raises:
        AcpRpcError: If the terminal id is unknown.
    """
    term_id = params.get("terminalId")
    terminal = _get_terminal(term_id)

    try:
        terminal.proc.kill()
    except ProcessLookupError:
        pass  # Already dead.

    return None


async def _handle_terminal_release(params: dict[str, Any]) -> None:
    """Handle ``terminal/release`` callback from the agent.

    Kills the process if still running, cancels the drain task, and
    removes the terminal from the registry.

    Returns:
        ``None``

    Raises:
        AcpRpcError: If the terminal id is unknown.
    """
    term_id = params.get("terminalId")
    terminal = _get_terminal(term_id)

    # Kill if still running.
    if terminal.proc.returncode is None:
        try:
            terminal.proc.kill()
        except ProcessLookupError:
            pass
        try:
            await asyncio.wait_for(terminal.proc.wait(), timeout=5.0)
        except asyncio.TimeoutError:
            logger.warning("Terminal %s did not exit after kill", term_id)

    # Cancel drain task.
    if terminal.read_task and not terminal.read_task.done():
        terminal.read_task.cancel()
        try:
            await terminal.read_task
        except asyncio.CancelledError:
            pass

    terminal.released = True
    _terminals.pop(term_id, None)
    logger.debug("Released terminal %s", term_id)

    return None


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _get_terminal(term_id: Any) -> _RunningTerminal:
    """Look up a terminal by id, raising AcpRpcError if not found."""
    if not term_id or not isinstance(term_id, str):
        raise AcpRpcError(-32602, "Missing required parameter: terminalId")
    terminal = _terminals.get(term_id)
    if terminal is None:
        raise AcpRpcError(-32000, f"Unknown terminal: {term_id}")
    return terminal
