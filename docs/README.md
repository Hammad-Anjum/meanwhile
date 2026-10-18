# Meanwhile

Meanwhile is a macOS notch app. While your coding agent works, it asks you short questions about your codebase, about what the agent found in this session, and about topics you choose (LLMs, system design, prompting). The idea: spend the 30–90 second wait learning instead of scrolling, and stay on top of code you didn't write yourself.

Status: **early build** (Phase 0). See [`progress.html`](progress.html) for what's done, what's left, and diagrams of the current structure. A clickable mockup lives in [`../mockup/index.html`](../mockup/index.html).

## Decisions so far

| Decision | Choice | Date |
|---|---|---|
| Name | Meanwhile (working name) | 2026-10-16 |
| First surface | The MacBook notch, with a floating pill on Macs and displays without one | 2026-10-16 |
| Agents at launch | Claude Code, Codex, Cursor | 2026-10-16 |
| Blocking | Never. Meanwhile does not pause, delay, or steer the agent. | 2026-10-16 |
| Context strategy | Observe what the agent already read; never re-explore the repo during a session ([details](question-engine.md#the-double-read-problem)) | 2026-10-16 |
| Cold start | One capped primer per repo when it's turned on. Prediction and concept questions until the evidence is strong; no weak codebase questions ([details](question-engine.md#cold-start-thin-context)) | 2026-10-16 |
| Who pays for questions | All three options, user picks. Build the existing-subscription route (`claude -p`, `codex exec`) and API keys first; a local model comes later | 2026-10-17 |
| Deep mode (fork the Claude Code session) | Later, opt-in. Not in v1 | 2026-10-17 |
| "Decision:" breadcrumbs | Offered per repo, off by default. The user sees the exact line before it's added | 2026-10-17 |
| Past session summaries in the primer | Ask once per repo. Final summaries only, never tool output | 2026-10-17 |
| Minimum macOS | 14 | 2026-10-17 |
| Display | Follows the display with the agent's terminal or editor; falls back to the built-in notch | 2026-10-17 |
| Team features | After v1. Keep storage ready for a shared bank per repo | 2026-10-17 |
| Release model | Undecided. Keep the code clean enough to open-source | 2026-10-17 |

## Documents

| Doc | What it covers |
|---|---|
| [architecture.md](architecture.md) | Components, processes, data flow for one agent turn, storage, the notch app |
| [question-engine.md](question-engine.md) | How questions are made for large repos without reading the docs twice, plus validation, timing, and cost |
| [integrations.md](integrations.md) | Hook mapping for Claude Code, Codex, and Cursor; the shared event schema; gaps per agent |
| [research.md](research.md) | Competitors, evidence that the problem is real, learning-science basis, sources |
| [progress.html](progress.html) | Visual tracker: high- and low-level diagrams of the current structure, task status, change log |
| [mvp-plan.md](mvp-plan.md) | v1 scope, tech stack, repo layout, flows, phased task list, where to start |

## Open questions

1. **Check before building the subscription route:**
   - Do Anthropic's and OpenAI's terms allow a third-party app to run `claude -p` / `codex exec` on the user's plan for this purpose?
   - How much of the user's rate limit does it use?

   If the terms don't allow it, API keys become the default.
2. **Release model:** open source, open core, or paid. This affects whether the generic decks and the hook installer are public.
