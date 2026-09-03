#!/usr/bin/env bash
# Ensures NotchFlow is the sole application identity in tracked content and
# installed agent-hook registrations. Keep this separate from runtime checks:
# it catches an obsolete path or user-visible label before it reaches a release.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
legacy_pattern='agent[ -]?notch'

if tracked_matches="$(git -C "$repo_root" grep -I -n -i -E "$legacy_pattern" -- . 2>/dev/null)"; then
    printf 'Obsolete product references remain in tracked content:\n%s\n' "$tracked_matches" >&2
    exit 1
fi

for configuration in \
    "$HOME/.codex/hooks.json" \
    "$HOME/.codex/config.toml" \
    "$HOME/.codex/notchflow-codex-hook.py" \
    "$HOME/.claude/settings.json" \
    "$HOME/.claude/notchflow/notchflow-hook.py"; do
    [ -e "$configuration" ] || {
        printf 'Expected NotchFlow integration artifact is missing: %s\n' "$configuration" >&2
        exit 1
    }
    if matches="$(rg -n -i -e "$legacy_pattern" "$configuration" 2>/dev/null)"; then
        printf 'Obsolete product reference remains in %s:\n%s\n' "$configuration" "$matches" >&2
        exit 1
    fi
done

legacy_name='Agent''Notch'
if [ -e "$HOME/Library/Application Support/$legacy_name" ]; then
    printf 'Obsolete product support directory remains.\n' >&2
    exit 1
fi

if [ -e "$HOME/.codex/notch-codex-hook.py" ]; then
    printf 'Obsolete Codex hook script remains.\n' >&2
    exit 1
fi

if [ -e "$HOME/.claude/$legacy_name" ]; then
    printf 'Obsolete Claude hook directory remains.\n' >&2
    exit 1
fi

if [ ! -d "$HOME/Library/Application Support/NotchFlow" ]; then
    printf 'NotchFlow support directory is missing.\n' >&2
    exit 1
fi

echo 'NotchFlow identity verification passed.'
