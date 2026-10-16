#!/usr/bin/env python3
"""Turn one recorded agent session into a test fixture.

    scripts/extract_fixture.py                       # list sessions in the recording
    scripts/extract_fixture.py <session_id> <out>    # write that session as NDJSON

Reads ~/Library/Application Support/Meanwhile/debug/events.ndjson. Replaces the home
directory with /Users/dev, the username with dev, and trims long strings so fixtures stay small and anonymous.
"""
import getpass
import json
import os
import sys

RECORDING = os.path.expanduser("~/Library/Application Support/Meanwhile/debug/events.ndjson")
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


def main():
    rows = [json.loads(line) for line in open(RECORDING) if line.strip()]
    if len(sys.argv) == 1:
        sessions = {}
        for row in rows:
            sid = row.get("payload", {}).get("session_id")
            if sid:
                s = sessions.setdefault(sid, {"agent": row["agent"], "events": 0, "first": row["ts"]})
                s["events"] += 1
        for sid, s in sessions.items():
            print(f'{s["first"]}  {s["agent"]:<6} {s["events"]:>3} events  {sid}')
        return
    session_id, out = sys.argv[1], sys.argv[2]
    picked = [clean(r) for r in rows if r.get("payload", {}).get("session_id") == session_id]
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w") as f:
        for row in picked:
            f.write(json.dumps(row, ensure_ascii=False, sort_keys=True) + "\n")
    print(f"wrote {len(picked)} events to {out}")


if __name__ == "__main__":
    main()
