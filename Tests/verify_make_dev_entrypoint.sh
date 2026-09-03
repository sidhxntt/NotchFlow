#!/usr/bin/env bash
# Prevent the documented development target from drifting away from the
# repository's single build-and-run entrypoint.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
expected='./scripts/build_and_run.sh --verify'

if ! rg -F "$expected" "$repo_root/Makefile" >/dev/null; then
    printf 'make dev does not invoke %s\n' "$expected" >&2
    exit 1
fi

test -f "$repo_root/scripts/build_and_run.sh"
echo 'make dev entrypoint verification passed.'
