#!/bin/zsh
# Task 0.5 provider spike: ask `claude -p` and `codex exec` for one question, headless,
# with JSON output, and time each call.
#
#     scripts/provider_spike.sh [claude|codex|both] [runs]
#
# Runs from an empty temp directory so neither CLI picks up this repo's CLAUDE.md or
# AGENTS.md, closes stdin (codex exec waits forever on an open stdin pipe), and sets MEANWHILE_INTERNAL=1 so meanwhile-hook ignores these calls (task 0.6).
set -u
which_provider=${1:-both}
runs=${2:-1}
repo=${0:A:h:h}

if (( $# > 2 )); then
  print -u2 "usage: ${0:t} [claude|codex|both] [positive-runs]"
  exit 2
fi
case $which_provider in
  claude|codex|both) ;;
  *) print -u2 "usage: ${0:t} [claude|codex|both] [positive-runs]"; exit 2 ;;
esac
if [[ $runs != <-> || $runs -lt 1 ]]; then
  print -u2 "runs must be a positive integer"
  exit 2
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export MEANWHILE_INTERNAL=1

# A small evidence pack: one real file from this repo, as the engine would send it.
evidence=$(cat "$repo/Sources/MeanwhileIPC/Spool.swift")
prompt="You write one multiple-choice question that tests whether a developer understands the code below.
Use only facts in the evidence. Question at most 120 characters, 4 options of at most 50 characters each, exactly one correct.
Quote the line from the evidence that proves the answer.

Evidence (Sources/MeanwhileIPC/Spool.swift):
$evidence"

cat > "$work/schema.json" <<'EOF'
{
  "type": "object",
  "additionalProperties": false,
  "required": ["question", "options", "correct", "quote"],
  "properties": {
    "question": {"type": "string"},
    "options": {"type": "array", "items": {"type": "string"}, "minItems": 4, "maxItems": 4},
    "correct": {"type": "integer", "minimum": 0, "maximum": 3},
    "quote": {"type": "string"}
  }
}
EOF

run_claude() {
  rm -f "$work/out.json" "$work/err.txt"
  (cd "$work" && claude -p "$prompt" \
    --output-format json --json-schema "$(cat schema.json)" \
    --tools "" --no-session-persistence --model haiku) < /dev/null > "$work/out.json" 2> "$work/err.txt" || return
  # The structured answer is in .structured_output; fall back to .result.
  python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
if d.get("is_error"): sys.exit("  error: " + str(d.get("result")))
print(json.dumps(d.get("structured_output") or d.get("result"), ensure_ascii=False))
print("  cost_usd:", d.get("total_cost_usd"), " api_ms:", d.get("duration_api_ms"))' "$work/out.json"
}

run_codex() {
  rm -f "$work/last.txt" "$work/err.txt"
  (cd "$work" && codex exec --skip-git-repo-check --ephemeral --sandbox read-only \
    --output-schema schema.json -o last.txt "$prompt") < /dev/null > /dev/null 2> "$work/err.txt" || return
  cat "$work/last.txt"
  echo
}

time_it() {
  local name=$1
  for i in $(seq 1 "$runs"); do
    local start=$EPOCHREALTIME
    if "run_$name"; then
      printf '%s run %d: %.1f s\n\n' "$name" "$i" $(( EPOCHREALTIME - start ))
    else
      printf '%s run %d failed:\n' "$name" "$i"; tail -5 "$work/err.txt"
    fi
  done
}

zmodload zsh/datetime
case $which_provider in
  claude) time_it claude ;;
  codex) time_it codex ;;
  both) time_it claude; time_it codex ;;
esac
