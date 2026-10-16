# Question engine

How Meanwhile writes good questions about large repos (hundreds of files, many markdown docs) without doubling the cost of a session.

## The double-read problem

The naive design runs a second agent next to the coding agent. It reads `CLAUDE.md`, the docs folder and the relevant source, then writes questions. Every doc is then read twice per session, once per agent. On a big repo that roughly doubles token spend and adds load on the user's rate limits.

**The fix is not to share the coding agent's context.** That isn't possible across vendors:
- Claude Code, Codex and Cursor run their own processes against their own model providers.
- A provider's prompt cache only helps when the request starts with exactly the same text, and the agent's system prompt and tool list can't be reproduced from outside.

Instead, Meanwhile follows five rules.

### 1. Observe, don't explore

During a session, Meanwhile never searches or reads the repo on its own initiative. It only uses what the coding agent already touched, which the hooks report:

| Signal | Where it comes from |
|---|---|
| Your prompt | `turn.start` |
| Files the agent read (path and line range) | `tool.read` |
| Edits (old and new text) | `tool.edit`: Claude Code `Edit` input has `old_string`/`new_string`; Cursor `afterFileEdit` has `edits[]` |
| Commands and test output | `tool.exec` |
| Web searches and pages | `tool.web` (hooks on Claude Code; the transcript on Codex and Cursor) |
| The agent's reasoning and final summary | `agent.thought`, `turn.end` (`last_assistant_message`) |

The double cost is in **LLM tokens, not disk reads**. Meanwhile can read any file from disk for free. What it must not do is push the same large documents through a second model. So the agent's activity tells Meanwhile *where to look*, and Meanwhile sends the LLM only a small slice.

