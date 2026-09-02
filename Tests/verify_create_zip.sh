#!/usr/bin/env bash
# Catches a fallback archive that omits the app bundle or breaks its signature.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/notchflow-zip-test.XXXXXX")"
app="$tmp_dir/NotchFlow.app"
archive="$tmp_dir/NotchFlow-v1.2.3-arm64.zip"
extracted="$tmp_dir/extracted"
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$app/Contents/MacOS"
printf '#!/bin/sh\nexit 0\n' > "$app/Contents/MacOS/NotchFlow"
chmod +x "$app/Contents/MacOS/NotchFlow"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.notchflow.app</string>
  <key>CFBundleShortVersionString</key><string>1.2.3</string>
  <key>CFBundleVersion</key><string>1.2.3</string>
</dict></plist>
PLIST
codesign --force --sign - "$app" >/dev/null

bash "$repo_root/scripts/create-zip.sh" "$app" "$archive"

if bash "$repo_root/scripts/create-zip.sh" "$app" "$tmp_dir/NotchFlow-test.zip"; then
  echo 'generic release artifact name was accepted' >&2
  exit 1
fi

test -f "$archive"
ditto -x -k "$archive" "$extracted"
test -d "$extracted/NotchFlow.app"
codesign --verify --deep --strict "$extracted/NotchFlow.app"
