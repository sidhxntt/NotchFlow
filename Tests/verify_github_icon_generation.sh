#!/usr/bin/env bash
# Catches the public GitHub icon being generated at its retired docs/ location.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/notchflow-icon-test.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/scripts"
mkdir -p "$tmp_dir/docs"
mkdir -p "$tmp_dir/NotchFlow/Resources/Assets.xcassets/AppIcon.appiconset"
cp "$repo_root/scripts/generate_icon.swift" "$tmp_dir/scripts/generate_icon.swift"

(
  cd "$tmp_dir"
  swift scripts/generate_icon.swift >/dev/null
)

test -s "$tmp_dir/.github/icon.png"
test ! -e "$tmp_dir/docs/icon.png"
