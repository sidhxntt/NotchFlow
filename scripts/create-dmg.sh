#!/usr/bin/env bash
# Creates the direct-download artifact without modifying the already-signed app.
# Usage: scripts/create-dmg.sh <signed-NotchFlow.app> <output.dmg>
set -euo pipefail

APP="${1:-}"
OUTPUT="${2:-}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ -n "$APP" ] && [ -n "$OUTPUT" ] \
  || die "Usage: scripts/create-dmg.sh <signed-NotchFlow.app> <output.dmg>"
[ -d "$APP" ] || die "Not an app bundle: $APP"
case "$OUTPUT" in
  *.dmg) ;;
  *) die "Output must end in .dmg: $OUTPUT" ;;
esac

asset_name="$(basename "$OUTPUT")"
if [[ "$asset_name" =~ ^NotchFlow-v([0-9]+\.[0-9]+\.[0-9]+)-arm64\.dmg$ ]]; then
  release_version="${BASH_REMATCH[1]}"
else
  die "Output must be NotchFlow-vX.Y.Z-arm64.dmg: $OUTPUT"
fi

info_plist="$APP/Contents/Info.plist"
[ -f "$info_plist" ] || die "App bundle has no Info.plist: $APP"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")" \
  || die "Could not read CFBundleIdentifier from $info_plist"
marketing_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")" \
  || die "Could not read CFBundleShortVersionString from $info_plist"
build_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")" \
  || die "Could not read CFBundleVersion from $info_plist"
[ "$bundle_id" = "com.notchflow.app" ] \
  || die "Unexpected bundle identifier: $bundle_id"
[ "$marketing_version" = "$release_version" ] \
  || die "DMG version $release_version does not match app marketing version $marketing_version"
[ "$build_version" = "$release_version" ] \
  || die "DMG version $release_version does not match app build version $build_version"

case "$OUTPUT" in
  /*) ;;
  *) OUTPUT="$PWD/$OUTPUT" ;;
esac
[ -d "$(dirname "$OUTPUT")" ] || die "Output directory does not exist: $(dirname "$OUTPUT")"
[ ! -e "$OUTPUT" ] || die "Refusing to overwrite existing artifact: $OUTPUT"

# Catch a broken bundle before copying it. From here on, only the staging copy
# is touched; the signed source app is never altered after signing.
codesign --verify --deep --strict --verbose=2 "$APP" >/dev/null

STAGING="$(mktemp -d "${TMPDIR:-/tmp}/notchflow-dmg.XXXXXX")"
cleanup() { rm -rf "$STAGING"; }
trap cleanup EXIT

ditto "$APP" "$STAGING/NotchFlow.app"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
  -volname "NotchFlow" \
  -srcfolder "$STAGING" \
  -format UDZO \
  "$OUTPUT" >/dev/null
hdiutil verify "$OUTPUT" >/dev/null

printf 'Created %s\n' "$OUTPUT"
