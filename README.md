# Meanwhile

Meanwhile shows short quiz questions in your MacBook notch while your coding agent (Claude Code or Codex) works. Questions come from the code your agent just changed, from your repo's docs, and from built-in decks (LLMs, system design, prompting, your stack). It never pauses or steers the agent.

## Requirements

- macOS 14 or later, Apple silicon or Intel. Macs and displays without a notch get a small floating pill instead.
- Claude Code, Codex, or both, installed first (`setup` needs `~/.claude` or `~/.codex`).
- For codebase questions: a provider CLI on your `PATH`, logged in. `codex` is the default; `claude` also works. Meanwhile runs that CLI under your own account, so its calls count toward your plan's usage limits. Deck questions work without a provider.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/Hammad-Anjum/meanwhile/main/install.sh | sh
```

The script downloads the latest [release](https://github.com/Hammad-Anjum/meanwhile/releases), checks its SHA-256, runs `meanwhile setup`, and links `~/.local/bin/meanwhile` (it prints the `PATH` line to add if that folder isn't on your `PATH`). Later, `meanwhile update` installs a newer release; `meanwhile update --check` only reports.

`setup` shows every change before it makes it, then:

- adds Meanwhile's hooks to `~/.claude/settings.json` and `~/.codex/hooks.json`. Your other settings and hooks are kept, and the old file is backed up next to it first.
- copies `meanwhile`, `meanwhile-hook` and the decks into `~/Library/Application Support/Meanwhile/bin`.
- adds a login item, so Meanwhile starts now and at every login.
- makes one test call to the question provider. If it fails, it tells you how to log in.

**Codex users:** Codex skips new hooks until you trust them. In Codex, run `/hooks` and trust the Meanwhile entries. Until you do, Codex turns show no questions.

## First run

Send your agent a prompt. A question opens in the notch while the agent works.

- **The opt-in card.** The first time you work in a repo, Meanwhile asks "Turn on codebase questions for <repo>?" Answer **Yes**, **Not now** (asks again after a day), or **Never**. Until you say Yes, you only get deck questions in that repo, and nothing from it is sent to a model. All worktrees of a repo share one answer.
- **Rounds.** A round of questions starts with each agent turn, then a new round starts every interval, until the cap is reached. The notch gets out of the way when the agent needs you or is done.
- **Codebase questions.** After you say Yes, Meanwhile reads the repo's docs once and writes a short repo card and a few orientation questions. After that, questions come from what the agent changed in each turn. A turn with too little to go on gets none, so they can take a few turns to appear.
- **Predictions.** In repos you turned on, you are sometimes asked to guess what the agent will do ("Which file will it change first?"). The agent's own work answers it.

Answer with the mouse, or with global hotkeys while a question is open:

| Keys | Does |
|---|---|
| ⌃⌥1 to ⌃⌥4 | Pick option 1–4 (after answering: pick a confidence) |
| ⌃⌥↩ | Next |

The hotkeys are only registered while a question is open, so other apps keep them the rest of the time.

The menu bar icon (a question bubble) has **Decks** (turn decks on and off), **Pacing**, **Show Event Log**, **Ask a Question in 3 s** (to try the notch without an agent), **Hide Notch**, and **Quit Meanwhile**.

## Settings

Settings live in `~/.config/meanwhile/config.toml` (or `$XDG_CONFIG_HOME/meanwhile/config.toml`). Change them in three ways:

- the menu bar icon → **Pacing** (presets, or type a value; **Open Config File** opens the file),
- `meanwhile config <key> <value>`,
- editing the file.

The app uses a change from the next agent turn.

| Key | Default | Allowed |
|---|---|---|
| `questions_per_round` | `3` | Questions shown back to back in one round, 1–20 |
| `round_interval` | `"2m"` | Time between rounds, 10s to 2h, e.g. `90s` or `2m`. The first round starts right away |
| `max_questions` | `20` | Most questions per `max_questions_per`, 1–1000, or `none`. Predictions don't count |
| `max_questions_per` | `"turn"` | What the cap counts over: `turn` (one agent run) or `day` |

```sh
meanwhile config                         # show every setting
meanwhile config round_interval 5m       # change one
meanwhile config max_questions none      # no cap
```

The question provider is not in this file yet. `setup` picks `codex` if it is on your `PATH`, else `claude`, and saves the choice in macOS user defaults. To switch: `defaults write meanwhile provider claude` (or `codex`).

## Commands

| Command | Does |
|---|---|
| `meanwhile run` | Runs the notch process in the foreground (the login item runs this). `--show-log` opens the Event Log. The default when you type just `meanwhile` |
| `meanwhile setup` | Installs the hooks and the login item, and tests the provider. `--dry-run` shows what would change and changes nothing; `--yes` skips the prompts; `--agents claude,codex` picks agents; `--no-start` skips the login item |
| `meanwhile uninstall` | Removes the hooks and the login item, and stops Meanwhile. Keeps your progress. `--purge` also deletes all data, after asking |
| `meanwhile doctor` | Checks the install and prints a fix for each problem. Exits non-zero if something is wrong. `--model` also makes one real call to the provider |
| `meanwhile update` | Updates to the latest GitHub release |
| `meanwhile config [key] [value]` | Shows or changes settings |
| `meanwhile repos` | Lists the repos Meanwhile has seen, whether each is on, and whether it could read them |
| `meanwhile version` | Prints the version |

`meanwhile --help` and `meanwhile <command> --help` list every option.

## Troubleshooting

Start with:

```sh
meanwhile doctor           # binaries, login item, app running, hooks, Codex trust, provider login, databases, config
meanwhile doctor --model   # also one real provider call
```

The app's log is `~/Library/Logs/Meanwhile/meanwhile.log`.

Common problems:

- **No questions on Codex turns.** Run `/hooks` in Codex and trust the Meanwhile entries.
- **Deck questions but never codebase questions.** Check that the repo is on (`meanwhile repos`), and that the provider works (`meanwhile doctor --model`). Codebase questions also need the agent to edit files in the repo.
- **Claude provider says "Not logged in" or the login expired.** Run `claude`, then `/login`, and finish the login in your browser. For Codex, run `codex login`.
- **Nothing in the notch at all.** Check that Meanwhile is running (the menu bar icon). If you quit it from the menu, it stays stopped until your next login; run `meanwhile setup` to start it again now.
- **Questions stop after a while.** You may have hit the cap (`max_questions`, see `meanwhile config`). New codebase questions also stop for the day after 20 model calls.
- **A repo in `~/Desktop`, `~/Documents` or `~/Downloads` shows "can't read" in `meanwhile repos`.** macOS limits access to those folders. Meanwhile reads repos from the agent's terminal, so give the terminal access in System Settings → Privacy & Security → Files and Folders.

## Uninstall

```sh
meanwhile uninstall          # removes hooks and login item; keeps your progress
meanwhile uninstall --purge  # also deletes all Meanwhile data, after asking
```

## Privacy

Everything Meanwhile stores stays on your Mac, in files only your user can read. Meanwhile has no servers and no telemetry. The only thing that leaves your Mac is a small, redacted excerpt of a turn (or, once per repo, of its docs), sent through your own `codex` or `claude` CLI under your own account, and only for repos you turned on. Files that usually hold secrets are never read. See [PRIVACY.md](PRIVACY.md) for the details and how to delete everything.

## Development

Requires macOS 14+ and a Swift 6 toolchain (Xcode 16+ or the Command Line Tools). Everything builds with SwiftPM.

A clickable mockup of the notch is in [mockup/index.html](mockup/index.html).

### Build

```sh
make build    # swift build: the meanwhile and meanwhile-hook binaries
make test     # core library tests (swift test)
make run      # build and run `meanwhile run` in the foreground; look for the icon in the menu bar
```

Or directly: `swift run meanwhile run`.

### Set up from a checkout

```sh
swift build
.build/debug/meanwhile setup --dry-run   # what would change; changes nothing
.build/debug/meanwhile setup             # hooks for Claude Code and Codex, start at login, a provider test
.build/debug/meanwhile uninstall         # removes the hooks and the login item; keeps your progress
```

`setup` copies `meanwhile`, `meanwhile-hook` and the decks into `~/Library/Application Support/Meanwhile/bin`, and the login item runs that copy, because macOS hides `~/Desktop`, `~/Documents` and `~/Downloads` from background processes. After rebuilding, run `setup` again to update the copy.

If you run `setup` inside a checkout whose `.claude/settings.json` or `.codex/hooks.json` also runs `meanwhile-hook`, it warns you: events from that folder would arrive twice.

Hidden commands for development: `meanwhile model-check [--provider codex|claude]` asks the provider one sample question and times it; `meanwhile generate --repo <path> --session <id>` writes questions for a session's latest turn and prints them. `meanwhile run --record` also writes every raw hook event to `~/Library/Application Support/Meanwhile/debug/events.ndjson` for test fixtures (off by default: it holds prompts and code).

### Release

Push a tag like `v0.2.0`. `.github/workflows/release.yml` sets the version from the tag (`scripts/set-version.sh`), runs the tests, builds a universal binary, ad-hoc signs it, and publishes `meanwhile-<version>-macos.tar.gz` and `SHA256SUMS` (`scripts/package.sh`; run it locally to get the same files in `dist/`). CI (`.github/workflows/ci.yml`) builds and tests every push to `main` and every pull request.

### Layout

| Path | What |
|---|---|
| `Sources/MeanwhileIPC` | Paths and wire format shared by the app and the hook |
| `Sources/MeanwhileCore` | The engine: events, sessions, storage, indexing, questions, providers, scheduling, settings, install |
| `Sources/MeanwhileHook` | `meanwhile-hook`, the small program agents call from their hooks |
| `Sources/MeanwhileApp` | The `meanwhile` command: the background notch process and the CLI |
| `Tests/` | Core tests and recorded hook payloads |
| `scripts/` | Packaging, versioning, spike and fixture scripts |
