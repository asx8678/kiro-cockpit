# Installing kiro_acp

## Prerequisites

### 1. Verify kiro-cli is installed

```bash
which kiro-cli
```

If this prints nothing, install kiro-cli first:
<https://kiro.dev/docs/cli/>

### 2. Verify code-puppy is installed and working

You should be able to start code-puppy and use `/help` without errors.

## Install the plugin

### Option A: Symlink (recommended — picks up edits instantly)

```bash
mkdir -p ~/.code_puppy/plugins
ln -s /Users/adam2/projects/kiro/kiro_acp ~/.code_puppy/plugins/kiro_acp
```

### Option B: Copy

```bash
mkdir -p ~/.code_puppy/plugins
cp -r /Users/adam2/projects/kiro/kiro_acp ~/.code_puppy/plugins/kiro_acp
```

> With Option B you'll need to re-copy after any changes.

## Activate

1. Restart code-puppy (exit and relaunch).
2. Run `/kiro-setup` inside code-puppy.
   - This discovers the `kiro-cli` binary and enumerates available models.
   - Models are written to your `extra_models` config with the `kiro-` prefix.
3. Switch to a kiro model:
   - Use the model picker, or
   - Run `/model kiro-claude-sonnet-4-6` (or whichever model you prefer).

## Verify

After switching, send a test prompt. You should see Kiro respond through
code-puppy's TUI.

## Uninstall

```bash
# Inside code-puppy:
/kiro-uninstall           # removes plugin config keys

# In your shell:
rm -rf ~/.code_puppy/plugins/kiro_acp
```

Then restart code-puppy.
