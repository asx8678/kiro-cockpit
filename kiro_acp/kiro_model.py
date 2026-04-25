"""pydantic-ai ``Model`` adapter for ``kiro-cli acp``.

One :class:`KiroAcpModel` instance owns one :class:`AcpClient` and one
ACP session.  Code-puppy sees a normal "model" that produces text +
thinking — kiro's internal tool calls (``fs/*``, ``terminal/*``) are
handled transparently by :mod:`callbacks_handler`.
"""

from __future__ import annotations

import asyncio
import logging
import os
from collections.abc import AsyncIterator, Iterator
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Optional, Sequence

from pydantic_ai._run_context import RunContext
from pydantic_ai.messages import (
    ModelMessage,
    ModelRequest,
    ModelResponse,
    ModelResponsePart,
    ModelResponseStreamEvent,
    SystemPromptPart,
    TextPart,
    ThinkingPart,
    UserPromptPart,
)
from pydantic_ai.models import Model, ModelRequestParameters, StreamedResponse
from pydantic_ai.settings import ModelSettings
from pydantic_ai.usage import RequestUsage

from .acp_client import AcpClient, AcpError, AcpRpcError
from .callbacks_handler import handle_agent_request
from .config import (
    KIRO_PROTOCOL_VERSION,
    discover_kiro_cli,
    get_default_mode,
)

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _emit_tool_visual(update: dict[str, Any]) -> None:
    """Send a tool-call / plan visual to the user via code-puppy's messaging.

    Uses ``emit_info`` from ``code_puppy.messaging`` so that kiro's internal
    tool activity is visible in the console.
    """
    try:
        from code_puppy.messaging import emit_info
    except Exception:
        return

    variant = update.get("sessionUpdate", "")
    if variant == "tool_call":
        title = update.get("title") or update.get("toolCallId", "")
        kind = update.get("kind", "")
        emit_info(f"[kiro] 🔧 {kind}: {title}")
    elif variant == "tool_call_update":
        status = update.get("status", "")
        tool_id = update.get("toolCallId", "")
        if status in ("completed", "failed", "cancelled"):
            emit_info(f"[kiro] ↓ {tool_id}: {status}")
    elif variant == "plan":
        entries = update.get("entries", [])
        if entries:
            emit_info(f"[kiro] 📋 plan: {len(entries)} steps")
    else:
        logger.debug("_emit_tool_visual: unhandled variant %s", variant)

def _code_puppy_version() -> str:
    """Best-effort version string for ``clientInfo``."""
    try:
        import code_puppy  # noqa: F811

        return str(getattr(code_puppy, "__version__", "unknown"))
    except Exception:
        return "unknown"


# ---------------------------------------------------------------------------
# KiroAcpModel
# ---------------------------------------------------------------------------


