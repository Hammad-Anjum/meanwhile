# Meanwhile

Meanwhile is a macOS notch tool for developers. While your coding agent works, it asks you short questions about your codebase, about what the agent found in this session, and about topics you choose (LLMs, system design, prompting). The idea: spend the 30–90 second wait learning instead of scrolling, and stay on top of code you didn't write yourself.

Status: **early build**. Phase 0 is done; Phase 1 is next. See [`progress.html`](progress.html) for what's done, what's left, and diagrams of the current structure. A clickable mockup lives in [`../mockup/index.html`](../mockup/index.html).

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
| Reading repos in Desktop, Documents, Downloads | The indexer runs as a helper started by `meanwhile-hook`, inheriting the terminal's access; hook-only evidence as fallback ([phase2-plan.md](phase2-plan.md)) | 2026-10-19 |
| Turning a repo on | Ask once per repo in the notch | 2026-10-19 |
| Daily generation budget | 20 calls a day, plus at most 1 live and 1 post-turn call per turn | 2026-10-19 |
| Why a question was picked | One small grey line under the deck chip in the notch | 2026-10-19 |
| Fallback if the notch takes focus | Both: floating pill with hover and click answers, plus global hotkeys | 2026-10-19 |
| Shape | A command-line tool, not an app: one `meanwhile` program that runs the notch in the background (`meanwhile run`) and sets itself up (`meanwhile setup`). A full `.app` only if there are many paying customers | 2026-10-19 |
| Install | A `curl … \| sh` script that downloads a ready-built program from a GitHub release and runs `meanwhile setup`. A Homebrew tap can come later from the same release files | 2026-10-19 |
| Provider default | `codex exec` on the user's ChatGPT plan, for now. Claude CLI and API keys remain options | 2026-10-19 |
| Git worktrees | One project per repo: all worktrees share the opt-in, repo card and question pool; each keeps its own file index. A question shows in a worktree only if the files it cites match there, so branch-only questions stay on their branch until merged | 2026-10-20 |
| Pacing | Rounds of questions: the first with the agent's turn, then one every interval, up to a cap per turn or per day. All three are settings (presets or a typed value); defaults 3 per round, every 2 minutes, 20 per turn | 2026-10-20 |

## Documents

| Doc | What it covers |
|---|---|
| [architecture.md](architecture.md) | Components, processes, data flow for one agent turn, storage, the notch app |
| [question-engine.md](question-engine.md) | How questions are made for large repos without reading the docs twice, plus validation, timing, and cost |
| [integrations.md](integrations.md) | Hook mapping for Claude Code, Codex, and Cursor; the shared event schema; gaps per agent |
| [research.md](research.md) | Competitors, evidence that the problem is real, learning-science basis, sources |
| [progress.html](progress.html) | Visual tracker: high- and low-level diagrams of the current structure, task status, change log |
| [mvp-plan.md](mvp-plan.md) | v1 scope, tech stack, repo layout, flows, phased task list, where to start |
| [phase2-plan.md](phase2-plan.md) | Phase 2 in detail: how the index scales with the repo, how questions are ranked, macOS folder access, revised tasks |

## Open questions

1. **Release model:** open source, open core, or paid. This affects whether the generic decks and the hook installer are public.

## Terms check: running the agents' CLIs on the user's plan (task 0.7, 2026-10-19)

| Provider | Verdict | Basis |
|---|---|---|
| Anthropic (`claude -p`) | **Yes, with conditions.** Spawning the user's own, unmodified `claude` binary, signed in through Anthropic's own flow, is allowed. Handling, storing or forwarding Claude.ai tokens is not. | [Claude Code legal and compliance](https://code.claude.com/docs/en/legal-and-compliance): third parties may not "route requests through Free, Pro, or Max plan credentials on behalf of their users" or "collect, store, or intermediate Claude.ai credentials", but this does not "prevent an end user from signing in to the unmodified Claude Code binary with their own Claude subscription". The same page says developer products "should use API key authentication". |
| OpenAI (`codex exec`) | **Unclear, probably tolerated.** No rule found against a local app running the user's own CLI. Reading `~/.codex/auth.json` or calling the backend directly is not allowed. | [Codex auth docs](https://learn.chatgpt.com/docs/auth): "API keys are still the recommended default for automation"; access tokens "are intended for trusted scripts, schedulers, and private CI runners". The OpenAI Terms of Use page could not be fetched. |

**Usage limits:** on both, CLI calls draw from the same 5-hour and weekly limits as the user's own agent. Anthropic's separate Agent SDK credit is paused as of 2026-10. At about 6,000 tokens a question, several times per turn, Meanwhile competes with the user's main work.

**Rules if the CLI route ships:**
- Always spawn the unmodified binary and let its own login handle auth.
- Never read, copy or proxy OAuth tokens or `auth.json`.
- Warn about usage in the provider picker.
- Check both policies again before release; Anthropic changed this policy several times in 2026.
