"""Configuration for the kiro_acp code-puppy plugin."""

from __future__ import annotations

import os
import shutil
from pathlib import Path
from typing import Optional

# ---------------------------------------------------------------------------
# Config keys — namespaced under "kiro_acp." so /kiro-uninstall can wipe by prefix
# ---------------------------------------------------------------------------

KIRO_CLI_PATH_KEY: str = "kiro_acp.cli_path"
KIRO_DEFAULT_MODE_KEY: str = "kiro_acp.default_mode"  # "code" or "ask"
KIRO_LOG_LEVEL_KEY: str = "kiro_acp.log_level"  # passes through as KIRO_LOG_LEVEL env var
KIRO_AUTOAPPROVE_FS_READ_KEY: str = "kiro_acp.autoapprove_fs_read"  # bool, default True
KIRO_AUTOAPPROVE_FS_WRITE_KEY: str = "kiro_acp.autoapprove_fs_write"  # bool, default False
KIRO_AUTOAPPROVE_TERMINAL_KEY: str = "kiro_acp.autoapprove_terminal"  # bool, default False
KIRO_PROTOCOL_VERSION: int = 1
KIRO_MODEL_PREFIX: str = "kiro-"  # prefix for models surfaced into EXTRA_MODELS_FILE

DEFAULT_KIRO_CLI_PATHS: list[Path] = [
    Path.home() / ".local" / "bin" / "kiro-cli",
    Path("/usr/local/bin/kiro-cli"),
    Path("/opt/homebrew/bin/kiro-cli"),
]


# ---------------------------------------------------------------------------
# Discovery helpers
# ---------------------------------------------------------------------------


def discover_kiro_cli() -> Optional[Path]:
    """Find the kiro-cli binary.

    Resolution order:
        1. Configured path via KIRO_CLI_PATH_KEY (from code_puppy config)
        2. ``shutil.which('kiro-cli')``
        3. Common install locations

    Returns:
        Absolute Path if found and executable, else None.
    """
    # 1. config-set path
    try:
        from code_puppy.config import get_value

        configured = get_value(KIRO_CLI_PATH_KEY)
        if configured:
            p = Path(configured).expanduser()
            if p.is_file() and os.access(p, os.X_OK):
                return p.resolve()
    except Exception:
        pass

    # 2. PATH lookup
    found = shutil.which("kiro-cli")
    if found:
        return Path(found).resolve()

    # 3. Common locations
    for candidate in DEFAULT_KIRO_CLI_PATHS:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate.resolve()

    return None


# ---------------------------------------------------------------------------
# Read-only config accessors
# ---------------------------------------------------------------------------


def get_log_level() -> Optional[str]:
    """Get configured ``KIRO_LOG_LEVEL`` (debug/info/etc.) for the child process env."""
    try:
        from code_puppy.config import get_value

        return get_value(KIRO_LOG_LEVEL_KEY)  # type: ignore[no-any-return]
    except Exception:
        return None


def get_default_mode() -> str:
    """Default session mode. ``'code'`` = full tools, ``'ask'`` = ask-before-edit."""
    try:
        from code_puppy.config import get_value

        v = get_value(KIRO_DEFAULT_MODE_KEY)
        if v in ("code", "ask"):
            return v  # type: ignore[return-value]
    except Exception:
        pass
    return "code"


def get_autoapprove(key: str, default: bool) -> bool:
    """Read a bool config value with a default fallback."""
    try:
        from code_puppy.config import get_value

        v = get_value(key)
        if v is None:
            return default
        return str(v).lower() in ("true", "1", "yes", "on")
    except Exception:
        return default


def autoapprove_fs_read() -> bool:
    """Whether filesystem reads are auto-approved (default True)."""
    return get_autoapprove(KIRO_AUTOAPPROVE_FS_READ_KEY, True)


def autoapprove_fs_write() -> bool:
    """Whether filesystem writes are auto-approved (default False)."""
    return get_autoapprove(KIRO_AUTOAPPROVE_FS_WRITE_KEY, False)


def autoapprove_terminal() -> bool:
    """Whether terminal commands are auto-approved (default False)."""
    return get_autoapprove(KIRO_AUTOAPPROVE_TERMINAL_KEY, False)


# ---------------------------------------------------------------------------
# Housekeeping
# ---------------------------------------------------------------------------


def get_all_config_keys() -> list[str]:
    """All config keys this plugin owns — used by ``/kiro-uninstall``."""
    return [
        KIRO_CLI_PATH_KEY,
        KIRO_DEFAULT_MODE_KEY,
        KIRO_LOG_LEVEL_KEY,
        KIRO_AUTOAPPROVE_FS_READ_KEY,
        KIRO_AUTOAPPROVE_FS_WRITE_KEY,
        KIRO_AUTOAPPROVE_TERMINAL_KEY,
    ]
