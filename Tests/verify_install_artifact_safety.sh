#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export NOTCHFLOW_INSTALL_LIBRARY_ONLY=1
# shellcheck source=../install.sh
source "$ROOT/install.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

make_release() {
  local path="$1"
  local tag="$2"
  local asset_name="$3"
  local asset_url="$4"
  cat > "$path" <<JSON
{"tag_name":"$tag","assets":[{"name":"$asset_name","browser_download_url":"$asset_url"}]}
JSON
}

release="$TMP/release.json"
expected_name="NotchFlow-v1.2.3-arm64.dmg"
expected_url="https://github.com/sidhxntt/NotchFlow/releases/download/v1.2.3/$expected_name"
make_release "$release" "v1.2.3" "$expected_name" "$expected_url"

version="$(release_version "$release")" || fail "valid release tag was rejected"
[ "$version" = "1.2.3" ] || fail "release version was not parsed exactly"
url="$(select_release_asset "$release" "v$version" "$expected_name")" || fail "exact DMG was not selected"
[ "$url" = "$expected_url" ] || fail "selected an unexpected download URL"

for malformed in "1.2.3" "v1.2" "v1.2.3-beta" "v1.2.3/../../bad"; do
  make_release "$release" "$malformed" "$expected_name" "$expected_url"
  if release_version "$release" >/dev/null 2>&1; then
    fail "accepted malformed release tag: $malformed"
  fi
done

make_release "$release" "v1.2.3" "renamed-$expected_name" "$expected_url"
if select_release_asset "$release" "v1.2.3" "$expected_name" >/dev/null 2>&1; then
  fail "accepted a suffix-matching DMG"
fi

make_release "$release" "v1.2.3" "$expected_name" "https://attacker.invalid/$expected_name"
if select_release_asset "$release" "v1.2.3" "$expected_name" >/dev/null 2>&1; then
  fail "accepted a release asset outside the configured GitHub repository"
fi

cat > "$release" <<JSON
{"tag_name":"v1.2.3","assets":[{"name":"$expected_name","browser_download_url":"$expected_url"},{"name":"$expected_name","browser_download_url":"$expected_url"}]}
JSON
if select_release_asset "$release" "v1.2.3" "$expected_name" >/dev/null 2>&1; then
  fail "accepted duplicate exact release assets"
fi

# Real macOS verification must reject an unsigned fixture, without changing an
# existing destination. This exercises the actual codesign/Gatekeeper boundary.
unsigned="$TMP/Unsigned.app"
mkdir -p "$unsigned/Contents"
/usr/bin/plutil -create xml1 "$unsigned/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleIdentifier -string com.notchflow.app "$unsigned/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleShortVersionString -string 1.2.3 "$unsigned/Contents/Info.plist"
if verify_app "$unsigned" "1.2.3" >/dev/null 2>&1; then
  fail "accepted an unsigned app fixture"
fi

# Isolate replacement behavior from the external trust service: verification
# succeeds for the first candidate copy, then the real transaction must preserve
# extended attributes and replace only after that success.
verify_app() { return 0; }
INSTALL_DIR="$TMP/Applications"
mkdir -p "$INSTALL_DIR"
source_app="$TMP/NotchFlow.app"
mkdir -p "$source_app/Contents"
printf 'new' > "$source_app/Contents/marker"
/usr/bin/xattr -w com.apple.quarantine '0081;fixture;NotchFlow;' "$source_app"
destination="$INSTALL_DIR/NotchFlow.app"
mkdir -p "$destination/Contents"
printf 'old' > "$destination/Contents/marker"

install_verified_candidate "$source_app" "$destination" "1.2.3"
[ "$(cat "$destination/Contents/marker")" = "new" ] || fail "verified candidate did not replace the old app"
/usr/bin/xattr -p com.apple.quarantine "$destination" >/dev/null 2>&1 \
  || fail "installer stripped quarantine from the verified app"

# A failed verification is checked before any destination mutation.
rejected="$TMP/Rejected.app"
mkdir -p "$rejected/Contents"
printf 'rejected' > "$rejected/Contents/marker"
printf 'old-again' > "$destination/Contents/marker"
verify_app() { return 1; }
if install_verified_candidate "$rejected" "$destination" "1.2.3" >/dev/null 2>&1; then
  fail "installed a candidate that failed verification"
fi
[ "$(cat "$destination/Contents/marker")" = "old-again" ] \
  || fail "verification failure mutated the installed app"

printf 'Installer artifact safety checks passed\n'
