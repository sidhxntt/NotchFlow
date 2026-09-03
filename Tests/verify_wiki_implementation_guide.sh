#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
guide="$repo_root/docs/wiki/implementation-guide.md"

test -s "$guide"

for required in \
  'AppDelegate.swift' \
  'IntentEngine.swift' \
  'CodexAppServerBridge' \
  'CodexTerminalHookBridge' \
  'ClaudeHookBridge' \
  'MediaRemoteAdapterController' \
  'ClipboardHistoryService' \
  'SystemUtilityService' \
  'LicenseService' \
  'UpdateArtifactVerifier' \
  'verify_approval_bridges.sh'; do
  grep -Fq "$required" "$guide"
done

grep -Fq 'Engineering-Implementation-Guide.md' "$repo_root/scripts/render-github-wiki.mjs"
grep -Fq 'Engineering-Implementation-Guide' "$repo_root/docs/wiki/_Sidebar.md"
grep -Fq 'implementation-guide.md' "$repo_root/wiki.md"

echo 'wiki implementation guide verification passed.'
