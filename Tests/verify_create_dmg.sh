#!/usr/bin/env bash
# Verifies the direct-download artifact contract: a signed app is copied into
# a mountable DMG alongside the conventional Applications shortcut.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/notchflow-dmg-test.XXXXXX")"
mount_dir="$tmp_dir/mount"
app="$tmp_dir/NotchFlow.app"
dmg="$tmp_dir/NotchFlow-v1.2.3-arm64.dmg"
mounted=false

cleanup() {
  if "$mounted"; then
    hdiutil detach "$mount_dir" -quiet || true
  fi
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

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

bash "$repo_root/scripts/create-dmg.sh" "$app" "$dmg"

if bash "$repo_root/scripts/create-dmg.sh" "$app" "$tmp_dir/NotchFlow-test.dmg"; then
  echo 'generic release artifact name was accepted' >&2
  exit 1
fi

test -f "$dmg"
hdiutil verify "$dmg" >/dev/null
mkdir "$mount_dir"
hdiutil attach "$dmg" -nobrowse -readonly -mountpoint "$mount_dir" -quiet
mounted=true

test -d "$mount_dir/NotchFlow.app"
test -L "$mount_dir/Applications"
test "$(readlink "$mount_dir/Applications")" = "/Applications"
