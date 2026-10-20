# Privacy

What Meanwhile stores, what leaves your Mac, and how to delete it. Checked against the code on 2026-10-20.

In short: everything is stored on your Mac. Meanwhile has no servers and no telemetry. The only data that leaves your Mac is a small, redacted excerpt sent through your own `codex` or `claude` CLI, under your own account, for repos you turned on.

## What is stored on your Mac

All of it is under your home folder. The folder `~/Library/Application Support/Meanwhile` and the databases in it are readable only by your user (folder mode 700, files 600).

### `~/Library/Application Support/Meanwhile/`

| Path | What it holds | How long |
|---|---|---|
| `meanwhile.sqlite` | Every hook event your agents send: your prompts, the tools the agent ran with their inputs and results (which can include file contents and diffs), and the agent's final messages. Kept raw and in a parsed form. Events from every folder the agent works in are stored, whether or not you turned that repo on. | Deleted after 30 days. The app prunes at launch and every 6 hours while running. |
| `reviews.sqlite` | Your progress: for each card, when it is next due and how often you got it right; a log of every answer (card id, choice, right or wrong, confidence, session id); each question shown, its outcome and why it was picked; cards you reported. | Kept until you delete it. Not pruned. |
| `library.sqlite` | What Meanwhile learned about each repo: its path, its opt-in answer, and for repos you turned on, the index (file paths and git blob hashes, chunks of doc files, symbol names and line numbers from code files, commit subjects with author email and date, how often each file changed), the repo card, and the question pool (each question with the quote and file path it cites). Also a log of every model call (time, kind, provider, repo, session, success, duration) used to enforce the budget, and the worker's queue. | Kept until you choose **Never** for the repo (see below) or delete the file. |
| `spool/` | Hook events written while Meanwhile wasn't running. | Read into `meanwhile.sqlite` and emptied when Meanwhile next starts (or within seconds, if it is running). |
| `debug/events.ndjson`, `debug/events.previous.ndjson` | Only if you start Meanwhile with `meanwhile run --record` (a developer option for test fixtures; off by default): a raw copy of every hook event, the same content as `meanwhile.sqlite`. | Size-limited, not time-limited: when the file reaches 32 MB it becomes `events.previous.ndjson` and the older one is deleted. Up to about 64 MB in all. |
| `bin/` | The installed `meanwhile`, `meanwhile-hook` and the bundled decks. | Removed by `meanwhile uninstall`. |
| `meanwhile.sock`, `worker.lock` | The socket the hook sends events to, and a lock so only one worker runs. No data. | While Meanwhile runs. |

Databases are backed up before a schema upgrade.

### Elsewhere

| Path | What it holds |
|---|---|
| `~/Library/Logs/Meanwhile/meanwhile.log` | The app's output and errors. Rotated. |
| `~/.config/meanwhile/config.toml` | Your settings (pacing). Uses `$XDG_CONFIG_HOME` if set. |
| `~/Library/LaunchAgents/dev.meanwhile.agent.plist` | The login item that starts `meanwhile run`. |
| macOS user defaults for `meanwhile` | The question provider (`codex` or `claude`) and which decks you turned off. |
| `~/.claude/settings.json` | Meanwhile's hook entries for Claude Code: each runs `meanwhile-hook claude <event>`. Your other settings stay as they were. |
| `~/.codex/hooks.json` | Meanwhile's hook entries for Codex: each runs `meanwhile-hook codex <event>`. |
| `~/.claude/settings.json.meanwhile-backup-<date>`, `~/.codex/hooks.json.meanwhile-backup-<date>` | A copy of each file from before `setup` or `uninstall` changed it. Not deleted automatically. |
| A temporary folder per model call, in `$TMPDIR` | The question schema and the model's answer. Deleted right after the call. |

## What leaves your Mac

Only one thing: a request to write questions, sent through the question provider CLI you chose (`codex`, the default, or `claude`). Meanwhile starts your own, unmodified CLI, which uses its own login under your account and plan. Meanwhile itself opens no network connections for this. There is no Meanwhile server and no telemetry, analytics or crash reporting.

The exception is updates: the install script and `meanwhile update` download the release from GitHub.

### When a call is made

Only for repos you turned on. A repo you haven't answered, or answered **Not now** or **Never**, is never sent to a model.

- **Primer:** once per project (a repo and all its worktrees), after you turn it on. It is retried later if the call fails.
- **Live:** at most once per agent turn, after the agent's first edit.
- **Post-turn:** at most once per agent turn, after the turn ends.
- **Daily limit:** 20 calls a day in all, counting failed calls.

Live and post-turn calls are skipped when the turn has too little evidence.

