# MVP v1 plan

## Goal

Prove the core loop on one Mac, with real agents:

> You send a prompt → the notch shows a question at once → you answer by clicking without leaving the terminal → questions about what the agent just changed or found start appearing → the agent finishes → you see a short score → missed cards come back later.

v1 is **single-user, local, no server**. "Backend" here means the app's local engine (`MeanwhileCore`) plus the hook program, not a web service.

## In v1 / not in v1

| In v1 | Not in v1 (later) |
|---|---|
| Notch UI on macOS 14+, floating pill on displays without a notch | Local models (Ollama, MLX) |
| Claude Code, Codex, Cursor | Deep mode (forking the session) |
| Decks: Your codebase, Session research, generic decks | "Decision:" breadcrumbs (v1.1, off by default) |
| **Generic decks are customizable:** turn decks and topics on or off; add, edit and delete cards; create your own deck (written by AI from a topic) | Team / shared question bank |
| Question types: multiple choice, true/false, short answer, prediction | Explain-back with AI grading (v1.1) |
| Providers: existing subscription (`claude -p`, `codex exec`) and API keys | Full FSRS (v1 uses a simple spaced schedule with the same data, so it can switch later) |
| One-time repo primer; past-session summaries, asked once per repo | Embeddings or a vector index |
| Evidence checks, context score, report a bad question | Analytics beyond local counters |

## Tech stack

