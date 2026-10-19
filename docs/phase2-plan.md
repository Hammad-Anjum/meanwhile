# Phase 2 plan: codebase questions

Status: **agreed 2026-10-19** (decisions [below](#decisions-2026-10-19)). Builds on [question-engine.md](question-engine.md), which still holds: observe what the agent touched, never re-explore; fixed-size evidence packs; the context score; deterministic validation and staleness. This plan adds what that doc left open: how the index scales, how questions are ranked, and one constraint found while setting up 1.7.

Exit criterion (unchanged): of 20 codebase questions on your own repos, you judge at least 16 correct and worth asking.

## A constraint found on 2026-10-19: macOS hides some folders from Meanwhile

The login item runs `meanwhile run` under launchd. macOS privacy protection (TCC) hides `~/Desktop`, `~/Documents`, `~/Downloads` and iCloud Drive from such processes unless the user grants access. That is why the first login item crashed: it could not read its own files in a checkout under `~/Desktop`.

What this means for Phase 2:
- **What still works everywhere:** everything that arrives through hooks. Prompts, edit diffs (Claude's `structuredPatch`, Codex patches), command output, web results and file paths come in the event itself, so live-diff questions need no disk access.
- **What breaks for repos in those folders:** building the index (docs, file map, git history) and reading the code around an edit.
- **Decided:** run the indexer as a short helper started by `meanwhile-hook`. A process started from the agent's terminal is attributed to that terminal app, which already has access. Fall back to hook-only evidence otherwise. Task 2.0 checks this works before anything depends on it.

## 1. How Meanwhile keeps up as a codebase grows

The rule that makes this work: **what Meanwhile sends to the LLM depends on the size of the turn, never on the size of the repo.** Every pack has the same budget, whether the repo has 100 files or 100,000. The local index grows with the repo, so it is built to stay cheap.

### Detect changes in three layers, cheapest first

| Layer | What it gives | Cost |
|---|---|---|
| 1. Hook events | Exactly which files the agent read and edited, with diffs | Free; arrives anyway |
| 2. FSEvents | Edits made outside the agent (you, your editor, `git pull`). The last event ID is saved, so a restart resumes instead of rescanning. A `MustScanSubDirs` flag rescans only that folder | Near zero |
| 3. Git | `git ls-files -s` lists tracked files with their blob hashes without hashing anything. `git status --porcelain` finds the rest. When `HEAD` moves (branch switch, pull), `git diff-tree` between the old and new tree says exactly what changed | One fast call per change |

There is never a full rescan after the first index.

### Index content once, keyed by git blob hash

- **Content-addressed:** doc chunks, symbols and generated questions are stored by the git blob hash of the file they come from. Unchanged content is never processed twice. (Continue indexes this way; GitHub code search shrank 115 TB of code to 28 TB of unique content by de-duplicating on blob IDs.)
- **Branches are cheap:** which blobs are on which branch lives in a separate table. Switching branches only adds and removes tags.
- **Staleness is exact:** a question cites blob hashes. When a cited file's blob changes on the current branch, the question is stale.

### Skip what isn't worth indexing

- Only files git tracks (`git ls-files` already applies `.gitignore`), plus untracked docs.
- GitHub code search's exclusion rules:
  - files over 350 KiB
  - files with a line over 4 KB
  - binaries and non-UTF-8 files
  - vendored and generated code
- Also skipped: lockfiles, `*.min.*`, LFS pointers, and `node_modules`, `build` and `dist` even if tracked.

### Index a skeleton, not the code

| Part | What | When |
|---|---|---|
| File map | Path, language, size, blob hash, last commit | At opt-in, seconds |
| Docs | `*.md`, `CLAUDE.md`, `AGENTS.md`, ADRs, READMEs, split by heading into FTS5 | At opt-in |
| Git history | Last 180 days or 5,000 commits: churn per file, authors per file, commit messages | At opt-in; then only new commits |
| Symbols and references | Definitions and references per file, a reference graph, PageRank over it (Aider's repo map) | Later in Phase 2 (2.11); "pay as you touch": folders the agent works in first |

Code itself is never indexed as text. The agent's reads and the edit hunks bring in exactly the code that matters.

### Hard caps, so a monorepo can't run away

| Thing | Cap |
|---|---|
| Doc chunks per repo | 50,000, or about 200 MB of index. Past that, only the highest-ranked folders |
| FTS5 settings | `detail=column` (2–5× smaller than the default in SQLite's own test), `optimize` when idle |
| `git blame` | Only on lines the agent edited (`-L`), 2 s timeout, never on files over 5,000 lines |
| Git history | 180 days or 5,000 commits at opt-in; incremental after |
| Shallow clones | Detected; history features turn off instead of failing |

These caps are starting points to check on a large repo (Linux or Chromium) in task 2.2.

### LLM cost stays flat

- **One pack, one budget:** about 6,000 tokens. About 3,000 go to edited hunks and the code the agent read around them, about 1,500 to the repo map near the touched files, and the rest to docs and commit messages.
- **Cache by content:** a generated question is keyed by the blob hashes of its evidence plus the prompt version. Re-opening a branch never regenerates anything.
- **Budget:** at most one generation call per agent turn while it runs, one after the turn, and 20 a day ([decision 3](#decisions-2026-10-19)).
- **Pool, not on-demand:** questions are generated into a pool ahead of time, and the notch picks from the pool. A slow `codex exec` (6–7 s) never delays a question.

## 2. What makes a question show up more often

Two steps: hard rules filter out what must never show, then one weighted score ranks the rest. The score is simple and explainable on purpose. A learning algorithm (a bandit) may later adjust the *mix of decks*, never individual questions, so behavior stays predictable.

### Step 1: rules (before any scoring)

| Rule | Why |
|---|---|
| **Stale:** a cited file changed since the question was made → never shown; regenerated if it was a good card | A wrong question about your code costs more trust than any right one earns |
| **Reported wrong** → retired for good. More than 2 reports from one generator run → that run's questions are paused | Same |
| **Skipped twice** → hidden for 7 days | It isn't landing |
| **Not due and very likely remembered** (predicted recall over 95%) → only shown as filler | No learning value |
| **At most 3 per wait;** a daily cap on brand-new questions (about 15) | Attention; the "Respecting attention" rules in architecture.md |
| **Never two in a row from the same deck or the same file** | Interleaving helps learning; a meta-analysis found a moderate effect overall (g = 0.42) |
| **When the agent touched code this turn and the context score is 4 or more:** at least one codebase question in the wait | This is the product: keep up with code you didn't write |
| **Short turns:** if your recent turns in a repo end in under 10 s, wait 10 s before showing anything | Already planned (architecture.md) |

### Step 2: priority score

Each part is scaled 0–1:

`score = 0.40 · Need + 0.35 · CodeRelevance + 0.15 · DeckFit + 0.10 · Novelty`

| Part | What it measures | How |
|---|---|---|
| **Need** | How likely you've forgotten it | `1 − R`, where R is predicted recall from the spacing data. Due cards rank by how overdue they are, relative to their interval (as in Anki). |
| **CodeRelevance** (codebase questions only) | How much this code matters to you now | Four terms plus a bonus, below |
| **DeckFit** | Whether this deck's questions get answered | The deck's answer rate, with skips counted against it |
| **Novelty** | A little exploration | Small credit for never-seen questions |

CodeRelevance, itself a weighted sum:

| Term | Weight | Signal | Source |
|---|---|---|---|
| Recency | 0.35 | The agent just edited or read it. Halves every day. | Hook events |
| Centrality | 0.25 | How many other files depend on it (PageRank on the reference graph) | Symbols index (2.11); until then, how many files mention it |
| Hotspot | 0.20 | Changes often relative to its size | Git churn. Relative churn predicted defects better than absolute churn (Nagappan & Ball) |
| Not yours | 0.20 | Share of its lines you didn't write; the agent's lines count as not yours | `git blame` author vs your git email, plus Meanwhile's record of agent edits |
| Bonus | +0.1 | Files you edit yourself | FSEvents edits outside agent turns |

Plus a **difficulty controller:**
- Rolling accuracy above 90%: lean toward new and harder questions.
- Below 75%: lean toward reviews.

The 85% "sweet spot" comes from machine-learning theory, so it's a target to tune, not a law.

All weights are starting priors. They live in the config file (task 5.1), and Phase 6 tunes them on logged data.

**Why the "not yours" signal matters:** Anthropic's randomized trial (January 2026, about 52 developers) found that developers using AI assistance scored 17% lower on a comprehension quiz about the library they had just used, without being significantly faster. METR (July 2025) found experienced developers took 19% longer with AI while believing they were 20% faster. Code the agent wrote is the code you're most likely not to understand.

### Spacing: keep the ladder, switch to FSRS later

The 1/2/4/7/14/30/60-day ladder stays. Every answer is already logged with its confidence, which is what FSRS needs. After about 1,000 answers, fit FSRS parameters on them and use its recall curve for `Need`.

### What to log so the weights can be tuned

A new `shown` table, one row per question shown:
- question id, version and deck
- the evidence blob hashes
- shown time, answer time and how long it took
- outcome: right, wrong, skipped, timed out or reported
- confidence
- predicted R, and every score term at the time
- whether the turn ended while it was open
- whether the question later went stale

## Task list (revised)

Order changed from the original plan: the provider layer and access come first, because every other task depends on them.

| # | Task | Size | Done when |
|---|---|---|---|
| 2.0 | **Access spike:** run the indexer as a helper started by the hook, and check it can read a repo under `~/Desktop` from launchd's side; fall back to hook-only evidence | S | A repo on the Desktop gets indexed with no permission prompt, or the fallback is in place |
| 2.1 | **Provider layer:** a `QuestionModel` protocol; `codex exec` first, using the 0.5 spike's lessons (structured output, stdin closed, `MEANWHILE_INTERNAL`); `claude -p` second; a queue with the per-turn and daily budget; API keys in Keychain later | M | A question comes back through `codex exec` from the app in under 10 s, and the budget is enforced |
| 2.2 | **Repo opt-in:** "Turn on codebase questions for acme-api?" in the notch; detect empty repos | S | A new repo shows the prompt once |
| 2.3 | **Index core:** file map by blob hash, exclusions, the three change-detection layers, branch tags | L | A large repo (Linux) indexes in under a minute; a branch switch updates in under a second |
| 2.4 | **Docs and git:** docs by heading in FTS5 (`detail=column`), mentions; bounded history, churn, authorship, `blame -L` on demand | M | FTS finds the doc chunks for a touched path; churn and "not yours" exist per file |
| 2.5 | **Evidence packs** (about 6,000 tokens) with secret redaction | M | Packs stay in budget; no secrets leak in fixture repos |
| 2.6 | **Generators:** live diff, post-turn "why", primer (repo card plus orientation questions), into a question pool keyed by evidence hashes | L | Questions about your real repos land in the pool |
| 2.7 | **Validator and staleness:** quotes match, evidence resolves, one right answer, notch limits; stale on blob change | M | Bad fixtures are rejected; changed code retires its questions |
| 2.8 | **Selection v2:** the rules and priority score above, the `shown` log, the difficulty controller | M | Unit tests for every rule; the score terms are logged |
| 2.9 | **Context score** gates codebase questions | S | Thin evidence never yields a codebase question |
| 2.10 | **Predictions** ("which file first?", "tests pass first try?") and the **"this question is wrong"** button | M | Predictions resolve live; reports retire cards |
| 2.11 | **Symbols and repo map:** definitions and references, PageRank, personalized to touched files; feeds Centrality and the 1,500-token map | L | The map near a touched file fits its budget and names the right neighbors |
| **Exit** | 16 of 20 codebase questions on your repos judged correct and worth asking | | |

## Decisions (2026-10-19)

1. **Repos in Desktop, Documents and Downloads:** the indexer runs as a helper started by `meanwhile-hook`, so it inherits the agent terminal's access. If that fails, Meanwhile uses only what hooks send.
2. **Turning a repo on:** the notch asks once per repo: "Turn on codebase questions for acme-api?" (Yes / Not now / Never).
3. **Daily generation budget:** 20 calls a day on your Codex plan, adjustable in the config file. On top of the per-turn limit of one live call and one post-turn call.
4. **Why a question was picked:** shown in the notch as one small grey line under the deck chip, built from the biggest score terms, e.g. "Agent changed auth.ts 3 min ago · you didn't write it".

Decided without asking (technical, reversible):
- Symbols come last (2.11). Docs, git and what the agent read carry the first questions.
- No embeddings or vector database in Phase 2 (question-engine.md, "Alternatives considered").

## Sources

- Index and scaling:
  - Continue indexing: https://github.com/continuedev/continue/blob/main/core/indexing/README.md
  - GitHub code search: https://github.blog/engineering/architecture-optimization/the-technology-behind-githubs-new-code-search/ and https://docs.github.com/en/search-github/github-code-search/about-github-code-search
  - Git fsmonitor: https://github.blog/engineering/improve-git-monorepo-performance-with-a-file-system-monitor/
  - Git commit-graph: https://git-scm.com/docs/commit-graph
  - Aider repo map: https://aider.chat/2023/10/22/repomap.html
  - SQLite FTS5: https://www.sqlite.org/fts5.html
  - Cursor indexing: https://cursor.com/blog/secure-codebase-indexing
- Selection:
  - FSRS optimal retention: https://github.com/open-spaced-repetition/fsrs4anki/wiki/The-optimal-retention
  - Duolingo half-life regression: https://preview.aclanthology.org/landing_page/P16-1174
  - Interleaving meta-analysis: https://www.psychologie.uni-wuerzburg.de/fileadmin/06020400/2019/Brunmair_Richter_in_press__2019_META-ANALYSIS_OF_INTERLEAVED_LEARNING.pdf
  - The 85% rule: https://pmc.ncbi.nlm.nih.gov/articles/PMC6831579
  - Relative churn: https://www.st.cs.uni-saarland.de/edu/recommendation-systems/papers/ICSE05Churn.pdf
  - "Don't Touch My Code": https://www.microsoft.com/en-us/research/?p=161465
- Comprehension debt:
  - Anthropic trial: https://www.anthropic.com/research/AI-assistance-coding-skills
  - METR study: https://metr.org/blog/2025-07-10-early-2025-ai-experienced-os-dev-study/
- Interruptions: https://www.erichorvitz.com/CHI_2007_Iqbal_Horvitz.pdf
