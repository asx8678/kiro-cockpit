"""kiro_acp plugin entry point — registers all callbacks with code-puppy.

Mirrors the structure of ``claude_code_oauth/register_callbacks.py``.
All callback functions are registered at import time via
``register_callback()``.
"""

from __future__ import annotations

import logging
from typing import Any, Dict, List, Optional, Tuple

from code_puppy.callbacks import register_callback

from .commands import custom_help_entries, handle_command
from .kiro_model import KiroAcpModel

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Callback wrappers (match the signatures code-puppy expects)
# ---------------------------------------------------------------------------


def _custom_help() -> List[Tuple[str, str]]:
    """Return help entries for kiro slash commands."""
    return custom_help_entries()


def _handle_custom_command(command: str, name: str) -> Optional[bool]:
    """Dispatch a slash command if it belongs to kiro_acp."""
    return handle_command(command, name)


def _register_model_providers() -> Dict[str, type]:
    """Tell code-puppy that ``type: kiro_acp`` models map to KiroAcpModel."""
    return {"kiro_acp": KiroAcpModel}


# ---------------------------------------------------------------------------
# Registration — executed at import time
# ---------------------------------------------------------------------------

register_callback("custom_command_help", _custom_help)
register_callback("custom_command", _handle_custom_command)
register_callback("register_model_providers", _register_model_providers)


# ---------------------------------------------------------------------------
# Cleanup note
# ---------------------------------------------------------------------------

# In v1, KiroAcpModel.aclose() is best-effort: the AcpClient subprocess is
# reaped by the OS on process exit, and AcpClient has atexit-style cleanup
# in its close() method.  A future stage could wire an ``agent_run_end``
# callback that tracks live KiroAcpModel instances and closes them.  For now
# the tradeoff is acceptable — no lingering processes have been observed in
# manual testing because kiro-cli exits when stdin is closed.