class KiroAcpModel(Model):
    """pydantic-ai ``Model`` that delegates to a ``kiro-cli acp`` subprocess.

    One instance owns one :class:`AcpClient` + one ACP session.  Plays the
    role of a "model" in code-puppy's eyes; internally runs a complete
    agent turn — including tool calls — entirely inside the subprocess.
    """

    # -- Construction -------------------------------------------------------

    def __init__(
        self,
        model_name: str,
        model_config: dict[str, Any],
        config: dict[str, Any],
    ) -> None:
        # Call Model.__init__ with defaults — no special settings/profile.
        super().__init__()

        self._model_name: str = model_name
        self._kiro_model_id: str = model_config.get("name", "")
        self._cwd: str = os.getcwd()

        # Lazy-init state (populated by _ensure_session).
        self._client: Optional[AcpClient] = None
        self._session_id: Optional[str] = None
        self._initialized: bool = False
        self._init_lock: Optional[asyncio.Lock] = None  # created lazily

        # Per-prompt update queue — created at the start of each request,
        # torn down at the end.
        self._update_queue: Optional[asyncio.Queue[dict[str, Any] | None]] = None

        # Stores the session result (modes, configOptions) for reference.
        self._session_result: dict[str, Any] = {}

        logger.debug(
            "KiroAcpModel created: model_name=%s kiro_model_id=%s cwd=%s",
            self._model_name,
            self._kiro_model_id,
            self._cwd,
        )

    # -- Required pydantic-ai properties ------------------------------------

    @property
    def model_name(self) -> str:
        """Return the code-puppy-facing model id."""
        return self._model_name

    @property
    def system(self) -> str:
        """Return the provider system identifier."""
        return "kiro_acp"

    @property
    def base_url(self) -> str | None:
        """Return the kiro-cli path or a placeholder."""
        cli = discover_kiro_cli()
        return str(cli) if cli else "kiro-cli"

    @staticmethod
    def _get_instructions(
        messages: Sequence[ModelMessage],
        model_request_parameters: ModelRequestParameters | None = None,
    ) -> str | None:
        """Return None — kiro has its own system prompt / instructions."""
        return None

    def prepare_request(
        self,
        model_settings: ModelSettings | None,
        model_request_parameters: ModelRequestParameters,
    ) -> tuple[ModelSettings | None, ModelRequestParameters]:
        """Pass-through — no custom settings merging needed."""
        return model_settings, model_request_parameters

    # -- Lazy session initialization ----------------------------------------

    def _get_init_lock(self) -> asyncio.Lock:
        """Return the init lock, creating it in the running loop if needed."""
        if self._init_lock is None:
            self._init_lock = asyncio.Lock()
        return self._init_lock

    async def _ensure_session(self) -> None:
        """Idempotently discover kiro-cli, spawn the subprocess, and
        initialise + create an ACP session.

        Safe to call from every ``request`` / ``request_stream``.
        """
        if self._initialized:
            return

        lock = self._get_init_lock()
        async with lock:
            # Double-check after acquiring lock.
            if self._initialized:
                return

            # 1. Discover kiro-cli binary.
            cli_path = discover_kiro_cli()
            if cli_path is None:
                raise AcpError(
                    "kiro-cli not found. Install it or configure "
                    "'kiro_acp.cli_path' in code-puppy config."
                )

            # 2. Spawn the AcpClient.
            self._client = AcpClient(
                cli_path,
                cwd=self._cwd,
                on_request_from_agent=self._on_agent_request,
                on_notification=self._on_notification,
            )
            await self._client.start()

            # 3. initialize — advertise our capabilities.
            init_result = await self._client.call(
                "initialize",
                {
                    "protocolVersion": KIRO_PROTOCOL_VERSION,
                    "clientCapabilities": {
                        "fs": {
                            "readTextFile": True,
                            "writeTextFile": True,
                        },
                        "terminal": True,
                    },
                    "clientInfo": {
                        "name": "code-puppy",
                        "title": "Code Puppy",
                        "version": _code_puppy_version(),
                    },
                },
                timeout=30.0,
            )
            logger.debug("initialize result: %s", init_result)

            # 4. session/new
            session_result = await self._client.call(
                "session/new",
                {
                    "cwd": self._cwd,
                    "mcpServers": [],
                },
                timeout=30.0,
            )
            self._session_id = session_result.get("sessionId")
            self._session_result = session_result
            logger.info(
                "ACP session created: %s (modes=%s)",
                self._session_id,
                session_result.get("modes"),
            )

            # 5. Set the kiro-side model if configured and different from
            #    the session's current value.
            config_options = session_result.get("configOptions", [])
            current_model = None
            for opt in config_options:
                if opt.get("id") == "model":
                    current_model = opt.get("currentValue")
                    break

            if self._kiro_model_id and self._kiro_model_id != current_model:
                logger.info(
                    "Setting kiro model to %s (was %s)",
                    self._kiro_model_id,
                    current_model,
                )
                await self._client.call(
                    "session/set_config_option",
                    {
                        "sessionId": self._session_id,
                        "configId": "model",
                        "value": self._kiro_model_id,
                    },
                    timeout=30.0,
                )

            # 6. Set the default mode if it differs from current.
            desired_mode = get_default_mode()
            current_mode = None
            modes_block = session_result.get("modes", {})
            current_mode = modes_block.get("currentModeId")
            if desired_mode and desired_mode != current_mode:
                logger.info("Setting kiro mode to %s (was %s)", desired_mode, current_mode)
                await self._client.call(
                    "session/set_mode",
                    {
                        "sessionId": self._session_id,
                        "modeId": desired_mode,
                    },
                    timeout=30.0,
                )

            self._initialized = True
            logger.info("KiroAcpModel session fully initialized: %s", self._session_id)

    # -- Callbacks from the AcpClient ---------------------------------------

    async def _on_agent_request(self, method: str, params: dict[str, Any]) -> Any:
        """Delegate agent→client requests to the callbacks handler."""
        return await handle_agent_request(
            method,
            params,
            session_id=self._session_id or "",
        )

    async def _on_notification(self, method: str, params: dict[str, Any]) -> None:
        """Handle notifications from the agent.

        The primary notification is ``session/update`` which streams the
        agent's output (text chunks, thinking chunks, tool calls, etc.).
        """
        if method != "session/update":
            logger.debug("Ignoring notification method=%s", method)
            return

        # Only process updates for our session.
        notif_session = params.get("sessionId")
        if notif_session and notif_session != self._session_id:
            return

        update = params.get("update")
        if update is None:
            return

        if self._update_queue is not None:
            await self._update_queue.put(update)
        else:
            # No active prompt — drop the update (expected between prompts).
            variant = update.get("sessionUpdate", "<unknown>")
            logger.debug("Dropping session/update between prompts: %s", variant)

    # -- Prompt block translation -------------------------------------------

    def _build_prompt_blocks(self, messages: list[ModelMessage]) -> list[dict[str, Any]]:
        """Translate pydantic-ai messages into ACP prompt content blocks.

        Strategy A: kiro owns the conversation history via its session.
        We only need to hand it the *latest* user input.  So we walk
        messages backward and collect every part from the last
        ``ModelRequest``.

        - ``UserPromptPart`` → ``{"type": "text", "text": ...}``
        - ``SystemPromptPart`` → folded into the first text block
        - ``ToolReturnPart`` from earlier turns → skipped (kiro already
          executed those tools internally).
        - Everything from prior ``ModelResponse``s → skipped.
        """
        blocks: list[dict[str, Any]] = []
        system_text: str | None = None

        # Walk backward to find the last ModelRequest.
        for msg in reversed(messages):
            if isinstance(msg, ModelRequest):
                # Collect system prompt text to prepend.
                for part in msg.parts:
                    if isinstance(part, SystemPromptPart):
                        system_text = part.content
                        break

                # Now collect user prompt parts (forward order within this request).
                for part in msg.parts:
                    if isinstance(part, UserPromptPart):
                        text = self._extract_user_text(part)
                        if text:
                            if system_text:
                                # Fold system prompt into the first text block.
                                text = f"{system_text}\n\n{text}"
                                system_text = None  # Only once.
                            blocks.append({"type": "text", "text": text})
                    # Skip ToolReturnPart, RetryPromptPart — kiro handled those.
                break  # Only the last ModelRequest matters.

        # If there was a system prompt but no user prompt, emit it alone.
        if system_text and not blocks:
            blocks.append({"type": "text", "text": system_text})

        if not blocks:
            blocks.append({"type": "text", "text": ""})

        return blocks

    @staticmethod
    def _extract_user_text(part: UserPromptPart) -> str:
        """Extract plain text from a UserPromptPart.

        Handles both ``str`` content and ``list`` content (which may
        contain ``str`` items or binary content like images).
        """
        if isinstance(part.content, str):
            return part.content
        elif isinstance(part.content, list):
            texts: list[str] = []
            for item in part.content:
                if isinstance(item, str):
                    texts.append(item)
                # Binary/image content is not supported in ACP text prompts;
                # skip silently (kiro's promptCapabilities would need image:true).
            return "\n".join(texts)
        else:
            return str(part.content)

    # -- Update handling ----------------------------------------------------

    def _collect_updates_non_streaming(
        self,
        update: dict[str, Any],
        text_parts: list[str],
        thinking_parts: list[str],
    ) -> None:
        """Process a single session/update for non-streaming mode."""
        variant = update.get("sessionUpdate", "")

        if variant == "agent_message_chunk":
            content_block = update.get("content", {})
            text = content_block.get("text", "")
            if text:
                text_parts.append(text)

        elif variant == "agent_thought_chunk":
            content_block = update.get("content", {})
            text = content_block.get("text", "")
            if text:
                thinking_parts.append(text)

        elif variant == "tool_call":
            _emit_tool_visual(update)

        elif variant == "tool_call_update":
            _emit_tool_visual(update)

        elif variant == "plan":
            _emit_tool_visual(update)

        elif variant in ("current_mode_update", "config_option_update"):
            logger.debug("Config/mode update: %s", variant)

        elif variant == "user_message_chunk":
            # Echoes during session/load — ignore.
            pass

        else:
            logger.debug("Unknown sessionUpdate variant: %s", variant)

    # -- Non-streaming request ----------------------------------------------

    async def request(
        self,
        messages: list[ModelMessage],
        model_settings: ModelSettings | None,
        model_request_parameters: ModelRequestParameters,
    ) -> ModelResponse:
        """Make a non-streaming request to kiro.

        Sends a ``session/prompt``, consumes all ``session/update``
        notifications, and returns a single :class:`ModelResponse`.
        """
        await self._ensure_session()
        assert self._client is not None and self._session_id is not None

        blocks = self._build_prompt_blocks(messages)
        self._update_queue = asyncio.Queue()

        text_parts: list[str] = []
        thinking_parts: list[str] = []

        # Send the prompt as a task so we can consume updates concurrently.
        prompt_task = asyncio.create_task(
            self._client.call(
                "session/prompt",
                {
                    "sessionId": self._session_id,
                    "prompt": blocks,
                },
                timeout=600.0,
            )
        )

        try:
            while not prompt_task.done():
                try:
                    update = await asyncio.wait_for(
                        self._update_queue.get(), timeout=0.1
                    )
                except asyncio.TimeoutError:
                    continue
                if update is None:
                    # Sentinel — shouldn't happen here, but be safe.
                    break
                self._collect_updates_non_streaming(
                    update, text_parts, thinking_parts
                )

            # Drain any remaining updates after prompt completes.
            while True:
                try:
                    update = self._update_queue.get_nowait()
                except asyncio.QueueEmpty:
                    break
                if update is None:
                    break
                self._collect_updates_non_streaming(
                    update, text_parts, thinking_parts
                )

            result = await prompt_task
            logger.debug("session/prompt result: %s", result)

        finally:
            self._update_queue = None

        # Build the ModelResponse.
        parts: list[ModelResponsePart] = []
        if thinking_parts:
            parts.append(ThinkingPart(content="".join(thinking_parts)))
        parts.append(TextPart(content="".join(text_parts) or ""))

        return ModelResponse(
            parts=parts,
            model_name=self._model_name,
            usage=RequestUsage(),  # ACP doesn't expose token counts.
            provider_name="kiro_acp",
        )

    # -- Streaming request --------------------------------------------------

    @asynccontextmanager
    async def request_stream(
        self,
        messages: list[ModelMessage],
        model_settings: ModelSettings | None,
        model_request_parameters: ModelRequestParameters,
        run_context: RunContext[Any] | None = None,
    ) -> AsyncIterator[StreamedResponse]:
        """Make a streaming request to kiro.

        Returns an async context manager that yields a
        :class:`KiroAcpStreamingResponse`.
        """
        await self._ensure_session()
        assert self._client is not None and self._session_id is not None

        blocks = self._build_prompt_blocks(messages)
        self._update_queue = asyncio.Queue()

        # Fire the prompt — we'll consume updates via the queue.
        prompt_task = asyncio.create_task(
            self._client.call(
                "session/prompt",
                {
                    "sessionId": self._session_id,
                    "prompt": blocks,
                },
                timeout=600.0,
            )
        )

        try:
            yield KiroAcpStreamingResponse(
                model_request_parameters=model_request_parameters,
                _update_queue=self._update_queue,
                _prompt_task=prompt_task,
                _model_name_str=self._model_name,
                _provider_name_str="kiro_acp",
            )
        finally:
            # Ensure the prompt task completes (or is cancelled).
            if not prompt_task.done():
                prompt_task.cancel()
                try:
                    await prompt_task
                except (asyncio.CancelledError, Exception):
                    pass
            self._update_queue = None

    # -- Cancellation & cleanup --------------------------------------------

    async def cancel(self) -> None:
        """Cancel the currently-active prompt, if any."""
        if self._client is not None and self._session_id is not None:
            try:
                self._client.notify(
                    "session/cancel", {"sessionId": self._session_id}
                )
            except Exception as exc:
                logger.warning("Failed to send cancel notification: %s", exc)

    async def aclose(self) -> None:
        """Shut down the AcpClient subprocess.

        NOT a destructor — pydantic-ai may not call it.  The Stage 3
        ``agent_run_end`` callback should trigger this.
        """
        if self._client is not None:
            try:
                await self._client.close()
            except Exception as exc:
                logger.warning("Error closing AcpClient: %s", exc)
            self._client = None
            self._initialized = False

    async def reset_session(self) -> None:
        """Tear down the current session and force re-initialization on
        the next request.

        Call this from an ``agent_reload`` callback to handle code-puppy's
        ``/clear`` command.
        """
        await self.aclose()
        self._session_id = None
        self._session_result = {}
        self._initialized = False


