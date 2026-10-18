#!/usr/bin/env python3
"""Turn one recorded agent session into a test fixture.

    scripts/extract_fixture.py                       # list sessions in the recording
    scripts/extract_fixture.py <session_id> <out>    # write that session as NDJSON

Reads the current and previous rotated recordings under
~/Library/Application Support/Meanwhile/debug/. Replaces the home directory with
/Users/dev, the username with dev, and trims long strings so fixtures stay small and anonymous.
"""
import getpass
import json
import os
import sys
from pathlib import Path

RECORDING_DIRECTORY = Path(os.path.expanduser("~/Library/Application Support/Meanwhile/debug"))
RECORDINGS = [
    RECORDING_DIRECTORY / "events.previous.ndjson",
    RECORDING_DIRECTORY / "events.ndjson",
]
HOME = os.path.expanduser("~")
USER = getpass.getuser()
MAX_STRING = 2000


def clean(value):
    if isinstance(value, str):
        value = value.replace(HOME, "/Users/dev").replace(USER, "dev")
        return value if len(value) <= MAX_STRING else value[:MAX_STRING] + f"…[trimmed {len(value) - MAX_STRING} chars]"
    if isinstance(value, list):
        return [clean(v) for v in value]
    if isinstance(value, dict):
        return {k: clean(v) for k, v in value.items()}
    return value


def row_session_id(row):
    if not isinstance(row, dict):
        return None
    payload = row.get("payload")
    return payload.get("session_id") if isinstance(payload, dict) else None


def load_rows():
    rows = []
    found = False
    for path in RECORDINGS:
        if not path.exists():
            continue
        found = True
        with path.open(encoding="utf-8") as recording:
            for line_number, line in enumerate(recording, start=1):
                if not line.strip():
                    continue
                try:
                    rows.append(json.loads(line))
                except json.JSONDecodeError as error:
                    raise SystemExit(
                        f"invalid JSON in {path} at line {line_number}, column {error.colno}: {error.msg}"
                    ) from None
    if not found:
        raise SystemExit(f"recording not found: {RECORDINGS[-1]}")
    return rows


def main():
    if len(sys.argv) not in (1, 3):
        raise SystemExit(f"usage: {Path(sys.argv[0]).name} [<session_id> <output>]")

    rows = load_rows()
    if len(sys.argv) == 1:
        sessions = {}
        for row in rows:
            sid = row_session_id(row)
            if sid:
                s = sessions.setdefault(sid, {
                    "agent": row.get("agent", "?"),
                    "events": 0,
                    "first": row.get("ts", "?"),
                })
                s["events"] += 1
        for sid, s in sessions.items():
            print(f'{s["first"]}  {s["agent"]:<6} {s["events"]:>3} events  {sid}')
        return
    session_id, out = sys.argv[1], sys.argv[2]
    picked = [clean(r) for r in rows if row_session_id(r) == session_id]
    output = Path(out)
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8") as f:
        for row in picked:
            f.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")
    print(f"wrote {len(picked)} events to {out}")


if __name__ == "__main__":
    main()
