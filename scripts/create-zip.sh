#!/usr/bin/env bash
# Creates the optional fallback archive without modifying the signed app.
# Usage: scripts/create-zip.sh <signed-NotchFlow.app> <output.zip>
set -euo pipefail

APP="${1:-}"
OUTPUT="${2:-}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ -n "$APP" ] && [ -n "$OUTPUT" ] \
  || die "Usage: scripts/create-zip.sh <signed-NotchFlow.app> <output.zip>"
[ -d "$APP" ] || die "Not an app bundle: $APP"
case "$OUTPUT" in
  *.zip) ;;
  *) die "Output must end in .zip: $OUTPUT" ;;
esac

asset_name="$(basename "$OUTPUT")"
if [[ "$asset_name" =~ ^NotchFlow-v([0-9]+\.[0-9]+\.[0-9]+)-arm64\.zip$ ]]; then
  release_version="${BASH_REMATCH[1]}"
else
  die "Output must be NotchFlow-vX.Y.Z-arm64.zip: $OUTPUT"
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
  || die "ZIP version $release_version does not match app marketing version $marketing_version"
[ "$build_version" = "$release_version" ] \
  || die "ZIP version $release_version does not match app build version $build_version"

case "$OUTPUT" in
  /*) ;;
  *) OUTPUT="$PWD/$OUTPUT" ;;
esac
[ -d "$(dirname "$OUTPUT")" ] || die "Output directory does not exist: $(dirname "$OUTPUT")"
[ ! -e "$OUTPUT" ] || die "Refusing to overwrite existing artifact: $OUTPUT"

# Validate before archiving. `ditto` preserves macOS bundle metadata and code
# signatures; the source app is never changed.
codesign --verify --deep --strict --verbose=2 "$APP" >/dev/null
ditto -c -k --keepParent "$APP" "$OUTPUT"

printf 'Created %s\n' "$OUTPUT"
