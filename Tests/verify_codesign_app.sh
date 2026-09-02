#!/usr/bin/env bash
# Exercises the release signing script against a disposable bundle. In
# particular, a hardened-runtime signature must be accepted on both the
# current CodeDirectory output and older codesign output formats.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/notchflow-signing-test.XXXXXX")"
app="$tmp_dir/NotchFlow.app"
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$app/Contents/MacOS"
# A script cannot carry a code-signing entitlement. Use a real Mach-O so this
# exercises the same signing surface as the shipped executable.
cp /usr/bin/true "$app/Contents/MacOS/NotchFlow"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.notchflow.app</string>
  <key>CFBundleShortVersionString</key><string>1.2.3</string>
  <key>CFBundleVersion</key><string>1.2.3</string>
</dict></plist>
PLIST

bash "$repo_root/scripts/codesign-app.sh" "$app"

codesign --verify --deep --strict "$app"
signature_details="$(codesign -dvvv "$app" 2>&1)"
case "$signature_details" in
  *"flags="*"runtime"*) ;;
  *) echo "Expected hardened runtime in signature details." >&2; exit 1 ;;
esac

entitlements="$(codesign -d --entitlements - "$app" 2>&1)"
case "$entitlements" in
  *"com.apple.security.automation.apple-events"*) ;;
  *) echo "Expected Apple Events entitlement." >&2; exit 1 ;;
esac
case "$entitlements" in
  *"com.apple.security.personal-information.calendars"*) ;;
  *) echo "Expected Calendars entitlement." >&2; exit 1 ;;
esac
