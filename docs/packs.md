# Meanwhile pack format (v1)

A pack is one JSON file: a deck of short questions shown in the MacBook notch while a coding agent works (30–90 s waits). The user answers by clicking, so every card must be answerable in a few seconds from memory or reasoning, with no code to read beyond one short line.

Bundled packs live in `Sources/MeanwhileCore/Resources/Packs/` and load through `PackLibrary`. Generic packs apply to every repo and can be turned off from the menu bar's **Decks** menu. Stack packs follow the repo being worked on: `StackDetector` reads its build files (`Package.swift`, `package.json`, `pyproject.toml`, `go.mod`, `Cargo.toml`…) at the root and one level down. Check a pack with `scripts/validate_pack.py FILE…`; the app runs the same core checks (`Pack.problems()`) and skips invalid files.

```json
{
  "format": 1,
  "id": "llm-fundamentals",
  "title": "LLM fundamentals",
  "description": "One sentence shown in the deck list.",
  "kind": "generic",
  "stacks": [],
  "topics": [
    { "id": "tokens", "title": "Tokens and context" }
  ],
  "cards": [
    {
      "id": "llm-fundamentals.tokens.1",
      "topic": "tokens",
      "type": "multipleChoice",
      "question": "Roughly how many English words fit in 1,000 tokens?",
      "options": ["About 750", "About 250", "About 1,000", "About 2,000"],
      "answer": 0,
      "explanation": "A token averages about 4 characters of English, so 1,000 tokens is roughly 750 words."
    },
    {
      "id": "llm-fundamentals.tokens.2",
      "topic": "tokens",
      "type": "trueFalse",
      "question": "A model's context window limits input and output tokens combined.",
      "answer": true,
      "explanation": "Prompt and generated tokens share the same window, so long prompts leave less room for the reply."
    }
  ]
}
```

## Rules (checked by `validate_pack.py`)

- `kind`: `"generic"` (topic decks) or `"stack"` (follows the tech stack of the repo being worked on).
- `stacks`: for `stack` packs, the stack ids the pack applies to, from: `swift`, `typescript`, `javascript`, `react`, `python`, `go`, `rust`. Empty for generic packs.
- `id`s: pack id is lowercase-kebab; card ids are `<pack id>.<topic id>.<n>`, unique.
- Every card's `topic` must be one of the pack's topics. 4–6 topics per pack, cards spread across them.
- `type` is `multipleChoice` or `trueFalse`.
  - `multipleChoice`: exactly 4 `options`, each ≤ 50 characters, `answer` is the 0-based index of the single correct option. Vary the correct position (don't always use 0). Distractors must be plausible but clearly wrong to an expert.
  - `trueFalse`: `answer` is `true` or `false`. Mix both; about 40% of a pack can be true/false.
- `question` ≤ 120 characters. `explanation` ≤ 220 characters: why the answer is right, teaching something.
- Optional `source`: an https URL to official docs or a well-known reference backing the card.

## Content rules

- Accurate and durable: prefer concepts that won't rot in a year over version trivia. No made-up numbers; if a figure is approximate, say "roughly".
- One clearly correct answer. No trick questions, no "all of the above", no negations that confuse ("Which is NOT…" sparingly, at most 2 per pack).
- Practical for someone who builds software with AI agents: favor things they'll meet in real work.
- Plain English, short sentences. Inline code in backticks only when short.
