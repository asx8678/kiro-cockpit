# Kiro ACP — Build-Your-Own-Client Reference

A practical, end-to-end reference for talking to **Kiro CLI** over the **Agent Client Protocol (ACP)** — written for someone building a terminal UI / custom client on top of it.

---

## 1. Mental model

- **Agent** = `kiro-cli acp` (subprocess you spawn).
- **Client** = your terminal app (the UI, the editor surface, the file/terminal provider).
- Wire = **JSON-RPC 2.0** over **stdio**, **newline-delimited** (one JSON object per line, no Content-Length headers, no embedded newlines).
- Two message kinds:
  - **Methods** — have an `id`, expect a `result` or `error`. Bi-directional.
  - **Notifications** — no `id`, no response. One-way.
- Direction is bi-directional: the **agent calls back into the client** for filesystem and terminal access (that's why your app is the "client", even though it has the UI).
- Path rule: **all paths in the protocol MUST be absolute**. Line numbers are **1-based**.

---

## 2. Spawn Kiro

```bash
which kiro-cli                 # use absolute path in code
kiro-cli acp                   # default agent
kiro-cli acp --agent my-agent  # named custom agent
```

Spawn with stdio piped:

```ts
import { spawn } from "node:child_process";
const kiro = spawn("/Users/<you>/.local/bin/kiro-cli", ["acp"], {
  stdio: ["pipe", "pipe", "inherit"], // stderr stays in your terminal
});
```

Then frame messages as **one JSON object per line** on stdin/stdout. Agents may write diagnostics to stderr — leave it inheriting or capture separately.

Logs (useful while developing):
- macOS: `$TMPDIR/kiro-log/kiro-chat.log`
- Linux: `$XDG_RUNTIME_DIR/kiro-log/kiro-chat.log`
- Verbosity: `KIRO_LOG_LEVEL=debug kiro-cli acp`
- Override file: `KIRO_CHAT_LOG_FILE=/path/to/x.log`

Sessions persist under `~/.kiro/sessions/cli/<session-id>.{json,jsonl}`.

---

## 3. Lifecycle at a glance

```
client ──► initialize                    ──► agent
client ◄── initialize result              ◄── agent
client ──► (authenticate, if needed)     ──► agent
client ──► session/new   OR  session/load ──► agent
client ◄── { sessionId, modes?, configOptions? }

loop:
  client ──► session/prompt
  client ◄── session/update (many)        // streaming
  client ──► fs/* or terminal/* on demand // agent calls back
  client ◄── session/prompt result        // { stopReason }
```

---

## 4. Initialize

**Client → Agent**

```json
{
  "jsonrpc": "2.0",
  "id": 0,
  "method": "initialize",
  "params": {
    "protocolVersion": 1,
    "clientCapabilities": {
      "fs":       { "readTextFile": true, "writeTextFile": true },
      "terminal": true
    },
    "clientInfo": { "name": "my-term-client", "title": "My Term", "version": "0.1.0" }
  }
}
```

**Agent → Client (Kiro)**

```json
{
  "jsonrpc": "2.0",
  "id": 0,
  "result": {
    "protocolVersion": 1,
    "agentCapabilities": {
      "loadSession": true,
      "promptCapabilities": { "image": true, "audio": true, "embeddedContext": true },
      "mcpCapabilities":    { "http": true, "sse": true }
    },
    "agentInfo": { "name": "kiro-cli", "version": "1.5.0" },
    "authMethods": []
  }
}
```

### What the capabilities mean for your UI

| Capability                          | Implication for the client                                                     |
| ----------------------------------- | ------------------------------------------------------------------------------ |
| `clientCapabilities.fs.read…`       | You **must** implement `fs/read_text_file` if you advertise it                 |
| `clientCapabilities.fs.write…`      | You **must** implement `fs/write_text_file` if you advertise it                |
| `clientCapabilities.terminal`       | You **must** implement all `terminal/*` methods if true                        |
| `agentCapabilities.loadSession`     | You can resume sessions via `session/load`                                     |
| `promptCapabilities.image/audio/…`  | You may include those content blocks in `session/prompt`; otherwise text only  |

**Version negotiation**: the integer is a single MAJOR version. If the agent answers with a version you don't support, disconnect.

---

## 5. Create / load a session

### `session/new`

```json
{
  "jsonrpc": "2.0", "id": 1, "method": "session/new",
  "params": {
    "cwd": "/Users/me/code/proj",
    "mcpServers": [
      { "name": "filesystem",
        "command": "/path/to/mcp-server",
        "args": ["--stdio"], "env": [] }
    ]
  }
}
```

**Result** — note the modes/configOptions blocks (this is where models surface):

```json
{
  "jsonrpc": "2.0", "id": 1,
  "result": {
    "sessionId": "sess_abc123",
    "modes": {
      "currentModeId": "code",
      "availableModes": [
        { "id": "ask",  "name": "Ask",  "description": "Ask before editing" },
        { "id": "code", "name": "Code", "description": "Write/modify with full tools" }
      ]
    },
    "configOptions": [
      {
        "id": "model", "name": "Model", "category": "model", "type": "select",
        "currentValue": "claude-sonnet-4-6",
        "options": [
          { "value": "claude-sonnet-4-6", "name": "Sonnet 4.6", "description": "Balanced" },
          { "value": "claude-opus-4-7",   "name": "Opus 4.7",   "description": "Most capable" }
        ]
      }
    ]
  }
}
```

> Modes and configOptions are optional — Kiro returns whichever it has. Read both from this response and render UI from them.

### `session/load`

Same params plus `sessionId`. Result is `null`, but the agent **streams the prior conversation back via `session/update`** notifications first. So your UI must already be listening.

---

## 6. Models — how to request, switch, and react to changes

Models in ACP are exposed as **config options** with `category: "model"`. There are two operations:

### Switch model (Client → Agent)

```json
{
  "jsonrpc": "2.0", "id": 7, "method": "session/set_config_option",
  "params": {
    "sessionId": "sess_abc123",
    "configId":  "model",
    "value":     "claude-opus-4-7"
  }
}
```

The agent responds with the **complete updated config state**.

### Agent-pushed change (Agent → Client notification)

The agent can flip the model on its own (rate limit, error fallback) and tells you via:

```json
{
  "jsonrpc": "2.0", "method": "session/update",
  "params": {
    "sessionId": "sess_abc123",
    "update": {
      "sessionUpdate": "config_option_update",
      "configOptions": [ /* full updated array */ ]
    }
  }
}
```

Your UI should re-render the model picker from the latest array — don't assume your local copy is authoritative.

> Kiro also exposes a legacy-style `session/set_model` shortcut (mentioned in Kiro's own docs). Prefer `session/set_config_option` — it's the spec-blessed path and works for any future config category.

---

## 7. Modes (a separate concept from models)

Mode = the **behavior profile** (e.g. ask vs code).

### Switch mode

```json
{
  "jsonrpc": "2.0", "id": 8, "method": "session/set_mode",
  "params": { "sessionId": "sess_abc123", "modeId": "code" }
}
```

### Agent-pushed mode change

```json
{
  "jsonrpc": "2.0", "method": "session/update",
  "params": {
    "sessionId": "sess_abc123",
    "update": { "sessionUpdate": "current_mode_update", "modeId": "code" }
  }
}
```

---

## 8. Sending a prompt

```json
{
  "jsonrpc": "2.0", "id": 9, "method": "session/prompt",
  "params": {
    "sessionId": "sess_abc123",
    "prompt": [
      { "type": "text", "text": "Explain main.py" },
      { "type": "resource_link",
        "resourceLink": { "uri": "file:///Users/me/code/proj/main.py", "mimeType": "text/x-python" } }
    ]
  }
}
```

### All content block types

| `type`           | Allowed when                                  | Shape (key fields)                                  |
| ---------------- | --------------------------------------------- | --------------------------------------------------- |
| `text`           | always                                        | `text`                                              |
| `resource_link`  | always                                        | `resourceLink.{uri, mimeType}`                      |
| `image`          | `promptCapabilities.image`                    | `image.{uri, mimeType}` (data: URI ok)              |
| `audio`          | `promptCapabilities.audio`                    | `audio.{uri, mimeType}`                             |
| `resource`       | `promptCapabilities.embeddedContext`          | `resource.{uri, mimeType, text}` (inline contents)  |

Don't send a block whose capability the agent didn't advertise.

### What the agent streams back (`session/update`)

Each notification has `params.update.sessionUpdate` discriminating the variant:

| `sessionUpdate`         | Use it for                                                              |
| ----------------------- | ----------------------------------------------------------------------- |
| `agent_message_chunk`   | Stream assistant text into your transcript pane                         |
| `agent_thought_chunk`   | (Optional) reasoning/thought stream                                     |
| `user_message_chunk`    | Echoes user content (mostly during `session/load` replay)               |
| `tool_call`             | Render a new tool-call card (id, title, kind, status: `pending`)        |
| `tool_call_update`      | Update an existing tool-call (status → `in_progress`/`completed`, content) |
| `plan`                  | Render the agent's TODO plan (entries with priority/status)             |
| `current_mode_update`   | Mode changed (see §7)                                                   |
| `config_option_update`  | Model or other config changed (see §6)                                  |

`tool_call_update` example with output:

```json
{
  "jsonrpc": "2.0", "method": "session/update",
  "params": {
    "sessionId": "sess_abc123",
    "update": {
      "sessionUpdate": "tool_call_update",
      "toolCallId": "call_001",
      "status": "completed",
      "content": [
        { "type": "content", "content": { "type": "text", "text": "tool output…" } }
      ]
    }
  }
}
```

### Final response

```json
{ "jsonrpc": "2.0", "id": 9, "result": { "stopReason": "end_turn" } }
```

`stopReason` ∈ `end_turn` · `max_tokens` · `max_turn_requests` · `refusal` · `cancelled`.

### Cancellation

Send a notification (no id):

```json
{ "jsonrpc": "2.0", "method": "session/cancel",
  "params": { "sessionId": "sess_abc123" } }
```

Then in your UI:
- Mark all in-flight tool calls you're rendering as `cancelled` immediately.
- If you have any pending permission prompts, resolve them with `cancelled`.
- Wait for the original `session/prompt` response — it will come back with `stopReason: "cancelled"`.

---

## 9. Agent → Client callbacks (you implement these)

These come **into your stdin** because the agent needs the editor (you) to do them.

### `fs/read_text_file`

```json
// agent → client
{ "jsonrpc": "2.0", "id": 42, "method": "fs/read_text_file",
  "params": { "sessionId": "sess_abc123",
              "path": "/abs/path/main.py",
              "line": 10, "limit": 50 } }
// client → agent
{ "jsonrpc": "2.0", "id": 42,
  "result": { "content": "def hello():\n    ...\n" } }
```

`line`/`limit` are optional. Return the buffer including unsaved edits if your UI has them.

### `fs/write_text_file`

```json
{ "jsonrpc": "2.0", "id": 43, "method": "fs/write_text_file",
  "params": { "sessionId": "sess_abc123",
              "path": "/abs/path/config.json",
              "content": "{\n  \"x\": 1\n}" } }
// → result: null
```

Create the file if it doesn't exist.

### `terminal/*` (only if you set `clientCapabilities.terminal: true`)

Lifecycle: **create → poll output / wait_for_exit → release**. `kill` is optional.

| Method                  | Purpose                                                  | Returns                                       |
| ----------------------- | -------------------------------------------------------- | --------------------------------------------- |
| `terminal/create`       | Start a command, return immediately                      | `{ terminalId }`                              |
| `terminal/output`       | Snapshot output so far (non-blocking)                    | `{ output, truncated, exitStatus? }`          |
| `terminal/wait_for_exit`| Block until the command exits                            | `{ exitCode, signal }`                        |
| `terminal/kill`         | SIGKILL the process; terminal stays valid for output     | `null`                                        |
| `terminal/release`      | Kill if running AND free the terminal id                 | `null`                                        |

`create` request:

```json
{ "jsonrpc": "2.0", "id": 50, "method": "terminal/create",
  "params": {
    "sessionId": "sess_abc123",
    "command": "npm",
    "args": ["test", "--coverage"],
    "env":  [{"name":"NODE_ENV","value":"test"}],
    "cwd":  "/abs/path/proj",
    "outputByteLimit": 1048576
  } }
```

**Important**: you must always `terminal/release` eventually, even after `kill`. Terminal IDs may be embedded in `tool_call` updates so the user sees live output — keep showing buffered output even after release.

---

## 10. Kiro-specific extensions (`_kiro.dev/`)

These are non-spec but Kiro emits/accepts them. Useful for parity with Kiro's own UI.

**Slash commands**
- `_kiro.dev/commands/available` — list slash commands
- `_kiro.dev/commands/options` — autocomplete suggestions
- `_kiro.dev/commands/execute` — run one

**MCP**
- `_kiro.dev/mcp/oauth_request` — agent needs an OAuth flow; surface a link/UI
- `_kiro.dev/mcp/server_initialized` — MCP server ready

**Sessions**
- `_kiro.dev/compaction/status` — context compaction progress (show a spinner)
- `_kiro.dev/clear/status` — `/clear` progress
- `_session/terminate` — terminate a subagent session

If you don't recognize a method or `sessionUpdate` variant, **ignore it** — the spec is designed so unknown extensions aren't breaking.

---

## 11. Minimal Node skeleton

```ts
import { spawn } from "node:child_process";
import * as readline from "node:readline";

const proc = spawn("/Users/me/.local/bin/kiro-cli", ["acp"]);
const rl = readline.createInterface({ input: proc.stdout });

let nextId = 1;
const pending = new Map<number, (msg: any) => void>();

function send(method: string, params: any, id?: number) {
  const msg: any = { jsonrpc: "2.0", method, params };
  if (id !== undefined) msg.id = id;
  proc.stdin.write(JSON.stringify(msg) + "\n");
}
function call(method: string, params: any) {
  const id = nextId++;
  return new Promise<any>((resolve) => {
    pending.set(id, resolve);
    send(method, params, id);
  });
}

rl.on("line", async (line) => {
  const msg = JSON.parse(line);

  // 1) responses to our requests
  if (msg.id !== undefined && (msg.result !== undefined || msg.error)) {
    pending.get(msg.id)?.(msg);
    pending.delete(msg.id);
    return;
  }

  // 2) requests FROM the agent (fs/*, terminal/*)
  if (msg.id !== undefined && msg.method) {
    const result = await handleAgentRequest(msg.method, msg.params);
    proc.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: msg.id, result }) + "\n");
    return;
  }

  // 3) notifications (session/update etc.)
  handleNotification(msg.method, msg.params);
});

// boot
const init = await call("initialize", {
  protocolVersion: 1,
  clientCapabilities: { fs: { readTextFile: true, writeTextFile: true }, terminal: true },
  clientInfo: { name: "my-term", version: "0.1.0" },
});

const sess = await call("session/new", { cwd: process.cwd(), mcpServers: [] });
const sessionId = sess.result.sessionId;

await call("session/prompt", {
  sessionId,
  prompt: [{ type: "text", text: "Hello Kiro" }],
});
```

`handleAgentRequest` dispatches `fs/read_text_file`, `fs/write_text_file`, `terminal/*`. `handleNotification` switches on `params.update.sessionUpdate` and updates your TUI state.

---

## 12. Editor configs (if you also want to test against existing clients)

### Zed — `~/.config/zed/settings.json`

```json
{
  "agent_servers": {
    "Kiro Agent": {
      "type": "custom",
      "command": "/Users/me/.local/bin/kiro-cli",
      "args": ["acp"],
      "env": {}
    }
  }
}
```

### JetBrains — `~/.jetbrains/acp.json`

```json
{
  "agent_servers": {
    "Kiro Agent": { "command": "/full/path/to/kiro-cli", "args": ["acp"] }
  }
}
```

### VS Code

Use a community ACP client (e.g. `vscode-acp-kiro`) and point its `command` at your `kiro-cli` path.

---

## 13. Gotchas

- **Always send absolute paths.** Relative paths are spec-illegal.
- **Don't embed `\n` in a JSON-RPC line.** One object, one line.
- **Use full path to `kiro-cli`** in editor configs — IDEs don't inherit shell `PATH`.
- **Don't advertise a capability you don't implement.** If you set `terminal: true`, the agent will call `terminal/*` and hang waiting for you.
- **Cancellation is async.** Stop rendering live updates immediately, but the `stopReason: "cancelled"` arrives later.
- **Treat config/model state as agent-authoritative** — re-read from `config_option_update` instead of caching.
- **Ignore unknown `sessionUpdate` variants and `_kiro.dev/*` methods** if you don't handle them — extensibility is non-breaking by design.

---

## 14. References

- Kiro ACP overview: https://kiro.dev/docs/cli/acp/
- Kiro custom agents: https://kiro.dev/docs/cli/custom-agents/configuration-reference/
- Kiro adopts ACP (blog): https://kiro.dev/blog/kiro-adopts-acp/
- ACP spec index: https://agentclientprotocol.com/llms.txt
- ACP overview: https://agentclientprotocol.com/protocol/overview.md
- Transports / framing: https://agentclientprotocol.com/protocol/transports.md
- Initialization: https://agentclientprotocol.com/protocol/initialization.md
- Session setup: https://agentclientprotocol.com/protocol/session-setup.md
- Prompt turn: https://agentclientprotocol.com/protocol/prompt-turn.md
- Session modes: https://agentclientprotocol.com/protocol/session-modes.md
- Session config (models): https://agentclientprotocol.com/protocol/session-config-options.md
- Filesystem: https://agentclientprotocol.com/protocol/file-system.md
- Terminals: https://agentclientprotocol.com/protocol/terminals.md
