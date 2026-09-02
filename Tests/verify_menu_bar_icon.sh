#!/usr/bin/env bash
# Verifies the running app owns a real NSStatusItem. This catches a menu icon
# that has been removed from the user's menu bar even when the preference says
# it is shown.
set -euo pipefail

pid="$(pgrep -x NotchFlow | head -n1)"
[ -n "$pid" ] || { echo "NotchFlow is not running." >&2; exit 1; }
trap 'kill -CONT "$pid" >/dev/null 2>&1 || true' EXIT

output="$(lldb -p "$pid" \
  -o 'expression -l objc++ -- (NSUInteger)[(NSPointerArray *)[[NSStatusBar systemStatusBar] valueForKey:@"_statusItems"] count]' \
  -o detach -o quit)"
count="$(printf '%s\n' "$output" | sed -n 's/.*= \([0-9][0-9]*\)$/\1/p' | tail -n1)"

case "$count" in
  ''|0) echo "NotchFlow has no visible menu-bar status item." >&2; exit 1 ;;
  *) echo "NotchFlow menu-bar status items: $count" ;;
esac
