"""Slash-command logic for the kiro_acp plugin.

Pure functions — no callback registration here (that goes in
``register_callbacks.py``).
"""

from __future__ import annotations

import asyncio
import json
import logging
from pathlib import Path
from typing import Any, Optional

from .acp_client import AcpClient, AcpError, AcpRpcError
from .config import (
    KIRO_DEFAULT_MODE_KEY,
    KIRO_MODEL_PREFIX,
    discover_kiro_cli,
    get_all_config_keys,
    get_default_mode,
)

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Help entries
# ---------------------------------------------------------------------------


def custom_help_entries() -> list[tuple[str, str]]:
    """Return ``[(command_name, description), ...]`` for the help menu."""
    return [
        ("kiro-setup", "Discover kiro-cli and import available models"),
        ("kiro-status", "Show kiro-cli status, discovered models, and current mode"),
        ("kiro-mode <ask|code>", "Set the default mode for new kiro sessions"),
        ("kiro-cancel", "Cancel the active kiro session (stub — use Ctrl-C for now)"),
        ("kiro-uninstall", "Remove all kiro_acp plugin state and models"),
    ]


# ---------------------------------------------------------------------------
# Command dispatcher
# ---------------------------------------------------------------------------


def handle_command(command: str, name: str) -> Optional[bool]:
    """Dispatch a slash command.

    Returns ``True`` if the command was handled, ``None`` if it's not ours.
    """
    dispatch = {
        "kiro-setup": _cmd_setup,
        "kiro-status": _cmd_status,
        "kiro-mode": _cmd_mode,
        "kiro-cancel": _cmd_cancel,
        "kiro-uninstall": _cmd_uninstall,
    }

    handler = dispatch.get(name)
    if handler is None:
        return None

    try:
        handler(command)
    except Exception as exc:
        _emit_error(f"Command /{name} failed: {exc}")
    return True


# ---------------------------------------------------------------------------
# Messaging helpers (defensive imports)
# ---------------------------------------------------------------------------


def _emit_info(msg: str) -> None:
    try:
        from code_puppy.messaging import emit_info

        emit_info(msg)
    except Exception:
        logger.info(msg)


def _emit_warning(msg: str) -> None:
    try:
        from code_puppy.messaging import emit_warning

        emit_warning(msg)
    except Exception:
        logger.warning(msg)


def _emit_error(msg: str) -> None:
    try:
        from code_puppy.messaging import emit_error

        emit_error(msg)
    except Exception:
        logger.error(msg)


def _emit_success(msg: str) -> None:
    try:
        from code_puppy.messaging import emit_success

        emit_success(msg)
    except Exception:
        logger.info("SUCCESS: %s", msg)


# ---------------------------------------------------------------------------
# /kiro-setup
# ---------------------------------------------------------------------------


def _cmd_setup(command: str) -> None:
    """Discover kiro-cli and import available models."""
    _emit_info("Running /kiro-setup …")

    cli_path = discover_kiro_cli()
    if cli_path is None:
        _emit_error(
            "kiro-cli not found.  Install it from https://kiro.dev/docs/install "
            "or set `kiro_acp.cli_path` in code-puppy config."
        )
        return

    _emit_info(f"Found kiro-cli at {cli_path}")

    # Run the async discovery logic synchronously.
    try:
        models = _discover_models_sync(cli_path)
    except Exception as exc:
        _emit_error(f"Failed to discover kiro models: {exc}")
        return

    if not models:
        _emit_warning("kiro-cli reported no models.")
        return

    # Write models to EXTRA_MODELS_FILE.
    added = _write_models_to_extra_config(models)
    _emit_success(f"Discovered {added} kiro model(s).  Use code-puppy's model picker to select one.")


def _discover_models_sync(cli_path: Path) -> list[dict[str, Any]]:
    """Spawn a temp AcpClient to introspect available models.

    Returns a list of dicts with keys: ``kiro_id``, ``label``, ``context_length``.
    """
    # If there's already a running event loop (e.g. inside code-puppy's async
    # shell), we need to schedule on it rather than calling asyncio.run().
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        loop = None

    if loop and loop.is_running():
        # We're inside an async context — use nest_asyncio or run in a thread.
        import concurrent.futures

        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            future = pool.submit(asyncio.run, _async_discover(cli_path))
            return future.result(timeout=60)
    else:
        return asyncio.run(_async_discover(cli_path))


