# Agent integrations

Meanwhile supports **Claude Code, Codex and Cursor** at launch. All three expose lifecycle hooks: shell commands that receive JSON on stdin. Meanwhile registers the same small program, `meanwhile-hook`, for each relevant event and normalizes the payloads in the app.

Facts checked on 2026-10-16 against:
- [Claude Code hooks](https://code.claude.com/docs/en/hooks)
- [Codex hooks](https://learn.chatgpt.com/docs/hooks)
- [Cursor hooks](https://cursor.com/docs/agent/hooks)

Items marked **Verify** must be tested against a real install. Rows marked as recorded were checked against real sessions on 2026-10-17; the recordings are test fixtures in `Tests/MeanwhileCoreTests/Fixtures/`.

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
  "kind": "session.start | turn.start | tool.read | tool.edit | tool.exec | tool.web | tool.other | permission.request | needs.input | notification | turn.end | subagent.end | session.end",
  "data": { },
  "transcript": "path or null",
  "term": { "program": "iTerm.app", "tty": "/dev/ttys004" }
}
```

Implemented in `Sources/MeanwhileCore/Events` (task 1.1) as `AgentEvent`, with `ClaudeAdapter` and `CodexAdapter`. Notes from running them on real sessions:
- `permission.request` is not `needs.input`. Claude Code sends `PermissionRequest` even when auto mode approves the call. Claude's `needs.input` comes from `Notification` with `notification_type` `permission_prompt` or `idle_prompt`. Codex has no `Notification` hook, so the session tracker has to infer waiting from timing.
- Claude Code sends nothing when the user approves a permission prompt; the next event is the approved tool's `PostToolUse`, which can come minutes later. So `needs.input` is a short attention signal: the tracker returns to working after 5 s (seen 2026-10-19; 20 s felt too long in testing).
- Claude Code sends an `idle_prompt` notification after `Stop` once the session sits idle. That means "waiting for the next prompt", not "blocked mid-turn".
- Shell commands that view files (`cat`, `head`, `tail`, `nl`, `sed -n`, also inside `bash -lc`) also produce `tool.read` events. Both agents read this way more often than through a Read tool.
- `agent.thought` is not produced yet; it needs the transcript tailer (Phase 4).
- Events from subagents carry `subagent` (the payload's `agent_id`).

## Event mapping

| Kind | Claude Code | Codex | Cursor |
|---|---|---|---|
| `session.start` / `session.end` | `SessionStart` / `SessionEnd` | `SessionStart` / `SessionEnd` | `sessionStart` / `sessionEnd` |
| `turn.start` | `UserPromptSubmit` (`prompt`) | `UserPromptSubmit` | `beforeSubmitPrompt` |
| `tool.read` | `PostToolUse` on `Read` (`tool_input.file_path`, `offset`, `limit`). **Also parse `Bash`:** in the recorded session Claude read files with `cat`/`sed`, not `Read`. | `PostToolUse` on shell reads; parse the command. **Verify** the tool names. | `postToolUse`. Avoid `beforeReadFile`, which is a permission hook that can block. |
| `tool.edit` | `PostToolUse` on `Edit`: `tool_input` has `old_string`/`new_string`; `tool_response` adds `originalFile` and `structuredPatch` (hunks with `oldStart`, `newStart`, `lines`). `Write` has `content`. | `PostToolUse` on `apply_patch`; `tool_input.command` holds the whole patch (`*** Begin Patch` … `*** Add File:` / `*** Update File:`). Seen 2026-10-17. | `afterFileEdit` (`file_path`, `edits[]` with `old_string` / `new_string`) |
| `tool.exec` | `PostToolUse` on `Bash` (`tool_response.stdout` / `stderr`) | `PostToolUse` on shell | `afterShellExecution` |
| `tool.web` | `PostToolUse` on `WebSearch`: `tool_input.query`; `tool_response.results` is a list mixing `{content: [{title, url}], tool_use_id}` and plain strings (the search's written summary). `WebFetch` still to record. | **Hookable after all:** `PostToolUse` with `tool_name: "webrun"`. `tool_input` has `search_query[].q` or `open[].ref_id` (the URL); `tool_response` is a list of `{type: "input_text", text}` holding the page text. Seen 2026-10-17, which contradicts the docs. | **No documented hook**. Read it from the transcript. |
| `agent.thought` | Transcript (assistant text near each edit) | Transcript | `afterAgentThought` (`text`), `afterAgentResponse` (`text`) |
| `turn.end` | `Stop` (`last_assistant_message`), `StopFailure` | `Stop` (`last_assistant_message`, `turn_id`) | `stop` |
| `needs.input` | **`PermissionRequest`**: fires the moment Claude asks. `Notification` with `permission_prompt` follows about 6 s later; `idle_prompt` arrives about 60 s after `Stop` and is not a needs-input signal. | `PermissionRequest` | No clear signal. **Verify** whether `preToolUse` or another event can stand in. |

**Common fields used:**
- **Claude Code:** `session_id`, `transcript_path`, `cwd`, `hook_event_name`, `prompt_id`; tool events add `tool_name`, `tool_input`, `tool_response`, `tool_use_id`, `duration_ms`.
- **Codex:** `session_id`, `transcript_path`, `cwd`, `hook_event_name`, `model`, `permission_mode`; turn events add `turn_id`. Transcripts live at `~/.codex/sessions/YYYY/MM/DD/rollout-<time>-<session>.jsonl`. `SessionStart` can arrive in the same millisecond as the first `UserPromptSubmit`, so don't rely on ordering.
- **Cursor:** `conversation_id`, `generation_id`, `transcript_path` (null when transcripts are off), `workspace_roots`.

## Never block the agent

- **Claude Code:** register every Meanwhile hook with `"async": true`.
- **Codex and Cursor:** there is no documented async flag. `meanwhile-hook` returns in milliseconds, with exit code 0 and empty stdout, so it is never read as a decision.
- **Permission-style hooks:** Meanwhile never registers them (Cursor `beforeReadFile`, `beforeShellExecution`; any `PreToolUse`). An empty or invalid response there could block or change the agent.
- **If the socket is down:** the hook writes to the spool file and exits. It never retries inline.

## Gaps and how we fill them

| Gap | Fill |
|---|---|
| Web search on Cursor (Codex turned out to send it through `webrun` hooks) | **Transcript tailer:** watch `transcript_path` files and pick out web results. Formats are internal and can change between releases, so parsers are versioned per agent and fail quietly (the research deck just shows less). |
| Claude Code `WebSearch` / `WebFetch` response shape | Capture real payloads in the prototype, then pin a parser. Fall back to the transcript. |
| "Needs input" on Cursor | Fall back to a timeout: no events for N seconds during a turn means it's probably waiting. Hide questions then. |
| Cursor with transcripts turned off | Hooks alone still give prompt, edits, thoughts and stop. Only the research deck is missing. |

## First milestone for integrations

1. Build `meanwhile-hook` plus a debug window that prints normalized events.
2. Install on all three agents and record one real session each, with a web search, an edit and a permission prompt.
3. Pin each adapter and transcript parser against those recordings. Keep the recordings as test fixtures (with secrets removed).
