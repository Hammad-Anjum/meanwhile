# Research

Compiled 2026-10-16. Star counts and prices change, so check them again before quoting them.

## Competitors

None of these combines all three of Meanwhile's parts:
1. A non-blocking surface that appears when the agent starts.
2. Questions grounded in the live session: the diff, why decisions were made, and what the agent found on the web.
3. Generic decks you can toggle, with spaced review.

| Product | What it does | How it differs |
|---|---|---|
| [Lull](https://github.com/h0ng1991/Lull) | Shows a flashcard in a screen corner while Claude Code or Codex works (triggered by the `UserPromptSubmit` hook) | Windows only for display. Generic decks; codebase cards are a paid add-on. 1 star. |
| [Covate](https://covate.org/) ([GitHub](https://github.com/SunflowersLwtech/covate)) | MCP server that quizzes you on your git diff (3 multiple-choice questions) | **Blocks** the agent until you answer. Started by request or on a schedule, not by hooks. |
| [after-build-quiz](https://github.com/VSDeadShot/after-build-quiz) | Claude Code plugin: `/quiz` asks why / concept / explain-back questions about your commits, graded by a separate model | Runs after the work, on request. Good question types to borrow. |
| [maxlearn](https://github.com/yashverma2110/maxlearn) | Claude Code mod: lessons and flashcards from your chats, with FSRS scheduling | Lives inside the terminal. Doesn't follow agent turns. |
| [PR Quiz](https://news.ycombinator.com/item?id=44726672) | GitHub Action that blocks a merge until you pass a quiz on the PR | Happens at merge time. HN commenters pointed out AI can answer it, and objected to sending code to OpenAI. |
| [AIditor](https://marketplace.visualstudio.com/items?itemName=asabry.aiditor-vscode) | VS Code quiz before commit, on the staged diff | Happens at commit time; tiny install base |
| [Claude Code output styles](https://code.claude.com/docs/en/output-styles) | Built-in Learning style leaves `TODO(human)` gaps for you to write | Built into the agent and changes how it works. Not a quiz. |

**Notch apps** are the biggest distribution threat. They already have the hooks, the notch UI and users, but no quiz feature:
- [CodeIsland](https://github.com/wxtsky/CodeIsland): about 2,500 stars, MIT, 30+ agents.
- [Vibe Island](https://vibeisland.app/): paid, one-time.
- [Chimlo](https://www.producthunt.com/products/chimlo-agents-in-your-macbook-notch).
- [notch-agent](https://github.com/TeamNoSleepz/notch-agent).
- [Notchware](https://ballmac.com/notchware).

**Prior art for quizzes during waits:** MIT's WaitChatter ([CHI 2015](https://sls.csail.mit.edu/publications/2015/Cai_CHI-2015.pdf)).

**Not found:** any product that quizzes you on facts your agent found through web research.

## The problem is real: comprehension debt

- **The term.** Addy Osmani: [comprehension debt](https://addyosmani.com/blog/comprehension-debt/). Code is cheap to generate, but understanding it still takes effort.
- **The Anthropic RCT** ([post](https://www.anthropic.com/research/AI-assistance-coding-skills), [paper](https://arxiv.org/abs/2601.20245)):
  - 52 mostly junior engineers learned a new library.
  - The AI group scored **50%** on a later quiz, against **67%** for the hand-coding group. Debugging questions showed the biggest gap.
  - Pure delegation scored under 40%. Asking conceptual questions scored 65% or higher.
- **METR** ([study](https://metr.org/blog/2025-07-10-early-2025-ai-experienced-os-dev-study/)): experienced developers were 19% slower with AI while believing they were faster.
- **Explain-back helps.** An "explanation gate" before integrating AI code cut maintenance failures from 77% to 39% ([arXiv 2602.20206](https://arxiv.org/abs/2602.20206)).

## Learning science

- **Testing beats rereading.** One week later: 61% recall after repeated testing vs 40% after repeated study ([Roediger & Karpicke 2006](https://psychology.ecu.edu/wp-content/pv-uploads/sites/216/2019/03/Roediger-Karpicke-2006.pdf)). Feedback after answering makes it stronger.
- **Spacing.** The best gap between reviews grows with how long you need to remember ([Cepeda et al. 2006](https://pubmed.ncbi.nlm.nih.gov/16719566/)). Use FSRS ([benchmark](https://github.com/open-spaced-repetition/srs-benchmark)).
- **Interleaving.** Mixing topics helped in [Rohrer & Taylor 2007](https://digitalcommons.usf.edu/psy_facpub/1767/). The effect varies across studies, so treat it as a mild benefit.
- **Generating answers.** Producing an answer beats recognizing one (d ≈ 0.40, [meta-analysis](https://pubmed.ncbi.nlm.nih.gov/17645161/)). This supports short-answer and explain-back types for longer waits.
- **Confidence.** High-confidence errors get corrected more often once feedback arrives (hypercorrection). Ask "how sure?" before showing the answer.
- **Short waits.** In WaitChatter, people answered most when the card appeared **right after they acted**. Median answer time was under 2 s. → Show the first question at `turn.start`, with no generation delay.

## Agent turn length

- **Typical turn.** The median Claude Code turn is about 45 s ([Anthropic](https://www.anthropic.com/research/measuring-agent-autonomy)), so plan for 1–3 questions.
- **Long turns** are rarer but take up most of the total waiting time ([one developer's data](https://tim-schipper.nl/en/blog/where-claude-code-spends-its-time)). They leave room for explain-back.

## Risks

| Risk | Mitigation |
|---|---|
| Interrupting flow | Agent waits are natural break points. Never block, hide on `turn.end` and `needs.input`, auto-pause on short turns. |
| Wrong questions about your code | Evidence-checked questions, staleness tracking, one-click report ([question-engine.md](question-engine.md#validation-no-made-up-questions-about-your-code)) |
| Privacy (code sent to a second LLM) | Local-first, per-repo opt-in, redaction, bring-your-own-key, local models |
| Cost | Small model, small evidence packs, bank reused across sessions (about $0.001 per batch, [estimate](question-engine.md#cost-model-illustrative)) |
| Notch apps add a quiz tab | Compete on question quality: questions grounded in your codebase and research, not generic cards |
