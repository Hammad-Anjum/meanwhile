#!/usr/bin/env python3
"""Checks Meanwhile pack JSON files against docs/packs.md. Usage: scripts/validate_pack.py FILE..."""
import json
import re
import sys

STACKS = {"swift", "typescript", "javascript", "react", "python", "go", "rust"}


def check(path):
    problems = []
    try:
        pack = json.load(open(path))
    except Exception as error:  # noqa: BLE001
        return [f"not valid JSON: {error}"]
    p = problems.append
    if pack.get("format") != 1: p("format must be 1")
    pid = pack.get("id", "")
    if not re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", pid): p(f"bad pack id {pid!r}")
    for key in ("title", "description"):
        if not isinstance(pack.get(key), str) or not pack[key]: p(f"missing {key}")
    kind = pack.get("kind")
    if kind not in ("generic", "stack"): p("kind must be generic or stack")
    stacks = pack.get("stacks", [])
    if kind == "stack" and (not stacks or not set(stacks) <= STACKS): p(f"stack pack needs stacks from {sorted(STACKS)}")
    if kind == "generic" and stacks: p("generic pack must have empty stacks")
    topics = {t.get("id") for t in pack.get("topics", [])}
    if not 4 <= len(topics) <= 6: p(f"{len(topics)} topics; want 4–6")
    ids = set()
    used_topics = set()
    answers = []
    tf = 0
    for i, card in enumerate(pack.get("cards", [])):
        where = card.get("id", f"card {i}")
        if card.get("id") in ids: p(f"{where}: duplicate id")
        ids.add(card.get("id"))
        if not str(card.get("id", "")).startswith(f"{pid}.{card.get('topic')}."): p(f"{where}: id must be <pack>.<topic>.<n>")
        if card.get("topic") not in topics: p(f"{where}: unknown topic")
        used_topics.add(card.get("topic"))
        q = card.get("question", "")
        if not q or len(q) > 120: p(f"{where}: question length {len(q)} (max 120)")
        e = card.get("explanation", "")
        if not e or len(e) > 220: p(f"{where}: explanation length {len(e)} (max 220)")
        if "source" in card and not str(card["source"]).startswith("https://"): p(f"{where}: source must be https")
        t = card.get("type")
        if t == "multipleChoice":
            options = card.get("options", [])
            if len(options) != 4: p(f"{where}: needs exactly 4 options")
            if len(set(options)) != len(options): p(f"{where}: duplicate options")
            for o in options:
                if not isinstance(o, str) or not o or len(o) > 50: p(f"{where}: option too long/empty: {o!r}")
            a = card.get("answer")
            if not isinstance(a, int) or isinstance(a, bool) or not 0 <= a < len(options): p(f"{where}: answer must be an option index")
            else: answers.append(a)
        elif t == "trueFalse":
            tf += 1
            if not isinstance(card.get("answer"), bool): p(f"{where}: answer must be true/false")
        else:
            p(f"{where}: unknown type {t!r}")
    n = len(pack.get("cards", []))
    if n < 20: p(f"only {n} cards")
    if topics - used_topics: p(f"topics without cards: {sorted(topics - used_topics)}")
    if answers and max(answers.count(k) for k in range(4)) > 0.5 * len(answers): p("correct option position not varied enough")
    if n and tf / n > 0.5: p(f"too many true/false ({tf}/{n})")
    return problems


ok = True
for path in sys.argv[1:]:
    problems = check(path)
    print(f"{path}: {'OK' if not problems else str(len(problems)) + ' problem(s)'}")
    for problem in problems:
        print("  -", problem)
    ok = ok and not problems
sys.exit(0 if ok else 1)
