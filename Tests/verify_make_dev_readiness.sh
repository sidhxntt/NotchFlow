#!/usr/bin/env bash
# `make dev` is the developer's launch command. It may not return while the
# app is merely alive: its menu bar and both approval transports must be ready.
set -euo pipefail

make dev
bash Tests/verify_menu_bar_icon.sh

/usr/bin/python3 - <<'PY'
import socket
import sys

for path in (
    "/Users/sidhxntt/Library/Application Support/NotchFlow/claude-approvals.sock",
    "/Users/sidhxntt/Library/Application Support/NotchFlow/notch.sock",
):
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(1)
    try:
        client.connect(path)
    except OSError as error:
        print(f"make dev returned before {path} was ready: {error}", file=sys.stderr)
        sys.exit(1)
    finally:
        client.close()
PY