# ---------------------------------------------------------------------------
# Streaming response
# ---------------------------------------------------------------------------


@dataclass
class KiroAcpStreamingResponse(StreamedResponse):
    """Streaming response handler for kiro ACP.

    Reads ``session/update`` notifications from the per-prompt queue and
    yields :class:`ModelResponseStreamEvent`s.
    """

    _update_queue: asyncio.Queue[dict[str, Any] | None]
    _prompt_task: asyncio.Task[Any]
    _model_name_str: str
    _provider_name_str: str = "kiro_acp"
    _provider_url_str: str | None = None
    _timestamp_val: datetime = field(
        default_factory=lambda: datetime.now(timezone.utc)
    )

    async def _get_event_iterator(self) -> AsyncIterator[ModelResponseStreamEvent]:
        """Process session/update notifications and yield streaming events.

        Mirrors the pattern in ``GeminiStreamingResponse._get_event_iterator``:
        read chunks (here: from the update queue) and yield
        ``PartStartEvent`` / ``PartDeltaEvent`` via the parts manager.
        """
        while True:
            # Check if the prompt task has completed.
            prompt_done = self._prompt_task.done()

            try:
                update = self._update_queue.get_nowait()
            except asyncio.QueueEmpty:
                if prompt_done:
                    # Drain any final items that arrived with the prompt result.
                    while True:
                        try:
                            update = self._update_queue.get_nowait()
                        except asyncio.QueueEmpty:
                            break
                        if update is None:
                            break
                        for event in self._process_update(update):
                            yield event
                    break
                # Wait a bit for more updates.
                try:
                    update = await asyncio.wait_for(
                        self._update_queue.get(), timeout=0.1
                    )
                except asyncio.TimeoutError:
                    continue

            if update is None:
                break

            for event in self._process_update(update):
                yield event

        # Wait for the prompt task to fully complete (to propagate exceptions).
        try:
            result = await self._prompt_task
            logger.debug("Streaming prompt result: %s", result)
        except Exception as exc:
            logger.error("Streaming prompt failed: %s", exc)
            raise

    def _process_update(
        self, update: dict[str, Any]
    ) -> Iterator[ModelResponseStreamEvent]:
        """Process a single session/update and yield events via the parts manager.

        This is a synchronous generator so it can be ``yield from``-ed by
        the async ``_get_event_iterator``.
        """
        variant = update.get("sessionUpdate", "")

        if variant == "agent_message_chunk":
            content_block = update.get("content", {})
            text = content_block.get("text", "")
            if text:
                yield from self._parts_manager.handle_text_delta(
                    vendor_part_id=None,
                    content=text,
                )

        elif variant == "agent_thought_chunk":
            content_block = update.get("content", {})
            text = content_block.get("text", "")
            if text:
                yield from self._parts_manager.handle_thinking_delta(
                    vendor_part_id=None,
                    content=text,
                )

        elif variant == "tool_call":
            _emit_tool_visual(update)

        elif variant == "tool_call_update":
            _emit_tool_visual(update)

        elif variant == "plan":
            _emit_tool_visual(update)

        elif variant in ("current_mode_update", "config_option_update"):
            logger.debug("Stream config/mode update: %s", variant)

        elif variant == "user_message_chunk":
            pass  # Ignore replays during session/load.

        else:
            logger.debug("Unknown stream sessionUpdate: %s", variant)

    @property
    def model_name(self) -> str:
        return self._model_name_str

    @property
    def provider_name(self) -> str | None:
        return self._provider_name_str

    @property
    def provider_url(self) -> str | None:
        return self._provider_url_str

    @property
    def timestamp(self) -> datetime:
        return self._timestamp_val