The agent has already done the expensive part: searching a big repo to find the few files that matter. Transcripts hold the exact text it read, so Meanwhile reuses that choice without paying for it again. The exception is a single, capped read when you turn a repo on ([cold start](#cold-start-thin-context)).

### 2. Do the reading once per change, not once per session

- **Generate once.** Questions drawn from docs (architecture, ADRs, conventions) are generated once per **version** of a doc section and stored in the question bank. The key is the section's content hash.
- **Reuse.** Every later session reuses them at no LLM cost.
- **Regenerate only on change.** When a section changes, only that section is regenerated.

With 300 markdown files, the one-off cost is paid once. After that you pay only for what changes.

### 3. A local repo index, built without an LLM

The index tells Meanwhile which few pieces of a big repo matter for the current turn:

- **Docs.**
  - **Which files:** `*.md`, `*.mdx`, `CLAUDE.md`, `AGENTS.md`, `.cursor/rules/*.mdc`, `docs/**`, ADR folders, READMEs.
  - **Chunking:** split by heading. Each chunk is stored with its path, heading trail and hash.
  - **Mentions:** we extract which file paths, directories and code identifiers each chunk mentions.
- **Code map.** File list, language, top-level modules, and symbols from tree-sitter or ctags.
- **Git.** Commit messages for lines (`git log -L`, `git blame`), plus PR numbers in messages. Commit messages are the cheapest source of "why".
- **Search.** SQLite FTS5 over all of the above. Local embeddings can come later if lexical search proves too weak.
- **Freshness.** An FSEvents watcher plus hash checks re-index only changed files.

This costs no LLM tokens. On a large repo it should take seconds, and it runs in the background when you turn the repo on.

### 4. Evidence packs: small, scoped inputs

For each batch, the context engine builds an evidence pack with a fixed budget (start at about 6,000 tokens):

1. The diff hunks from this turn, with about 20 lines of surrounding code read from disk.
2. The top doc chunks that mention the touched paths or symbols (FTS lookup).
3. Commit messages from `git blame` on the touched lines.
4. The agent's own explanation near each edit (transcript text, the final message, and "Decision:" lines if enabled).
5. A **repo card**: about 300 tokens on what the repo is and its stack. It is written once per repo and rewritten only when the README or a top-level doc changes.

The stable part of each request (instructions, question rubric, repo card) comes first, so it hits the provider's prompt cache. Only the evidence changes between calls.

A hundred-file repo and a ten-thousand-file repo produce evidence packs of the same size. Pack size depends on the size of the turn, not the size of the repo.

### 5. Optional: the agent leaves breadcrumbs

The agent already knows *why* it made a choice, so the cheapest "why" source is to have it say so. With your permission, Meanwhile adds one line to `CLAUDE.md`, `AGENTS.md` or `.cursor/rules`:

> When you make a non-obvious design decision, state it in one sentence starting with "Decision:".

- **How it's used:** Meanwhile picks these lines out of the transcript and the final message.
- **Cost:** a few output tokens in the main session, and nothing extra read.
- **Why it's opt-in:** it edits the user's files.

## Cold start: thin context

Observation only works once Meanwhile knows enough to write a question worth answering. On the first prompt in a repo it knows almost nothing, and the agent knows far more than it does. A vague or wrong question loses the user faster than no question at all.

There are three answers:
1. Meanwhile can see more than it seems.
2. A one-time primer per repo covers most of the rest.
3. Until the evidence is strong, Meanwhile asks questions that don't need it.

### What Meanwhile can actually see

The agent's "idea of the codebase" has three parts. Meanwhile can see all three:

| Part of the agent's understanding | What Meanwhile sees |
|---|---|
| **What it read** | The transcript holds the exact file excerpts and search hits the agent saw. That is the result of its search through the repo. |
| **What it reasoned** | Assistant text in the transcript, Cursor's `afterAgentThought`, and the final message on `Stop` |
| **What was written down before** | `CLAUDE.md`, `AGENTS.md`, `.cursor/rules`: files written to give an agent a working picture of the repo. Also, if you opt in, past session transcripts in the same repo. |

What Meanwhile doesn't have is the agent's combined picture of all of it. **A good 45-second question doesn't need that whole picture.** It needs one fact worth knowing, three believable wrong answers, and an explanation. All three are local: the edited function, its callers and callees (from the code map, no LLM), and the reason the agent gave.

### One-time primer per repo

When you turn a repo on, before your first wait, Meanwhile runs a primer in the background:

| Input | Why |
|---|---|
| Agent instruction files (`CLAUDE.md`, `AGENTS.md`, `.cursor/rules`), README, top-level docs | The densest summary of the repo that exists, written for exactly this purpose |
| Directory tree, manifests (`package.json`, `pyproject.toml`, …), entry points from the code map | The stack and the overall shape |
| Last ~200 commit messages | What changes often, and why |
| Opt-in: final summaries from your last N agent sessions in this repo (assistant text only, no tool output) | Explanations the agent already wrote |

The output is the repo card (about 300 tokens) and 20–40 **orientation questions**: architecture, stack, conventions, and "why" questions from ADRs and commits.

This is the one place Meanwhile reads docs with an LLM on its own. It happens once per repo, then again only for changed sections, never once per session, so it follows [rule 2](#2-do-the-reading-once-per-change-not-once-per-session). Budget: about 50,000 tokens in and 10,000 out, roughly $0.01 at the Haiku prices [below](#cost-model-illustrative).

### Questions that don't need context

Until the evidence is strong, Meanwhile asks questions whose answers come from **what the agent does next** or from **the topic of your prompt**:

| Type | Example | What it needs | How it's resolved |
|---|---|---|---|
| Predict: files | "Which file will the agent change first?" (4 options) | Your prompt plus a local file search, no LLM | First `tool.edit`: "You called it" or "It went for api/server.ts" |
| Predict: outcome | "Will the tests pass on the first run?" | Nothing | First test run seen in `tool.exec` |
| Predict: approach | "How will it store the counts: memory, Redis, or the database?" | Prompt plus repo card; one small call | A small model compares your pick with the agent's final message |
| Concept bridge | Your prompt says "rate limiting", so you get a system-design card: "token bucket vs sliding window?" | Prompt keywords mapped to deck topics, no LLM | Normal answer |
| Spot the risk | Shows a hunk the agent just edited: "What could go wrong here?" | The hunk and the code around it | Explain-back, graded against the hunk |

**Prediction questions may be the most engaging type.** You commit to a guess, and the agent's own work reveals the answer seconds later. They also rebuild what comprehension debt wears away first: your picture of where things live. Committing to an answer before feedback is good for learning anyway ([research.md](research.md#learning-science)).

### Context score: never show a weak codebase question

Each evidence pack gets a score before Meanwhile writes a codebase question from it. The weights are a starting point, to be tuned on real data:

| Evidence in the pack | Points |
|---|---|
| An edit hunk from this turn | 2 |
| The agent's stated reason for it | 2 |
| A doc section or ADR that mentions the touched path | 1 |
| A commit message on the touched lines | 1 |
| An excerpt the agent read from a caller or callee | 1 |

| Score | What Meanwhile may ask |
|---|---|
| 4 or more | Codebase multiple choice or a "why" question |
| 2–3 | Spot the risk, or a prediction about this area |
| Under 2 | No codebase question. Concept bridge or a due review card instead. |

A strong generic question beats a weak codebase one.

### The first prompt, step by step

| Situation | First question |
|---|---|
| Repo just turned on, primer still running | Predict files or tests, or a concept bridge |
| Primer done | An orientation question that matches your prompt (FTS), or a prediction |
| Empty repo | Concept bridge or a due generic card, or "what will it create first?" |
| Mid-turn, score reaches 4 | First live codebase question |
| Second session onward | "Why" questions from the last turn, then the bank |

### Measure engagement, not just correctness

For each generator, track answer rate, skip rate, "this question is wrong" reports, and time to answer. A generator with a high skip rate gets a smaller share of questions automatically. That replaces guessing with data on whether the questions hold attention.

## Where each deck's questions come from

| Deck | Source | LLM at runtime? |
|---|---|---|
| Your codebase: Current diff | This turn's edits and evidence pack | Yes, small batch |
| Your codebase: Why this decision | Agent explanation, "Decision:" lines, commit messages, ADRs | Yes, mostly right after the turn |
| Your codebase: Architecture, Dependencies, Tests | Repo bank, generated from doc chunks and code map | No; pre-generated, picked by path overlap |
| Session research | `tool.web` results: the query, the source URL, the snippet the agent used | Yes, small batch |
| LLM fundamentals, System design, Prompting | Curated content packs | No |
| Custom decks | Generated once from a topic, doc or URL, then stored | Only when created |

## Generators

Each generator returns questions in one schema:

```json
{
  "id": "q_7f3a",
  "deck": "codebase",
  "topic": "Why this decision",
  "type": "mc | tf | short | explain | predict",
  "stem": "Why does the rate limiter keep its counters in Redis?",
  "options": ["…", "…", "…", "…"],
  "answer": 1,
  "explanation": "…",
  "evidence": [
    { "kind": "file", "path": "api/rate_limit.ts", "lines": [12, 40], "hash": "sha1:…", "quote": "…" },
    { "kind": "commit", "sha": "3f2a91c" },
    { "kind": "web", "url": "https://…", "quote": "…" },
    { "kind": "transcript", "agent": "claude", "session": "…", "event": 142 }
  ]
}
```

- **Live diff.** Starts after the first edit in a turn, then at most every 20 s while edits keep coming. Returns 1–2 questions.
- **Post-turn "why".** Runs on `turn.end` with the full turn diff and the final message. Its questions open your next wait.
- **Research.**
  - Runs on each `tool.web` result that contains a figure or a claim.
  - Produces a recall question ("what share…"), plus an optional explain-back question ("how should this change onboarding?").
  - Always cites the source URL and the quote.
- **Repo bank.**
  - Runs in the background on doc chunks that have no questions yet. It starts with chunks that mention paths you touch most often ("pay as you touch").
  - A daily token budget caps it.
- **Custom deck.** Turns a topic into 20 cards once. You can review and edit them.

## Validation: no made-up questions about your code

Questions about your own code are only useful if they're right. Every question passes deterministic checks before it can show:

1. Every evidence reference resolves: the file exists, the commit exists, the URL was really fetched in this session.
2. Each `quote` appears word for word in its source at the stored hash.
3. Multiple choice has exactly one correct key, and the stem doesn't give the answer away.
4. The question fits the notch: stem up to about 140 characters, options up to about 70.
5. No duplicates of a recent card (normalized-text and evidence overlap).

Research and "why" questions get one more cheap model pass. A second call sees **only the evidence** and must reach the same answer. If it doesn't, the question is dropped.

**After a question ships:**
- **Staleness.** Each question stores the hashes of its evidence. When a cited file changes, the question is marked stale. It is retired, or regenerated if it was a good card.
- **Reporting.** "This question is wrong" is one click. It retires the card and logs the case for prompt fixes.

## Timing inside one wait

Anthropic reports a median Claude Code turn of about 45 seconds ([source](https://www.anthropic.com/research/measuring-agent-autonomy)), so a wait fits 1–3 short questions.

| Moment | What shows | LLM latency |
|---|---|---|
| `turn.start` | A prediction about this turn, the best match from the bank (FTS on your prompt plus recent paths), or a due review card | None |
| First edit or web result + generation time | A live question about this turn, if the turn is still running | A few seconds, hidden behind the current question |
| `turn.end` | Score; or finish the current question, depending on settings | None |
| Next `turn.start` | Post-turn "why" questions from the last turn | None, already generated |

**Empty or new repo:** codebase questions stay off at `turn.start` until the repo has tracked source files and the index exists. A first prompt in an empty folder therefore gets generic or research questions. Its diff turns into codebase questions after the turn ends.

## Cost model (illustrative)

Prices are from the research brief, Haiku 5.5 at $0.10 input / $0.50 output per million tokens ([pricing](https://platform.claude.com/docs/en/about-claude/pricing)). Check current prices before relying on these numbers.

| Item | Tokens | Cost |
|---|---|---|
| One live batch | about 6,000 in + 800 out | about $0.001 |
| A heavy day: 30 turns × 2 batches | about 400,000 in + 50,000 out | about $0.06 |
| Repo bank warm-up: 300 doc chunks | about 450,000 in + 120,000 out | about $0.11, once per repo; later only on changes |

Compare that with the coding agent. It re-sends its whole conversation on every tool call (mostly through its prompt cache), so a single session routinely uses millions of input tokens. Meanwhile adds a few thousand tokens per turn on a much cheaper model. That's a small fraction of what the agent already uses, not double. We should measure the real ratio on real sessions in the prototype.

## Alternatives considered

| Option | Why not (as default) |
|---|---|
| A second agent that reads the repo and docs every session | The double-read problem: about 2× tokens, plus rate-limit pressure |
| Ask the coding agent itself to write questions (for example, a `Stop` hook that makes it continue) | Makes your turn longer, which defeats the purpose. Spends main-model tokens. Adds quiz text to the agent's context. |
| **Fork the agent's session** (Claude Code: `claude -p --resume <session> --fork-session "write 3 questions"`) | The best context, with no re-reading, and if it runs right after the turn the fork reads the conversation from the prompt cache at a reduced price. But it uses the main model and your plan's limits. It works only on Claude Code. **Verify:** the flags on the current CLI, and whether using the subscription this way is allowed. **Candidate for an opt-in "deep mode" on Claude Code.** |
| Embed the whole repo with a vector database | Costs more up front, and turns don't need it. Lexical search plus path overlap is enough to start. |
| Generate everything at idle time only | Misses the most valuable questions, the ones about what just changed and what was just found. |
