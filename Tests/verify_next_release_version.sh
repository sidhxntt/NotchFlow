#!/usr/bin/env bash
# Exercises the semantic version selected for an automatic release tag.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
script="$repo_root/scripts/next-release-version.sh"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/notchflow-next-release-version.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

fail() {
  printf 'next release version check failed: %s\n' "$*" >&2
  exit 1
}

new_repo() {
  local name="$1"
  local dir="$tmp_dir/$name"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.name "NotchFlow tests"
  git -C "$dir" config user.email "tests@example.invalid"
  printf 'initial\n' > "$dir/history.txt"
  git -C "$dir" add history.txt
  git -C "$dir" commit -qm 'chore: initial release'
  printf '%s\n' "$dir"
}

commit() {
  local dir="$1"
  local subject="$2"
  local body="${3:-}"
  printf '%s\n' "${subject}${body}" >> "$dir/history.txt"
  git -C "$dir" add history.txt
  git -C "$dir" commit -qm "$subject" ${body:+-m "$body"}
}

assert_version() {
  local expected="$1"
  local dir="$2"
  local actual
  actual="$(cd "$dir" && "$script")" || fail "script failed in $dir"
  [ "$actual" = "$expected" ] || fail "expected $expected, got $actual"
}

initial="$(new_repo initial)"
assert_version "0.1.0" "$initial"

patch="$(new_repo patch)"
git -C "$patch" tag v1.2.3
commit "$patch" 'fix: correct the updater label'
assert_version "1.2.4" "$patch"

minor="$(new_repo minor)"
git -C "$minor" tag v1.2.3
commit "$minor" 'feat: add a focus timer'
assert_version "1.3.0" "$minor"

major_subject="$(new_repo major-subject)"
git -C "$major_subject" tag v1.2.3
commit "$major_subject" 'feat!: replace the settings format'
assert_version "2.0.0" "$major_subject"

major_footer="$(new_repo major-footer)"
git -C "$major_footer" tag v1.2.3
commit "$major_footer" 'feat: simplify library import' $'\n\nBREAKING CHANGE: old imports are no longer supported'
assert_version "2.0.0" "$major_footer"

printf 'Automatic release version selection checks passed.\n'
