# Agent integrations

Meanwhile supports **Claude Code, Codex and Cursor** at launch. All three expose lifecycle hooks: shell commands that receive JSON on stdin. Meanwhile registers the same small program, `meanwhile-hook`, for each relevant event and normalizes the payloads in the app.

Facts checked on 2026-10-16 against:
- [Claude Code hooks](https://code.claude.com/docs/en/hooks)
- [Codex hooks](https://learn.chatgpt.com/docs/hooks)
- [Cursor hooks](https://cursor.com/docs/agent/hooks)

Items marked **Verify** must be tested against a real install.

## Where hooks are configured

| Agent | User-level config | Project-level | Notes |
|---|---|---|---|
| Claude Code | `~/.claude/settings.json` (`hooks` key) | `.claude/settings.json`, `.claude/settings.local.json` | Supports `"async": true` (run in background, no wait) and `type: "http"` hooks |
| Codex | `~/.codex/hooks.json` or `[hooks]` in `~/.codex/config.toml` | `<repo>/.codex/hooks.json` (only when the project layer is trusted) | Hooks are on by default. **New or changed hooks are skipped until the user trusts them with `/hooks`**, and trust is tied to the hook's hash. |
| Cursor | `~/.cursor/hooks.json` | `<repo>/.cursor/hooks.json` | `{"version": 1, "hooks": {"<event>": [{"command": "…"}]}}` |

Meanwhile installs at **user level** so it works in every repo. Each repo is still turned on separately inside the app.

**Installer rules:**
- Back up the file.
- Merge without overwriting the user's other hooks.
- Show the change.
- Keep a clean uninstall path.

**Codex trust step:** after installing, the app tells the user to run `/hooks` in Codex and trust Meanwhile's entries, then checks that events arrive.

## Shared event schema

Adapters turn each payload into:

```json
{
  "v": 1,
  "agent": "claude | codex | cursor",
  "session": "string",
  "turn": "string | null",
  "ts": "2026-10-16T14:02:11Z",
  "cwd": "/path/to/repo",
  "kind": "session.start | turn.start | tool.read | tool.edit | tool.exec | tool.web | agent.thought | turn.end | needs.input | session.end",
  "data": { },
  "transcript": "path or null",
  "term": { "program": "iTerm.app", "tty": "/dev/ttys004" }
}
```

## Event mapping

| Kind | Claude Code | Codex | Cursor |
|---|---|---|---|
| `session.start` / `session.end` | `SessionStart` / `SessionEnd` | `SessionStart` / `SessionEnd` | `sessionStart` / `sessionEnd` |
| `turn.start` | `UserPromptSubmit` (`prompt`) | `UserPromptSubmit` | `beforeSubmitPrompt` |
| `tool.read` | `PostToolUse` on `Read` (`tool_input.file_path`, `offset`, `limit`) | `PostToolUse` on shell reads; parse the command. **Verify** the tool names. | `postToolUse`. Avoid `beforeReadFile`, which is a permission hook that can block. |
| `tool.edit` | `PostToolUse` on `Edit` (`old_string`, `new_string`) and `Write` (`content`) | `PostToolUse` on the patch tool (`tool_input`). **Verify** the tool name and patch format. | `afterFileEdit` (`file_path`, `edits[]` with `old_string` / `new_string`) |
| `tool.exec` | `PostToolUse` on `Bash` (`tool_response.stdout` / `stderr`) | `PostToolUse` on shell | `afterShellExecution` |
| `tool.web` | `PostToolUse` on `WebSearch` / `WebFetch`. **Verify** the `tool_response` shape, which is not documented. | **Not hookable**: hosted web search skips tool hooks. Read it from the transcript. | **No documented hook**. Read it from the transcript. |
| `agent.thought` | Transcript (assistant text near each edit) | Transcript | `afterAgentThought` (`text`), `afterAgentResponse` (`text`) |
| `turn.end` | `Stop` (`last_assistant_message`), `StopFailure` | `Stop` (`last_assistant_message`, `turn_id`) | `stop` |
| `needs.input` | `Notification` (`notification_type`: `permission_prompt`, `idle_prompt`, `elicitation_dialog`), `PermissionRequest` | `PermissionRequest` | No clear signal. **Verify** whether `preToolUse` or another event can stand in. |

**Common fields used:**
- **Claude Code:** `session_id`, `transcript_path`, `cwd`, `hook_event_name`, `prompt_id`; tool events add `tool_name`, `tool_input`, `tool_response`, `tool_use_id`, `duration_ms`.
- **Codex:** `session_id`, `transcript_path`, `cwd`, `hook_event_name`, `model`; turn events add `turn_id`.
- **Cursor:** `conversation_id`, `generation_id`, `transcript_path` (null when transcripts are off), `workspace_roots`.

## Never block the agent

- **Claude Code:** register every Meanwhile hook with `"async": true`.
- **Codex and Cursor:** there is no documented async flag. `meanwhile-hook` returns in milliseconds, with exit code 0 and empty stdout, so it is never read as a decision.
- **Permission-style hooks:** Meanwhile never registers them (Cursor `beforeReadFile`, `beforeShellExecution`; any `PreToolUse`). An empty or invalid response there could block or change the agent.
- **If the socket is down:** the hook writes to the spool file and exits. It never retries inline.

## Gaps and how we fill them

| Gap | Fill |
|---|---|
| Web search on Codex and Cursor | **Transcript tailer:** watch `transcript_path` files and pick out web results. Formats are internal and can change between releases, so parsers are versioned per agent and fail quietly (the research deck just shows less). |
| Claude Code `WebSearch` / `WebFetch` response shape | Capture real payloads in the prototype, then pin a parser. Fall back to the transcript. |
| "Needs input" on Cursor | Fall back to a timeout: no events for N seconds during a turn means it's probably waiting. Hide questions then. |
| Cursor with transcripts turned off | Hooks alone still give prompt, edits, thoughts and stop. Only the research deck is missing. |

## First milestone for integrations

1. Build `meanwhile-hook` plus a debug window that prints normalized events.
2. Install on all three agents and record one real session each, with a web search, an edit and a permission prompt.
3. Pin each adapter and transcript parser against those recordings. Keep the recordings as test fixtures (with secrets removed).