async def _async_discover(cli_path: Path) -> list[dict[str, Any]]:
    """Async helper: initialize + session/new → extract models."""
    async with AcpClient(cli_path) as client:
        # initialize
        await client.call(
            "initialize",
            {"protocolVersion": 1},
            timeout=30.0,
        )

        # session/new — grab configOptions
        session = await client.call(
            "session/new",
            {"cwd": str(Path.cwd())},
            timeout=30.0,
        )

    config_options = session.get("configOptions", [])
    models: list[dict[str, Any]] = []

    for opt in config_options:
        if opt.get("id") != "model":
            continue
        options_list = opt.get("options", [])
        for entry in options_list:
            value = entry.get("value", "")
            label = entry.get("label", value)
            # Heuristic: if the label mentions "1M" or "1m", use 1M context.
            ctx_len = 200_000
            label_lower = label.lower()
            if "1m" in label_lower or "1 million" in label_lower:
                ctx_len = 1_000_000
            # If the entry itself provides context_length, prefer that.
            if "contextLength" in entry:
                ctx_len = int(entry["contextLength"])
            elif "context_length" in entry:
                ctx_len = int(entry["context_length"])
            models.append(
                {
                    "kiro_id": value,
                    "label": label,
                    "context_length": ctx_len,
                }
            )

    return models


