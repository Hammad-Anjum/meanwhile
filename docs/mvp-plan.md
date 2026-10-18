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
| App | Swift 6, SwiftUI, AppKit `NSPanel`, macOS 14+ | Native notch window, low memory, one language |
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
    MeanwhileHook/        the small CLI the agents call
  App/                    SwiftUI app (Xcode project): notch, settings, onboarding
  Packs/                  generic decks as JSON
  Tests/
    Fixtures/             recorded hook payloads per agent (secrets removed)
  docs/
```

## Flows

### First launch (onboarding)

1. Welcome: one screen explaining what Meanwhile does.
2. **Detect agents:** check `~/.claude`, `~/.codex`, `~/.cursor`, and show which are found.
3. **Install hooks:** for each agent the user picks, show the exact change, back up the file, then merge in Meanwhile's entries.
4. **Codex only:** "Run `/hooks` in Codex and trust Meanwhile". The app waits for the first Codex event to confirm.
5. **Pick a provider:** existing subscription (detect `claude` / `codex` on the PATH), or paste an API key (stored in Keychain).
6. **Pick decks:** codebase, research, and generic decks with topics.
7. Done. "Send a prompt to your agent to see your first question."

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

Progress (2026-10-19): **0.1, 0.2, 0.3, 0.6 and 0.7 done** (0.7 findings in [README.md](README.md#terms-check-running-the-agents-clis-on-the-users-plan-task-07-2026-10-19)). 0.5: `codex exec` (now the default provider) returns a valid question in 5.6–7.1 s (`scripts/provider_spike.sh`); it must be started with stdin closed or it waits forever. `claude -p` is still to time. A headless `codex exec` turn sends `SessionStart`, `UserPromptSubmit` and `SessionEnd` but no `Stop`. 0.4 is built and needs a hand test:
1. Run the app. In its menu, choose **Ask Test Question in 3 s**, then click into your terminal and start typing.
2. When the question opens, click an answer. Then try ⌃⌥1–4 on the next question.
3. Keep typing. The notch footer reports whether the terminal kept keyboard focus.

A prompt to a hooked agent also opens a question; `Stop` or a permission request hides it. The panel uses `becomesKeyOnlyIfNeeded`, because DynamicNotchKit's panel can otherwise become key on click.

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

### Phase 1: Vertical slice, Claude Code with generic decks

| # | Task | Size | Done when |
|---|---|---|---|
| 1.1 | Shared event schema plus the Claude Code adapter, tested on the 0.3 fixtures | M | Fixture tests pass |
| 1.2 | Event store (GRDB) with 30-day retention | S | Events persist across app restarts |
| 1.3 | Session tracker state machine (idle, working, needs input, done) | M | Unit tests for every transition |
| 1.4 | Pack format (JSON schema) and 3 starter packs: LLM fundamentals, system design, prompting, about 30 cards each, reviewed by hand | M | Packs load; each card passes schema checks |
| 1.5 | Scheduler v1: pick from enabled decks and topics, interleave, limit per wait, simple spacing (missed → tomorrow; then 2, 4, 7… days by confidence) | M | Unit tests |
| 1.6 | Notch UI: compact (timer and count), expanded (multiple choice, true/false), feedback with confidence buttons, needs-input, done | L | Matches the mockup; works with real events |
| 1.7 | Claude Code hook installer: detect, show the change, back up, merge, uninstall | M | Install and uninstall leave `settings.json` exactly as before plus or minus our entries |
| **Exit** | A real Claude Code turn shows a generic question in the notch, hides when the agent needs you, and shows a score on `Stop` | | |

### Phase 2: Codebase questions

| # | Task | Size | Done when |
|---|---|---|---|
| 2.1 | Repo opt-in flow and empty-repo detection | S | New folder → prompt in the notch |
| 2.2 | Repo index: doc chunks by heading (FTS5), file map, git log and blame, `.gitignore` / `.meanwhileignore` | L | Index of a large repo built in under a minute; incremental on file change |
| 2.3 | Provider layer: `QuestionModel` protocol and 4 implementations; keys in Keychain | M | The same prompt works through all four |
| 2.4 | Evidence pack builder (about 6,000 tokens) with secret redaction | M | Tests: packs stay in budget; no secrets leak in fixture repos |
| 2.5 | Generators: live diff, post-turn "why", primer (orientation questions, plus past-session summaries if allowed) | L | Questions on your real repos |
| 2.6 | Validator: evidence resolves, quotes match, one correct answer, notch length limits; staleness on file change | M | Bad fixtures are rejected |
| 2.7 | Context score and fallback order | S | Thin evidence never yields a codebase question |
| 2.8 | Prediction questions: "which file first", "tests pass first try" | M | Resolved live in the notch |
| 2.9 | "This question is wrong" button | S | Retires the card and logs it |
| **Exit** | Of 20 codebase questions on your own repos, you judge at least 16 correct and worth asking | | |

### Phase 3: Session research deck

| # | Task | Size | Done when |
|---|---|---|---|
| 3.1 | Capture Claude Code `WebSearch` / `WebFetch` results into `tool.web` events | S | Fixtures pass |
| 3.2 | Research generator: recall question for figures and claims, always with source URL and quote | M | A research prompt yields a question citing its source |

### Phase 4: Codex and Cursor

| # | Task | Size | Done when |
|---|---|---|---|
| 4.1 | Codex adapter and installer, including the `/hooks` trust step and confirmation | M | Phase 1 and 2 exits pass on Codex |
| 4.2 | Install Cursor; record fixtures; Cursor adapter and installer | M | Phase 1 and 2 exits pass on Cursor |
| 4.3 | Transcript tailer for web results on Codex and Cursor, with versioned parsers that fail quietly | M | Research questions appear on both, or the deck quietly shows less |
| 4.4 | Needs-input fallback for Cursor (no events for N seconds) | S | Questions hide while Cursor waits on you |

### Phase 5: Settings, customization, polish

| # | Task | Size | Done when |
|---|---|---|---|
| 5.1 | Settings window: decks and topics, question types, mix, limit per wait, behavior when the agent finishes, provider, per-repo switches | L | Every setting changes behavior |
| 5.2 | **Generic deck editor:** add, edit and delete cards; create a deck from a topic (written by AI once, then editable); import and export JSON | M | A custom deck shows up in the notch |
| 5.3 | Recap view | S | Matches the mockup |
| 5.4 | Display placement: follow the agent's terminal or editor window; fall back to the built-in notch | M | Works with an external monitor |
| 5.5 | Onboarding flow (above) | M | A fresh Mac account gets from install to first question in under 3 minutes |
| 5.6 | Auto-pause on short turns and screen sharing; Escape and hover behavior | S | |
| 5.7 | Packaging: signing, notarization, launch at login | M | A notarized `.dmg` installs on another Mac |

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
