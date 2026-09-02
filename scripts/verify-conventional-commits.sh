#!/usr/bin/env bash
# Reject pull requests whose commits or squash-merge title lack a Conventional
# Commit subject. The release tagger uses these subjects for semantic versioning.
set -euo pipefail

base="${1:?Usage: verify-conventional-commits.sh <base> <head> <pr-title>}"
head="${2:?Usage: verify-conventional-commits.sh <base> <head> <pr-title>}"
pr_title="${3:?Usage: verify-conventional-commits.sh <base> <head> <pr-title>}"
pattern='^[a-z][a-z0-9-]*(\([A-Za-z0-9._/-]+\))?!?: .+$'

die() {
  printf 'invalid Conventional Commit: %s\n' "$*" >&2
  exit 1
}

git rev-parse --verify -q "${base}^{commit}" >/dev/null \
  || die "base ${base} is not a commit"
git rev-parse --verify -q "${head}^{commit}" >/dev/null \
  || die "head ${head} is not a commit"
git merge-base --is-ancestor "$base" "$head" \
  || die "base ${base} is not an ancestor of ${head}"

is_valid() {
  [[ "$1" =~ $pattern ]]
}

while IFS= read -r subject; do
  [ -n "$subject" ] || continue
  is_valid "$subject" || die "commit subject '$subject'"
done < <(git log --format=%s --no-merges "${base}..${head}")

is_valid "$pr_title" || die "pull request title '$pr_title'"