def _write_models_to_extra_config(models: list[dict[str, Any]]) -> int:
    """Write kiro models to code-puppy's ``extra_models.json``.

    Returns the number of models added.
    """
    from code_puppy.config import EXTRA_MODELS_FILE

    extra_path = Path(EXTRA_MODELS_FILE)
    existing: dict[str, Any] = {}
    if extra_path.exists():
        try:
            existing = json.loads(extra_path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            existing = {}

    # Remove any previous kiro models (idempotent re-run).
    to_remove = [k for k, v in existing.items() if v.get("type") == "kiro_acp"]
    for k in to_remove:
        del existing[k]

    added = 0
    for m in models:
        kiro_id = m["kiro_id"]
        key = f"{KIRO_MODEL_PREFIX}{kiro_id}"
        existing[key] = {
            "type": "kiro_acp",
            "name": kiro_id,
            "context_length": m["context_length"],
            "supported_settings": [],
        }
        added += 1

    extra_path.parent.mkdir(parents=True, exist_ok=True)
    extra_path.write_text(
        json.dumps(existing, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )

    # Bust the model cache so code-puppy sees the new models.
    try:
        from code_puppy.config import clear_model_cache

        clear_model_cache()
    except Exception:
        pass

    return added


# ---------------------------------------------------------------------------
# /kiro-status
# ---------------------------------------------------------------------------


def _cmd_status(command: str) -> None:
    """Print current kiro status."""
    cli_path = discover_kiro_cli()
    if cli_path is None:
        _emit_warning("kiro-cli: NOT FOUND")
    else:
        _emit_info(f"kiro-cli path: {cli_path}")

    # Best-effort version probe.
    if cli_path is not None:
        try:
            version = _probe_version(cli_path)
            _emit_info(f"kiro-cli version: {version}")
        except Exception as exc:
            _emit_warning(f"Could not determine kiro-cli version: {exc}")

    # Count discovered models.
    from code_puppy.config import EXTRA_MODELS_FILE

    count = 0
    extra_path = Path(EXTRA_MODELS_FILE)
    if extra_path.exists():
        try:
            data = json.loads(extra_path.read_text(encoding="utf-8"))
            count = sum(
                1 for v in data.values() if v.get("type") == "kiro_acp"
            )
        except Exception:
            pass
    _emit_info(f"Discovered kiro models: {count}")

    # Current mode.
    mode = get_default_mode()
    _emit_info(f"Default mode: {mode}")

    # Current model (if it's a kiro model).
    try:
        from code_puppy.config import get_global_model_name

        current = get_global_model_name() or ""
        if current.startswith(KIRO_MODEL_PREFIX):
            _emit_info(f"Active kiro model: {current}")
        else:
            _emit_info(f"Active model: {current} (not a kiro model)")
    except Exception:
        pass


def _probe_version(cli_path: Path) -> str:
    """Quick initialize to read ``agentInfo.version``."""
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        loop = None

    def _do_probe() -> str:
        async def _inner() -> str:
            async with AcpClient(cli_path) as client:
                result = await client.call(
                    "initialize", {"protocolVersion": 1}, timeout=10.0
                )
                info = result.get("agentInfo", {})
                return info.get("version", "unknown")

        return asyncio.run(_inner())

    if loop and loop.is_running():
        import concurrent.futures

        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            return pool.submit(_do_probe).result(timeout=20)
    else:
        return _do_probe()


# ---------------------------------------------------------------------------
# /kiro-mode
# ---------------------------------------------------------------------------


def _cmd_mode(command: str) -> None:
    """Set the default mode for new kiro sessions."""
    parts = command.strip().split(None, 1)
    if len(parts) < 2:
        _emit_error("Usage: /kiro-mode <ask|code>")
        return

    arg = parts[1].strip().lower()
    if arg not in ("ask", "code"):
        _emit_error(f"Invalid mode '{arg}'.  Must be 'ask' or 'code'.")
        return

    try:
        from code_puppy.config import set_value

        set_value(KIRO_DEFAULT_MODE_KEY, arg)
        _emit_success(f"Default kiro mode set to '{arg}'.")
        _emit_info("Note: this affects new sessions, not the currently-active one.")
    except Exception as exc:
        _emit_error(f"Failed to set mode: {exc}")


# ---------------------------------------------------------------------------
# /kiro-cancel
# ---------------------------------------------------------------------------


def _cmd_cancel(command: str) -> None:
    """Stub — cancellation not yet implemented."""
    _emit_info(
        "Cancellation not yet implemented — Ctrl-C cancels at the agent layer instead."
    )


# ---------------------------------------------------------------------------
# /kiro-uninstall
# ---------------------------------------------------------------------------


def _cmd_uninstall(command: str) -> None:
    """Remove all kiro_acp plugin state and imported models."""
    _emit_info("Running /kiro-uninstall …")

    # Step 1: If the active model is a kiro model, switch to a sane default.
    try:
        from code_puppy.config import get_global_model_name

        active = get_global_model_name() or ""
        if active.startswith(KIRO_MODEL_PREFIX):
            # Try to find a reasonable fallback.
            fallback = _pick_fallback_model()
            _emit_info(
                f"Switching from {active} to {fallback} …"
            )
            from code_puppy.model_switching import set_model_and_reload_agent

            set_model_and_reload_agent(fallback)
    except Exception as exc:
        _emit_warning(f"Could not switch away from kiro model: {exc}")

    # Step 2: Remove kiro models from extra_models.json.
    try:
        from code_puppy.config import EXTRA_MODELS_FILE

        extra_path = Path(EXTRA_MODELS_FILE)
        if extra_path.exists():
            data = json.loads(extra_path.read_text(encoding="utf-8"))
            to_remove = [
                k for k, v in data.items() if v.get("type") == "kiro_acp"
            ]
            for k in to_remove:
                del data[k]
            extra_path.write_text(
                json.dumps(data, indent=2, ensure_ascii=False) + "\n",
                encoding="utf-8",
            )
            if to_remove:
                _emit_info(f"Removed {len(to_remove)} kiro model(s) from configuration.")
            try:
                from code_puppy.config import clear_model_cache

                clear_model_cache()
            except Exception:
                pass
    except Exception as exc:
        _emit_warning(f"Error removing kiro models: {exc}")

    # Step 3: Reset all config keys.
    try:
        from code_puppy.config import reset_value

        for key in get_all_config_keys():
            try:
                reset_value(key)
            except Exception:
                pass
        _emit_info("Reset all kiro_acp config keys.")
    except Exception as exc:
        _emit_warning(f"Error resetting config: {exc}")

    _emit_success(
        "kiro_acp plugin state cleaned.  To finish removal: "
        "rm -rf ~/.code_puppy/plugins/kiro_acp"
    )


def _pick_fallback_model() -> str:
    """Pick a sensible model to switch to after uninstalling kiro."""
    # Try a few well-known models in preference order.
    candidates = [
        "claude-4-0-sonnet",
        "claude-sonnet-4-6",
        "gpt-4.1",
    ]
    try:
        from code_puppy.model_factory import ModelFactory

        config = ModelFactory.load_config()
        for c in candidates:
            if c in config:
                return c
    except Exception:
        pass
    return candidates[0]
