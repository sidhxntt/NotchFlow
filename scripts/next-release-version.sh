#!/usr/bin/env bash
# Print the semantic version for the next automatic NotchFlow release.
#
# Conventional Commit signals in commits since the latest vX.Y.Z tag decide
# the bump: BREAKING CHANGE / type! is major, feat is minor, everything else
# is a patch. The first release begins at 0.1.0.
set -euo pipefail

target="${1:-HEAD}"

die() {
  printf 'next release version: %s\n' "$*" >&2
  exit 1
}

git rev-parse --verify -q "${target}^{commit}" >/dev/null \
  || die "${target} is not a commit"

latest_tag="$({
  git tag --list 'v*' \
    | awk '/^v[0-9]+\.[0-9]+\.[0-9]+$/ { print }' \
    | sort -V \
    | tail -n 1
} || true)"

if [ -z "$latest_tag" ]; then
  printf '0.1.0\n'
  exit 0
fi

git merge-base --is-ancestor "$latest_tag" "$target" \
  || die "latest release tag ${latest_tag} is not an ancestor of ${target}"

version="${latest_tag#v}"
IFS=. read -r major minor patch <<< "$version"
messages="$(git log "${latest_tag}..${target}" --format=%B)"

if grep -Eq '(^[[:alnum:]_-]+(\([^)]+\))?!:|^BREAKING[ -]CHANGE:)' <<< "$messages"; then
  printf '%d.0.0\n' "$((major + 1))"
elif grep -Eq '^feat(\([^)]+\))?:' <<< "$messages"; then
  printf '%d.%d.0\n' "$major" "$((minor + 1))"
else
  printf '%d.%d.%d\n' "$major" "$minor" "$((patch + 1))"
fi
