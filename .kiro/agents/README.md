# `.kiro/agents/` — Custom Kiro agent configs

Project-local Kiro CLI custom agent definitions used by `kiro_cockpit`.
See `plan2.md` §10 ("Kiro custom agent config") for the authoritative schema.

## Agents

| File | Role | Writes? | Shell? | MCP? |
| --- | --- | --- | --- | --- |
| `kiro-cockpit-nano-planner.json` | Read-only planner that drafts approval-gated plans | no | no | no |
| `kiro-cockpit-executor.json` | Executes approved plans; default allowedTools is read-only, `write`/`shell` are approval-gated per turn | yes (with approval) | yes (with approval) | yes |
| `kiro-cockpit-qa-reviewer.json` | Read-only QA reviewer: testability, coverage gaps, acceptance criteria quality (§26.9, Phase 18) | no | no | no |
| `kiro-cockpit-security-reviewer.json` | Read-only security reviewer: injection risks, privilege escalation, data exposure (§26.9, Phase 18) | no | no | no |

Both agents pin `model: "claude-sonnet-4"` per `plan2.md`. Override per-session via the
ACP `session/setModel` request rather than editing these files.

## Prompt files

Both configs reference prompts under `priv/prompts/` via `file://./priv/prompts/...`:

- `priv/prompts/nano_planner_system_prompt.md`
- `priv/prompts/kiro_executor_system_prompt.md`

Those prompt files are produced by the parallel `feature/kiro-q8i-prompts` branch
and will land on `main` as part of the Phase 2 fanout. They are not created here
to avoid merge conflicts.

## Invariants

- Required keys: `name`, `description`, `prompt`, `tools`, `allowedTools`, `includeMcpJson`, `model`.
- `allowedTools` MUST be a subset of `tools`.
- `prompt` MUST use the `file://` scheme and reference `priv/prompts/`.
- No secrets, API keys, or provider credentials in these files — they are committed.

## Validation

Quick JSON parse + invariant check (no Elixir deps required):

```sh
for f in .kiro/agents/*.json; do
  python3 -m json.tool "$f" > /dev/null && echo "ok: $f"
done
```

Deeper structural check (run from the project root):

```sh
python3 - <<'PY'
import json, pathlib
required = {"name","description","prompt","tools","allowedTools","includeMcpJson","model"}
for p in sorted(pathlib.Path(".kiro/agents").glob("*.json")):
    d = json.loads(p.read_text())
    missing = required - set(d)
    assert not missing, f"{p}: missing {missing}"
    extra = set(d["allowedTools"]) - set(d["tools"])
    assert not extra, f"{p}: allowedTools not subset of tools ({extra})"
    assert d["prompt"].startswith("file://") and "priv/prompts/" in d["prompt"], f"{p}: bad prompt path"
    print(f"ok: {p} ({d['name']})")
PY
```

Integration tests covering planner/executor wiring live under `kiro-gq1`.
Reviewer coordination tests live under `test/kiro_cockpit/nano_planner/subagent_coordinator_test.exs`.
