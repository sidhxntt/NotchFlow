#!/usr/bin/env bash
# Exercises the shared Conventional Commit verifier used by pull requests.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
script="$repo_root/scripts/verify-conventional-commits.sh"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/notchflow-commit-message-test.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

fail() {
  printf 'conventional commit check failed: %s\n' "$*" >&2
  exit 1
}

new_repo() {
  local dir="$tmp_dir/repo"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.name "NotchFlow tests"
  git -C "$dir" config user.email "tests@example.invalid"
  printf 'initial\n' > "$dir/history.txt"
  git -C "$dir" add history.txt
  git -C "$dir" commit -qm 'chore: initial setup'
  printf '%s\n' "$dir"
}

commit() {
  local dir="$1"
  local subject="$2"
  printf '%s\n' "$subject" >> "$dir/history.txt"
  git -C "$dir" add history.txt
  git -C "$dir" commit -qm "$subject"
}

repo="$(new_repo)"
base="$(git -C "$repo" rev-parse HEAD)"
commit "$repo" 'feat(settings): add a focus timer'
commit "$repo" 'fix!: remove the retired import format'

(cd "$repo" && "$script" "$base" HEAD 'feat: add focus controls') \
  || fail 'valid commit subjects were rejected'

commit "$repo" 'updated release configuration'
if (cd "$repo" && "$script" "$base" HEAD 'fix: validate commit rules'); then
  fail 'an invalid commit subject was accepted'
fi

valid_base="$(git -C "$repo" rev-parse HEAD)"
if (cd "$repo" && "$script" "$valid_base" HEAD 'invalid pull request title'); then
  fail 'an invalid pull request title was accepted'
fi

printf 'Conventional Commit validation checks passed.\n'
