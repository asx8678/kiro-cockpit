"""Low-level async JSON-RPC 2.0 stdio transport for ``kiro-cli acp``.

This module is a **pure transport layer** — it knows nothing about ACP session
semantics (``initialize``, ``session/new``, ``session/prompt``).  Higher layers
(Stage 2's ``kiro_model.py``) build protocol awareness on top.

Framing follows the ACP spec §13: **one JSON object per line**, no
``Content-Length`` headers, no embedded newlines inside a payload.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
from collections.abc import Awaitable, Callable
from pathlib import Path
from typing import Any, Optional

logger = logging.getLogger(__name__)

# Maximum line length we'll accept from the agent (guards against runaway output).
_MAX_LINE_BYTES: int = 4 * 1024 * 1024  # 4 MiB

# Truncation limit for debug log messages.
_LOG_TRUNCATE: int = 500


# ---------------------------------------------------------------------------
# Exceptions
# ---------------------------------------------------------------------------


class AcpError(Exception):
    """Base exception for all ACP client errors."""


class AcpRpcError(AcpError):
    """A JSON-RPC error response was received from the agent."""

    def __init__(self, code: int, message: str, data: Any = None) -> None:
        self.code = code
        self.message = message
        self.data = data
        super().__init__(f"RPC error {code}: {message}")

    def __repr__(self) -> str:
        return f"AcpRpcError(code={self.code!r}, message={self.message!r}, data={self.data!r})"


class AcpProtocolError(AcpError):
    """Malformed line, oversized payload, or other framing violation."""


class AcpProcessError(AcpError):
    """The child process died unexpectedly."""

    def __init__(self, returncode: int | None, stderr_tail: str = "") -> None:
        self.returncode = returncode
        self.stderr_tail = stderr_tail
        msg = f"kiro-cli exited with code {returncode}"
        if stderr_tail:
            msg += f": {stderr_tail[:200]}"
        super().__init__(msg)


# ---------------------------------------------------------------------------
# Client
# ---------------------------------------------------------------------------

# Type aliases for callback signatures
_AgentRequestHandler = Callable[[str, dict[str, Any]], Awaitable[Any]]
_NotificationHandler = Callable[[str, dict[str, Any]], Awaitable[None]]


class AcpClient:
    """Async JSON-RPC 2.0 client that talks to ``kiro-cli acp`` over stdio.

    Usage::

        async with AcpClient(Path("/usr/local/bin/kiro-cli")) as client:
            result = await client.call("initialize", {"protocolVersion": 1})
    """

    def __init__(
        self,
        kiro_cli_path: Path,
        *,
        cwd: str | None = None,
        env: dict[str, str] | None = None,
        on_request_from_agent: _AgentRequestHandler | None = None,
        on_notification: _NotificationHandler | None = None,
    ) -> None:
        self._kiro_cli_path = kiro_cli_path
        self._cwd = cwd
        self._base_env: dict[str, str] | None = env
        self._on_request = on_request_from_agent
        self._on_notification = on_notification

        # Mutable state
        self._process: asyncio.subprocess.Process | None = None
        self._next_id: int = 1
        self._pending: dict[int, asyncio.Future[Any]] = {}
        self._write_lock: asyncio.Lock = asyncio.Lock()
        self._reader_task: asyncio.Task[None] | None = None
        self._stderr_task: asyncio.Task[None] | None = None
        self._closed: bool = False

    # -- Lifecycle ----------------------------------------------------------

    async def start(self) -> None:
        """Spawn the ``kiro-cli acp`` subprocess and begin reading."""
        if self._process is not None:
            raise AcpError("AcpClient already started")

        env = self._build_env()
        logger.info(
            "Starting kiro-cli acp: %s  cwd=%s",
            self._kiro_cli_path,
            self._cwd or os.getcwd(),
        )

        self._process = await asyncio.create_subprocess_exec(
            str(self._kiro_cli_path),
            "acp",
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=self._cwd,
            env=env,
        )

        self._reader_task = asyncio.create_task(
            self._read_loop(), name="acp-reader"
        )
        self._stderr_task = asyncio.create_task(
            self._drain_stderr(), name="acp-stderr"
        )

        logger.debug("kiro-cli acp subprocess started (pid=%s)", self._process.pid)

    async def close(self) -> None:
        """Shut down the subprocess and cancel background tasks.

        Idempotent — safe to call multiple times.
        """
        if self._closed:
            return
        self._closed = True
        logger.debug("AcpClient.close() called")

        # 1. Close stdin politely so the agent can wind down.
        if self._process and self._process.stdin:
            try:
                self._process.stdin.close()
            except (OSError, BrokenPipeError):
                pass

        # 2. Wait briefly for graceful exit.
        if self._process:
            try:
                await asyncio.wait_for(self._process.wait(), timeout=5.0)
            except asyncio.TimeoutError:
                logger.warning("kiro-cli did not exit after stdin close; terminating")
                self._process.terminate()
                try:
                    await asyncio.wait_for(self._process.wait(), timeout=3.0)
                except asyncio.TimeoutError:
                    logger.warning("kiro-cli did not terminate; killing")
                    self._process.kill()
                    await self._process.wait()

        # 3. Cancel reader / stderr tasks.
        for task in (self._reader_task, self._stderr_task):
            if task and not task.done():
                task.cancel()
                try:
                    await task
                except asyncio.CancelledError:
                    pass

        # 4. Fail any pending futures.
        for rid, fut in self._pending.items():
            if not fut.done():
                fut.set_exception(AcpProcessError(self._process.returncode if self._process else None))
        self._pending.clear()

    async def __aenter__(self) -> AcpClient:
        await self.start()
        return self

    async def __aexit__(
        self,
        exc_type: type[BaseException] | None,
        exc_val: BaseException | None,
        exc_tb: Any,
    ) -> None:
        await self.close()

    # -- JSON-RPC core ------------------------------------------------------

    async def call(
        self,
        method: str,
        params: dict[str, Any],
        *,
        timeout: float | None = 120.0,
    ) -> Any:
        """Send a JSON-RPC request and wait for the response.

        Args:
            method: The RPC method name.
            params: Parameters dict.
            timeout: Seconds to wait. ``None`` means wait forever.

        Returns:
            The ``result`` field from the response.

        Raises:
            AcpRpcError: If the response contains an ``error`` field.
            asyncio.TimeoutError: If *timeout* is exceeded.
            AcpProcessError: If the subprocess dies while waiting.
        """
        rid = self._next_id
        self._next_id += 1

        msg: dict[str, Any] = {
            "jsonrpc": "2.0",
            "id": rid,
            "method": method,
            "params": params,
        }

        fut: asyncio.Future[Any] = asyncio.get_running_loop().create_future()
        self._pending[rid] = fut

        await self._send(msg)

        try:
            if timeout is not None:
                result = await asyncio.wait_for(fut, timeout=timeout)
            else:
                result = await fut
        except asyncio.TimeoutError:
            # Clean up the pending entry so the reader doesn't try to resolve a
            # dangling future later.
            self._pending.pop(rid, None)
            raise
        finally:
            # Belt-and-suspenders: always remove from pending after resolution.
            self._pending.pop(rid, None)

        return result

    def notify(self, method: str, params: dict[str, Any]) -> None:
        """Fire-and-forget notification (no ``id``, no response expected).

        This is synchronous because ``asyncio.ensure_future`` handles the write;
        callers don't need to ``await`` anything.
        """
        msg: dict[str, Any] = {
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        }
        # Schedule the send; don't await.
        asyncio.ensure_future(self._send(msg))

    async def respond(self, request_id: int, result: Any) -> None:
        """Respond to an inbound agent→client request with a success result."""
        msg: dict[str, Any] = {
            "jsonrpc": "2.0",
            "id": request_id,
            "result": result,
        }
        await self._send(msg)

    async def respond_error(
        self,
        request_id: int,
        code: int,
        message: str,
        data: Any = None,
    ) -> None:
        """Respond to an inbound agent→client request with a JSON-RPC error."""
        error_body: dict[str, Any] = {"code": code, "message": message}
        if data is not None:
            error_body["data"] = data
        msg: dict[str, Any] = {
            "jsonrpc": "2.0",
            "id": request_id,
            "error": error_body,
        }
        await self._send(msg)

    # -- Internals ----------------------------------------------------------

    def _build_env(self) -> dict[str, str]:
        """Construct the environment for the child process."""
        env = dict(os.environ)
        if self._base_env:
            env.update(self._base_env)

        # Inject KIRO_LOG_LEVEL from config if available.
        try:
            from .config import get_log_level

            level = get_log_level()
            if level:
                env["KIRO_LOG_LEVEL"] = level
        except Exception:
            pass

        return env

    async def _send(self, msg: dict[str, Any]) -> None:
        """Serialize and write a single JSON-RPC message to stdin."""
        if self._process is None or self._process.stdin is None:
            raise AcpError("AcpClient not started or stdin closed")

        payload = json.dumps(msg, ensure_ascii=False, separators=(",", ":"))

        # Sanity check: no unescaped newlines in the payload.
        if "\n" in payload:
            raise AcpProtocolError(
                f"Outbound message contains embedded newline — framing violated. "
                f"Method: {msg.get('method', '?')}"
            )

        line = payload + "\n"

        if len(line.encode("utf-8")) > _MAX_LINE_BYTES:
            raise AcpProtocolError(
                f"Outbound message exceeds {_MAX_LINE_BYTES} bytes"
            )

        async with self._write_lock:
            logger.debug("→ %s", payload[:_LOG_TRUNCATE])
            try:
                self._process.stdin.write(line.encode("utf-8"))
                await self._process.stdin.drain()
            except (OSError, BrokenPipeError) as exc:
                raise AcpProcessError(
                    self._process.returncode,
                    f"stdin write failed: {exc}",
                ) from exc

    # -- Inbound reader -----------------------------------------------------

    async def _read_loop(self) -> None:
        """Drain stdout line-by-line and dispatch each message."""
        assert self._process is not None and self._process.stdout is not None
        reader = self._process.stdout

        while True:
            try:
                raw = await reader.readline()
            except asyncio.CancelledError:
                return
            except Exception as exc:
                logger.error("stdout read error: %s", exc)
                return

            if not raw:
                # EOF — subprocess closed stdout.
                logger.debug("stdout EOF (kiro-cli exited)")
                self._fail_pending(AcpProcessError(
                    self._process.returncode if self._process else None,
                ))
                return

            line = raw.decode("utf-8", errors="replace").strip()
            if not line:
                continue

            if len(raw) > _MAX_LINE_BYTES:
                logger.warning(
                    "Dropping oversized line (%d bytes)", len(raw)
                )
                continue

            logger.debug("← %s", line[:_LOG_TRUNCATE])

            try:
                msg: dict[str, Any] = json.loads(line)
            except json.JSONDecodeError as exc:
                logger.warning("Malformed JSON, skipping: %s — raw=%r", exc, line[:200])
                continue

            try:
                await self._dispatch(msg)
            except asyncio.CancelledError:
                return
            except Exception as exc:
                logger.error("Dispatch error: %s", exc, exc_info=True)

    async def _dispatch(self, msg: dict[str, Any]) -> None:
        """Route an inbound message to the correct handler.

        Three shapes per JSON-RPC 2.0:
        1. **Response** to our outbound call: has ``id`` and (``result`` | ``error``), no ``method``.
        2. **Request** from agent: has ``id`` and ``method``.
        3. **Notification**: has ``method`` but no ``id``.
        """
        rid = msg.get("id")
        method = msg.get("method")

        # 1. Response to our outbound call.
        if rid is not None and method is None:
            fut = self._pending.get(rid)
            if fut is None:
                logger.warning("Response for unknown id=%s, ignoring", rid)
                return
            if fut.done():
                return
            if "error" in msg:
                err = msg["error"]
                fut.set_exception(
                    AcpRpcError(
                        code=err.get("code", -1),
                        message=err.get("message", "Unknown error"),
                        data=err.get("data"),
                    )
                )
            else:
                fut.set_result(msg.get("result"))
            return

        # 2. Request from agent (agent → client callback).
        if rid is not None and method is not None:
            await self._handle_agent_request(rid, method, msg.get("params", {}))
            return

        # 3. Notification (no id).
        if rid is None and method is not None:
            await self._handle_notification(method, msg.get("params", {}))
            return

        logger.warning("Unrecognized message shape: %s", json.dumps(msg)[:200])

    async def _handle_agent_request(
        self, request_id: int, method: str, params: dict[str, Any]
    ) -> None:
        """Dispatch an inbound request from the agent and auto-respond."""
        if self._on_request is None:
            logger.warning("No handler for agent request method=%s, sending -32601", method)
            await self.respond_error(request_id, -32601, "Method not found")
            return

        try:
            result = await self._on_request(method, params)
            await self.respond(request_id, result)
        except AcpRpcError as exc:
            # Let callers raise AcpRpcError to send a specific error code.
            await self.respond_error(request_id, exc.code, exc.message, exc.data)
        except Exception as exc:
            logger.error(
                "Agent request handler failed for method=%s: %s",
                method,
                exc,
                exc_info=True,
            )
            await self.respond_error(request_id, -32603, str(exc))

    async def _handle_notification(
        self, method: str, params: dict[str, Any]
    ) -> None:
        """Dispatch an inbound notification from the agent."""
        if self._on_notification is None:
            logger.debug("Unhandled notification method=%s", method)
            return

        try:
            await self._on_notification(method, params)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            # Notifications are fire-and-forget; swallow but log.
            logger.warning("Notification handler error for method=%s: %s", method, exc)

    # -- Stderr drain -------------------------------------------------------

    async def _drain_stderr(self) -> None:
        """Read stderr into the logger so it doesn't fill the OS pipe buffer."""
        assert self._process is not None and self._process.stderr is not None
        reader = self._process.stderr

        while True:
            try:
                raw = await reader.readline()
            except asyncio.CancelledError:
                return
            except Exception:
                return

            if not raw:
                return

            line = raw.decode("utf-8", errors="replace").rstrip()
            if line:
                logger.debug("[kiro-cli stderr] %s", line[:_LOG_TRUNCATE])

    # -- Helpers ------------------------------------------------------------

    def _fail_pending(self, exc: BaseException) -> None:
        """Set an exception on all pending futures (used on process death)."""
        for fut in self._pending.values():
            if not fut.done():
                fut.set_exception(exc)
        self._pending.clear()