### What a call contains

About 6,000 tokens at most, built from the current turn and the repo's index. Never the whole repo.

- **Primer:** the repo's detected stack and chunks of its doc files (`CLAUDE.md`, `AGENTS.md`, READMEs, top-level docs), up to about 22,000 characters.
- **Live and post-turn:**
  - your prompt for the turn (first 1,500 characters),
  - the lines the agent added and removed in up to 4 files, with up to 20 lines of code around each change,
  - for post-turn calls, the agent's final message (first 2,000 characters),
  - doc chunks and recent commit subjects about the changed files,
  - a short map of symbol names in nearby files,
  - the paths (not contents) of up to 10 other files the agent read.

Only events from inside the repo are used, even when one agent session works in several folders.

### Redaction

Two layers, in `Sources/MeanwhileCore/Questions/Redactor.swift`:

1. **Secret files are never read.** `.env` files (except `.env.example` and `.env.sample`), SSH keys (`id_rsa`, `id_ed25519`, …), `.netrc`, `.npmrc`, `.pypirc`, `.git-credentials`, `credentials`, `credentials.json`, service-account files, `kubeconfig`, `.htpasswd`, and files ending in `.pem`, `.key`, `.p12`, `.pfx`, `.keystore`, `.jks`, `.p8` or `.mobileprovision`. If the agent edits one, the call says only "secret file: contents not included". The indexer does not read their contents either: it reads only doc and code files.
2. **Secret patterns are masked** in everything else, replaced with `[REDACTED]`: private key blocks; AWS, GitHub, Anthropic, OpenAI, Slack, Stripe and Google API keys; JSON Web Tokens; passwords in URLs; `Authorization:` headers; and values assigned to names like `password`, `secret`, `token`, `api_key`, `access_key`, `private_key`, `client_secret` or `auth`.

Pattern matching can miss a secret with an unusual shape. If a repo holds secrets in ordinary source files, leave it off.

### How the CLI is run

- In an empty temporary folder, so it reads no repo instructions (`AGENTS.md`, `CLAUDE.md`).
- With no tools: Codex with a read-only sandbox, `--ephemeral`, and its shell tool disabled; Claude with `--tools ""` and `--no-session-persistence`, on the `haiku` model.
- With a minimal environment: home, user, path, locale and terminal variables, the CLI's own config folders, and `ANTHROPIC_API_KEY` and `OPENAI_API_KEY` if you set them. Other variables from your terminal, such as cloud credentials, are not passed on. If you set one of those API keys, the CLI may bill that key instead of your plan.

What the provider does with the request is governed by your agreement with OpenAI or Anthropic, the same as for your own `codex` or `claude` use.

## Turning a repo on, and "Never"

The first time you work in a repo, the notch asks whether to turn on codebase questions for it. All worktrees of a repo share one answer.

- **Yes:** Meanwhile indexes the repo and may send excerpts as described above.
- **Not now:** nothing is indexed or sent. It asks again after a day.
- **Never:** nothing is indexed or sent, and it doesn't ask again. Choosing Never also deletes everything learned from that project and all its worktrees in `library.sqlite`: the question pool, the repo card, file paths, doc chunks, symbols, commit info and file history. Index data shared with another repo you turned on stays for that repo.

**Never** does not delete the repo's hook events in `meanwhile.sqlite` (they expire after 30 days; also `debug/` if you used `--record`, which is limited by size), your answers in `reviews.sqlite`, or the model-call log in `library.sqlite`. The repo's path and your answer stay, so Meanwhile remembers not to ask.

## Deleting everything

```sh
meanwhile uninstall --purge
```

This removes the hooks, the login item and the installed binaries, then, after you confirm, deletes `~/Library/Application Support/Meanwhile`, `~/.config/meanwhile` and `~/Library/Logs/Meanwhile`.

Not removed by it: the hook-file backups (`~/.claude/settings.json.meanwhile-backup-*` and `~/.codex/hooks.json.meanwhile-backup-*`) and the user defaults (`defaults delete meanwhile`). Delete those by hand if you want them gone.

`meanwhile uninstall` without `--purge` keeps your data, so you can reinstall and keep your progress.

## Provider terms

Meanwhile only runs your own, unmodified `codex` or `claude` CLI and lets it handle its own login. It never reads, copies, stores or forwards your tokens or credential files (such as `~/.codex/auth.json` or the Claude keychain entry). Calls draw from the same usage limits as your own agent work.

For what each provider's terms say about this, see the [Provider table in the design README](README.md#terms-check-running-the-agents-clis-on-the-users-plan-task-07-2026-10-19).