| Part | Choice | Why |
|---|---|---|
| Program | One `meanwhile` command (Swift 6, [swift-argument-parser](https://github.com/apple/swift-argument-parser)). `meanwhile run` is a background AppKit process with SwiftUI views and an `NSPanel`; macOS 14+ | A tool developers install from the terminal; native notch window, low memory, one language |
| Notch | [DynamicNotchKit](https://github.com/MrKai77/DynamicNotchKit) (MIT) | Notch shape and the pill fallback already solved |
| Storage | SQLite through [GRDB.swift](https://github.com/groue/GRDB.swift) (MIT), FTS5 for search | Local, fast, full-text search included |
| Hook program | Swift command-line target in the same package | One language; starts in milliseconds |
| IPC | Unix domain socket | Local only, no ports open |
| LLM | One `QuestionModel` protocol with 4 implementations: Claude CLI, Codex CLI, Anthropic API, OpenAI API | Lets the user pick; local models slot in later |
| Tests | Swift Testing, plus recorded hook payloads as fixtures | Adapters are tested against real agent output |

## Repository layout

```
meanwhile/
  Package.swift
  Sources/
    MeanwhileCore/        engine: events, sessions, store, index, questions, scheduler
      Events/             shared schema + one adapter per agent
      Sessions/           state machine per session
      Store/              GRDB models and migrations
      Index/              doc chunks, file map, git miner
      Questions/          evidence packs, generators, validator, context score
      Providers/          Claude CLI, Codex CLI, Anthropic, OpenAI
      Scheduler/          card selection and spacing
      Install/            hook installers per agent
    MeanwhileHook/        the small CLI the agents call (kept separate so it starts fast)
    MeanwhileApp/         the `meanwhile` command: run (notch, menu bar icon), setup, uninstall
  Packs/                  generic decks as JSON
  Tests/
    Fixtures/             recorded hook payloads per agent (secrets removed)
  docs/
```

## Flows

### First run (`curl … | sh`, then `meanwhile setup`)

1. **Install:** `install.sh` downloads `meanwhile` and `meanwhile-hook` from the latest GitHub release into `~/.local/bin`, then runs `meanwhile setup`.
2. **Welcome:** one short paragraph in the terminal explaining what Meanwhile does.
3. **Detect agents:** check `~/.claude`, `~/.codex`, `~/.cursor`, and show which are found.
4. **Install hooks:** for each agent the user picks, show the exact change, back up the file, then merge in Meanwhile's entries.
5. **Codex only:** "Run `/hooks` in Codex and trust Meanwhile". Setup waits for the first Codex event to confirm, or tells the user how to check later.
6. **Pick a provider:** `codex exec` if `codex` is on the PATH (the default); otherwise `claude -p` or an API key (stored in Keychain).
7. **Pick decks:** codebase, research, and generic decks with topics.
8. **Start in the background:** install a launch agent so `meanwhile run` starts now and at every login.
9. **Test:** send a test event and show a sample question in the notch. "Send a prompt to your agent to see your first real question."

`--yes` accepts the defaults without prompts. `meanwhile uninstall` removes the hooks (restoring the backups' other entries untouched) and the launch agent.

### First turn in a new repo

1. A `turn.start` event arrives from a folder Meanwhile hasn't seen.
2. The notch asks: "Turn on codebase questions for **acme-api**?" with options Yes, Not now, Never.
3. On Yes:
   - Meanwhile builds the local index (seconds, no LLM).
   - It asks once: "Also learn from your past agent sessions here?"
   - It runs the primer in the background.
4. Until the primer finishes, this turn gets prediction and generic questions.

### An agent turn

As drawn in [architecture.md](architecture.md#one-agent-turn-end-to-end): an instant question on `turn.start`, live questions once the context score is high enough, a score on `turn.end`, and "why" questions ready for the next wait.

## Task list

Phases run in order. Each phase ends with something you can run and check. Rough sizes: **S** is under half a day, **M** is 1–2 days, **L** is 3+ days.

### Phase 0: Setup and de-risking spikes

Progress (2026-10-19): **Phase 0 is done.**
- 0.4: clicking an answer and ⌃⌥1–4 both work while the terminal keeps keyboard focus (tested by hand). The panel needs `becomesKeyOnlyIfNeeded`, because DynamicNotchKit's panel can otherwise become key on click.
- 0.5: `codex exec`, the default provider, returns a valid question in 5.6–7.1 s (`scripts/provider_spike.sh`). It must be started with stdin closed or it waits forever. Timing `claude -p` is deferred until someone picks the Claude route.
- 0.7: findings are in [README.md](README.md#terms-check-running-the-agents-clis-on-the-users-plan-task-07-2026-10-19).
- Seen along the way: a headless `codex exec` turn sends `SessionStart`, `UserPromptSubmit` and `SessionEnd` but no `Stop`. Claude Code sends `PermissionRequest` even when auto mode approves the call, so it does not mean the agent needs you; `Notification` with `notification_type: permission_prompt` or `idle_prompt` does.

These find the expensive surprises first.

| # | Task | Size | Done when |
|---|---|---|---|
| 0.1 | Create the repo, `Package.swift` with `MeanwhileCore` and `MeanwhileHook` targets, and the Xcode app project; add GRDB and DynamicNotchKit | S | App builds and shows a menu bar icon |
| 0.2 | **Hook spike:** `meanwhile-hook` sends stdin JSON to a socket; a debug window in the app lists the events | M | A real Claude Code turn shows `UserPromptSubmit` → tool events → `Stop` in the debug window |
| 0.3 | **Record fixtures:** one Claude Code and one Codex session each with a file read, an edit, a web search and a permission prompt. Save the payloads. | S | Fixtures in `Tests/Fixtures/`. The real `WebSearch` / `WebFetch` payload shape is known. |
| 0.4 | **Notch spike:** compact and expanded states with DynamicNotchKit; click an answer while the terminal keeps keyboard focus | M | You can type in the terminal, click an answer in the notch, and keep typing without clicking back |
| 0.5 | **Provider spike:** call `claude -p` and `codex exec` headless, get JSON back, time it | S | A sample question in about 5–10 s |
| 0.6 | **Recursion guard:** Meanwhile's own `claude -p` / `codex exec` calls must not fire Meanwhile's hooks (env var `MEANWHILE_INTERNAL=1`, and the hook ignores events that carry it) | S | Generating a question produces no new events |
| 0.7 | **Terms check:** read Anthropic's and OpenAI's terms on running their CLIs on a user's plan from a third-party app | S | A written yes/no in `docs/README.md`. If no, API keys become the default. |

### Phase 1: Vertical slice, Claude Code and Codex with generic decks

Scope changed 2026-10-19: Codex moved here from Phase 4 because it is the default provider; starter cards ship without a hand review.

Progress (2026-10-19): all seven tasks built. First live test of 1.6: the notch looks good. It showed three bugs, now fixed:
- "Needs you" stuck through long approved commands; it now fades after 5 s.
- Right answers were lost when "needs you" came before the confidence pick; answers are now saved on click.
- The notch moved on by itself; it is now static.

Second test: every answer saved through four permission prompts. Then trimmed: "needs you" fades after 5 s instead of 20 s, and the explanatory captions under the confidence buttons and in the recap are gone.

1.6 done (signed off 2026-10-19 after the third live test).

1.7 done for Claude Code (2026-10-19). The real `meanwhile setup` installed the hooks and the login item, and events arrive through the user-level hooks. It also found that macOS hides `~/Desktop` from the login item, so setup now installs `meanwhile` into `~/Library/Application Support/Meanwhile/bin`. Still open: a Codex turn after trusting its hooks with `/hooks`.

| # | Task | Size | Done when |
|---|---|---|---|
| 1.1 | Shared event schema plus the Claude Code and Codex adapters, tested on the 0.3 fixtures | M | Fixture tests pass |
| 1.2 | Event store (GRDB) with 30-day retention | S | Events persist across app restarts |
| 1.3 | Session tracker state machine (idle, working, needs input, done) | M | Unit tests for every transition |
| 1.4 | Pack format (JSON schema); 3 generic starter packs that can each be turned on or off (LLM fundamentals, system design, prompting and agents, about 30 cards each); a **stack deck** that follows the repo being worked on: detect the stack from its files (`Package.swift`, `package.json`, `pyproject.toml`, `go.mod`, `Cargo.toml`) and use drafted packs for common stacks (Swift/macOS, TypeScript/React, Python). Phase 2 generates packs for other stacks with the provider layer | M | Packs load; each card passes schema checks; this repo gets the Swift/macOS deck |
| 1.5 | Scheduler v1: pick from enabled decks and topics, interleave, limit per wait, simple spacing (missed → tomorrow; then 2, 4, 7… days by confidence) | M | Unit tests |
| 1.6 | Notch UI: compact (timer and count), expanded (multiple choice, true/false), feedback with confidence buttons, needs-input, done | L | Matches the mockup; works with real events |
| 1.7 | `meanwhile setup` and `meanwhile uninstall` for Claude Code and Codex (including the `/hooks` trust step): detect, show the change, back up, merge hooks; pick the provider; install a launch agent so `meanwhile run` starts at login; show a test question | M | Setup then uninstall leaves `settings.json` exactly as before; a fresh setup reaches a first question |
| **Exit** | A real Claude Code or Codex turn shows a generic question in the notch, hides when the agent needs you, and shows a score on `Stop` | | |

### Phase 2: Codebase questions

Revised 2026-10-19; the full plan, the research behind it and the decisions are in [phase2-plan.md](phase2-plan.md).

Progress:
- 2.0 done (2026-10-19). `meanwhile-hook` starts `meanwhile work` detached on turn start, edits and turn end, and the worker read a repo under `~/Desktop`. Requests go through a queue in `library.sqlite`, and one worker at a time works through it. The hook-only fallback is built with the evidence packs (2.5), using the access error the worker records.
- 2.1 done (2026-10-19). `QuestionModel` with `codex exec` (default) and `claude -p`. `GenerationBudget` allows 1 live and 1 post-turn call per turn, and 20 a day. Three real codex calls took 6.1, 9.1 and 12.3 s, so questions are generated into a pool ahead of time rather than on demand. `meanwhile model-check` makes one test call.
- 2.2 done (2026-10-19). The notch asks "Turn on codebase questions for <repo>?" once per repo (Yes / Not now / Never). It never asks for empty or unreadable repos, and "Not now" comes back after a day. Also fixed: the app couldn't detect stacks for repos under `~/Desktop`, so their stack decks were missing. The worker now records stacks in `library.sqlite`, and the app uses them.
- 2.3 done (2026-10-19). `RepoIndexer` keeps a file map by git blob hash for repos that are turned on.
  - It skips the run entirely when `HEAD` and `git status` are unchanged.
  - It hashes only working-tree changes and writes only the differences.
  - Synthetic 50,000-file repo: cold index 1.4 s, unchanged 0.24 s, one edit 0.9 s, 13 MB of index.
  - One change from the plan: no FSEvents. The app can't watch protected folders either; the worker's git checks on each turn start, edit and turn end cover it.
  - Branches share a single current snapshot per repo; blobs already seen are never reprocessed.
- 2.4 done (2026-10-19).
  - **Docs:** split at headings into FTS5 (`detail=column`), with file paths and identifiers each chunk mentions. LFS pointers and files with lines over 4 KB are skipped; 50,000 chunks per repo at most.
  - **Git history:** the last 180 days or 5,000 commits once, then only new commits. Per file: commit count, how many were yours ("not yours" share), and last change. Commit subjects are kept as "why" evidence.
  - **Speed:** on the 50,000-file repo, 2,500 docs chunk in 0.43 s, history takes 0.44 s, and a search answers in 4 ms.
  - **Fixed on the way:** `Shell.run` could deadlock when many ran at once (pipe reads used the shared thread pool), and full-text search never matched (words became arrays of characters).

| # | Task | Size | Done when |
|---|---|---|---|
| 2.0 | Access spike: the indexer runs as a helper started by `meanwhile-hook`, so it can read repos under `~/Desktop`; hook-only fallback | S | A repo on the Desktop gets indexed with no permission prompt, or the fallback is in place |
| 2.1 | Provider layer: `QuestionModel`; `codex exec` first, then `claude -p`; a queue with 1 live + 1 post-turn call per turn and 20 a day; API keys later | M | A question comes back through `codex exec` from the app in under 10 s; the budget holds |
| 2.2 | Repo opt-in in the notch (ask once per repo) and empty-repo detection | S | A new repo shows the prompt once |
| 2.3 | Index core: file map by git blob hash, exclusions, change detection (hooks, FSEvents, git), branch tags, caps | L | A large repo indexes in under a minute; a branch switch updates in under a second |
| 2.4 | Docs in FTS5 (`detail=column`) with mentions; bounded git history, churn, authorship, `blame -L` on demand | M | FTS finds doc chunks for a touched path; churn and "not yours" exist per file |
| 2.5 | Evidence packs (about 6,000 tokens) with secret redaction | M | Packs stay in budget; no secrets leak in fixture repos |
| 2.6 | Generators (live diff, post-turn "why", primer) into a question pool keyed by evidence hashes | L | Questions on your real repos land in the pool |
| 2.7 | Validator and staleness on blob change | M | Bad fixtures are rejected; changed code retires its questions |
| 2.8 | Selection v2: rules, priority score, the "why this" line, the `shown` log, the difficulty controller | M | Unit tests for every rule; score terms logged |
| 2.9 | Context score gates codebase questions | S | Thin evidence never yields a codebase question |
| 2.10 | Prediction questions and the "this question is wrong" button | M | Predictions resolve live; reports retire cards |
| 2.11 | Symbols and repo map: definitions, references, PageRank personalized to touched files | L | The map near a touched file fits its budget and names the right neighbors |
| **Exit** | Of 20 codebase questions on your own repos, you judge at least 16 correct and worth asking | | |

### Phase 3: Session research deck

| # | Task | Size | Done when |
|---|---|---|---|
| 3.1 | Capture Claude Code `WebSearch` / `WebFetch` results into `tool.web` events | S | Fixtures pass |
| 3.2 | Research generator: recall question for figures and claims, always with source URL and quote | M | A research prompt yields a question citing its source |

### Phase 4: Codex and Cursor

| # | Task | Size | Done when |
|---|---|---|---|
| 4.1 | ~~Codex adapter and installer~~ moved to Phase 1 (1.1, 1.7). Remaining: check the Phase 2 exit on Codex | S | Phase 2 exit passes on Codex |
| 4.2 | Install Cursor; record fixtures; Cursor adapter and installer | M | Phase 1 and 2 exits pass on Cursor |
| 4.3 | Transcript tailer for web results on Codex and Cursor, with versioned parsers that fail quietly | M | Research questions appear on both, or the deck quietly shows less |
| 4.4 | Needs-input fallback for Cursor (no events for N seconds) | S | Questions hide while Cursor waits on you |

### Phase 5: Settings, customization, polish

| # | Task | Size | Done when |
|---|---|---|---|
| 5.1 | Settings in `~/.config/meanwhile/config.toml` plus `meanwhile config` commands: decks and topics, question types, mix, limit per wait, behavior when the agent finishes, provider, per-repo switches | M | Every setting changes behavior |
| 5.2 | **Generic deck editor:** add, edit and delete cards; create a deck from a topic (written by AI once, then editable); import and export JSON | M | A custom deck shows up in the notch |
| 5.3 | Recap view | S | Matches the mockup |
| 5.4 | Display placement: follow the agent's terminal or editor window; fall back to the built-in notch | M | Works with an external monitor |
| 5.5 | Onboarding inside `meanwhile setup` (the flow above, as prompts in the terminal) | S | A fresh Mac account gets from install to first question in under 3 minutes |
| 5.6 | Auto-pause on short turns and screen sharing; Escape and hover behavior | S | |
| 5.7 | Packaging: universal (Apple silicon and Intel) builds on a GitHub release, `install.sh` (`curl … \| sh`) that installs `meanwhile` and `meanwhile-hook` and runs `meanwhile setup`, and `meanwhile update` | M | The one-line install works on another Mac |

### Phase 6: Use it yourself and measure

| # | Task | Size | Done when |
|---|---|---|---|
| 6.1 | Local counters per generator: shown, answered, skipped, reported wrong, time to answer | S | A stats view in Settings |
| 6.2 | Two weeks of daily use; tune the context score, timing and mix | | Answer rate is high enough that you keep it on. Set a target after week 1. |

## Where to start

**Phase 0, in this order: 0.1 → 0.2 → 0.3.** Everything else depends on knowing exactly what the hooks send. 0.4 (notch focus) and 0.7 (terms) can run in parallel, because each can change the design:
- If the notch can't take a click without stealing focus, the interaction model changes.
- If the subscription route isn't allowed, the provider default changes.

## Risks to watch

| Risk | Where it shows up | Fallback |
|---|---|---|
| Hook payloads change between agent releases | 0.3, 4.x | Fixture tests per agent version; adapters fail quietly |
| Notch panel steals focus | 0.4 | Both: a floating pill beside the notch (answers on hover and click), plus global hotkeys to answer without the mouse (decided 2026-10-19) |
| Subscription route not allowed | 0.7 | API keys as default |
| Codebase questions not good enough | Phase 2 exit | Raise the context-score threshold; lean on predictions and the primer bank |
| `claude -p` too slow for live questions | 0.5 | Generate after the turn only; serve live slots from predictions and the bank |
