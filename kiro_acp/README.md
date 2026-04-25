# kiro_acp — Kiro ACP Plugin for Code Puppy

Talk to **kiro-cli acp** (Kiro CLI in Agent Client Protocol mode) as if it were a
native code-puppy model backend. The plugin spawns `kiro-cli acp` as a subprocess
and proxies JSON-RPC 2.0 over stdio with newline-delimited framing.

## How it works

**Strategy A: Sealed agent wrapper.** Code-puppy owns the UI, safety layer, and
tool routing. `kiro-cli` runs as an isolated agent subprocess whose `fs/*` and
`terminal/*` callbacks are routed through code-puppy's existing tools and safety
plugins. You get Kiro's model options and agentic reasoning inside code-puppy's
TUI.

## Model name pattern

Models surface as `kiro-<upstream-model>`, for example:

| kiro-cli model | code-puppy name |
|----------------|-----------------|
| `claude-sonnet-4-6` | `kiro-claude-sonnet-4-6` |
| `claude-opus-4-7` | `kiro-claude-opus-4-7` |

Pick them from code-puppy's normal model picker after running `/kiro-setup`.

## Requirements

- **kiro-cli** must already be installed separately. See https://kiro.dev/docs/cli/
- Python 3.11+

## Installation

See [INSTALL.md](INSTALL.md) for detailed steps.

TL;DR:

```bash
# Symlink (preferred) or copy
ln -s /Users/adam2/projects/kiro/kiro_acp ~/.code_puppy/plugins/kiro_acp
# Restart code-puppy, then:
/kiro-setup
```

## Quickstart

1. Start code-puppy.
2. Run `/kiro-setup` — discovers installed `kiro-cli` and enumerates available models.
3. Pick a `kiro-*` model from the model picker.
4. Use code-puppy normally. Prompts go to Kiro; Kiro's tool calls route through
   code-puppy's safety layer.

## Removal

```bash
/kiro-uninstall          # wipes plugin config keys
rm -rf ~/.code_puppy/plugins/kiro_acp
```

## Architecture note

`kiro-cli` runs as a child process. When the Kiro agent requests filesystem or
terminal operations (`fs/read_text_file`, `terminal/create`, etc.), those requests
are routed through code-puppy's existing tool implementations and safety plugins.
This means all Kiro activity respects your code-puppy permission settings.

## Plugin files

| File | Purpose |
|------|---------|
| `__init__.py` | Package marker + version |
| `config.py` | Configuration helpers (CLI discovery, auto-approve settings) |
| `acp_client.py` | Low-level async JSON-RPC 2.0 stdio transport |
| `register_callbacks.py` | *(Stage 2+)* code-puppy callback registration |
