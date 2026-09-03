#!/usr/bin/env bash
# Confirms the running Debug app accepts approval-hook connections for both
# Claude Code and Terminal Codex. A refused listener makes the CLIs fail open,
# so merely finding stale socket files is not sufficient.
set -euo pipefail

pid="$(pgrep -x NotchFlow | head -n1)"
[ -n "$pid" ] || { echo "NotchFlow is not running." >&2; exit 1; }

/usr/bin/python3 - <<'PY'
import socket
import sys
import time

paths = (
    "/Users/sidhxntt/Library/Application Support/NotchFlow/claude-approvals.sock",
    "/Users/sidhxntt/Library/Application Support/NotchFlow/notch.sock",
)

deadline = time.monotonic() + 10
while True:
    failed = []
    for path in paths:
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.settimeout(1)
        try:
            client.connect(path)
        except OSError as error:
            failed.append(f"{path}: {error}")
        finally:
            client.close()

    if not failed:
        for path in paths:
            print(f"accepting: {path}")
        break
    if time.monotonic() >= deadline:
        print("NotchFlow approval listener unavailable: " + "; ".join(failed), file=sys.stderr)
        sys.exit(1)
    time.sleep(0.25)
PY
