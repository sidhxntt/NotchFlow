#!/usr/bin/env bash
#
# NotchFlow — verified direct-download installer.
#
#   curl -fsSL https://raw.githubusercontent.com/sidhxntt/notchflow/main/install.sh | bash
#
# Downloads the exact DMG for the latest vX.Y.Z release, validates the app with
# codesign and Gatekeeper, and only then replaces /Applications/NotchFlow.app.
# Quarantine is intentionally preserved so macOS remains in the trust path.
#
set -euo pipefail

REPO="sidhxntt/NotchFlow"
APP_NAME="NotchFlow.app"
INSTALL_DIR="/Applications"
EXPECTED_BUNDLE_ID="com.notchflow.app"
EXPECTED_TEAM_ID="NQ55M2U74M"
NOTCHFLOW_INSTALL_LIBRARY_ONLY="${NOTCHFLOW_INSTALL_LIBRARY_ONLY:-0}"

bold=$'\033[1m'; dim=$'\033[2m'; red=$'\033[31m'; green=$'\033[32m'; reset=$'\033[0m'
info() { printf '%s==>%s %s\n' "$bold" "$reset" "$*"; }
ok()   { printf '%s✓%s %s\n' "$green" "$reset" "$*"; }
die()  { printf '%s✗%s %s\n' "$red" "$reset" "$*" >&2; exit 1; }

release_version() {
  local release_file="$1"
  local tag
  tag="$(/usr/bin/plutil -extract tag_name raw -o - "$release_file" 2>/dev/null)" || return 1
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  printf '%s\n' "$tag" | /usr/bin/sed 's/^v//'
}

select_release_asset() {
  local release_file="$1"
  local tag="$2"
  local expected_name="$3"
  local count index name url matches=0 selected=""
  local expected_url="https://github.com/$REPO/releases/download/$tag/$expected_name"

  count="$(/usr/bin/plutil -extract assets raw -o - "$release_file" 2>/dev/null)" || return 1
  [[ "$count" =~ ^[0-9]+$ ]] || return 1
  for ((index = 0; index < count; index++)); do
    name="$(/usr/bin/plutil -extract "assets.$index.name" raw -o - "$release_file" 2>/dev/null)" \
      || return 1
    [ "$name" = "$expected_name" ] || continue
    url="$(/usr/bin/plutil -extract "assets.$index.browser_download_url" raw -o - "$release_file" 2>/dev/null)" \
      || return 1
    [ "$url" = "$expected_url" ] || return 1
    matches=$((matches + 1))
    selected="$url"
  done
  [ "$matches" -eq 1 ] || return 1
  printf '%s\n' "$selected"
}

verify_app() {
  local app="$1"
  local expected_version="$2"
  local details info bundle_id short_version build_version

  [ -d "$app" ] || return 1
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$app" >/dev/null 2>&1 \
    || return 1

  details="$(/usr/bin/codesign -dvvv "$app" 2>&1)" || return 1
  printf '%s\n' "$details" | /usr/bin/grep -q '^Authority=Developer ID Application:' \
    || return 1
  printf '%s\n' "$details" | /usr/bin/grep -qx "TeamIdentifier=$EXPECTED_TEAM_ID" \
    || return 1

  /usr/sbin/spctl --assess --type execute --verbose=2 "$app" >/dev/null 2>&1 \
    || return 1

  # Info.plist is covered by the signature. Read it only after both trust checks.
  info="$app/Contents/Info.plist"
  bundle_id="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$info" 2>/dev/null)" \
    || return 1
  short_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$info" 2>/dev/null)" \
    || return 1
  build_version="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$info" 2>/dev/null)" \
    || return 1
  [ "$bundle_id" = "$EXPECTED_BUNDLE_ID" ] || return 1
  [ "$short_version" = "$expected_version" ] || return 1
  [ "$build_version" = "$expected_version" ] || return 1
}

install_verified_candidate() (
  set -euo pipefail
  local source_app="$1"
  local destination="$2"
  local expected_version="$3"
  local install_parent work incoming backup had_previous=false preserve_work=false

  # Candidate trust is resolved before creating staging or moving destination.
  verify_app "$source_app" "$expected_version" \
    || die "The downloaded app failed signature, Team ID, Gatekeeper, bundle ID, or version verification. The existing app was not changed."

  install_parent="$(/usr/bin/dirname "$destination")"
  [ -d "$install_parent" ] || die "Install directory does not exist: $install_parent"
  [ -w "$install_parent" ] || die "Cannot write to $install_parent. Drag the DMG app to Applications manually."
  [ ! -L "$destination" ] || die "Refusing to replace a symbolic-link destination: $destination"

  work="$(/usr/bin/mktemp -d "$install_parent/.notchflow-install.XXXXXX")" \
    || die "Could not create same-volume staging in $install_parent."
  incoming="$work/incoming.app"
  backup="$work/previous.app"
  cleanup_staging() {
    # If interruption lands after the old app was moved, restore it before
    # cleaning staging. A failed restoration deliberately preserves the backup.
    if "$had_previous" && [ ! -e "$destination" ] && [ -e "$backup" ]; then
      /bin/mv "$backup" "$destination" || preserve_work=true
    fi
    if ! "$preserve_work"; then
      /bin/rm -rf "$work"
    fi
  }
  trap cleanup_staging EXIT

  /usr/bin/ditto "$source_app" "$incoming" \
    || die "Could not stage the app in $install_parent. The existing app was not changed."
  verify_app "$incoming" "$expected_version" \
    || die "The staged copy failed verification. The existing app was not changed."

  if [ -e "$destination" ]; then
    /bin/mv "$destination" "$backup" \
      || die "Could not back up the existing app. It was not changed."
    had_previous=true
  fi

  if ! /bin/mv "$incoming" "$destination"; then
    if "$had_previous"; then
      /bin/mv "$backup" "$destination" \
        || { preserve_work=true; die "Installation failed and the previous app could not be restored from $backup."; }
    fi
    die "Installation failed. The previous app was restored."
  fi
)

main() {
  [ "$(/usr/bin/uname -s)" = "Darwin" ] \
    || die "NotchFlow is a macOS app — this installer only runs on macOS."
  [ "$(/usr/bin/uname -m)" = "arm64" ] \
    || die "This NotchFlow release requires an Apple-silicon Mac."
  [ -x /usr/bin/curl ] || die "curl is required but not found."

  local tmp release_file version tag asset_name asset_url dmg mount_dir source_app destination
  local mounted=false
  tmp="$(/usr/bin/mktemp -d)"
  release_file="$tmp/release.json"
  dmg="$tmp/notchflow.dmg"
  mount_dir="$tmp/mount"
  cleanup() {
    if "$mounted"; then
      /usr/bin/hdiutil detach "$mount_dir" -quiet || true
    fi
    rm -rf "$tmp"
  }
  trap cleanup EXIT

  info "Looking up the latest release of $REPO…"
  /usr/bin/curl --proto '=https' --proto-redir '=https' --tlsv1.2 --fail --silent --show-error --location \
    "https://api.github.com/repos/$REPO/releases/latest" -o "$release_file" \
    || die "Could not reach the GitHub API."

  version="$(release_version "$release_file")" \
    || die "The latest release does not have an exact vX.Y.Z tag."
  tag="v$version"
  asset_name="NotchFlow-$tag-arm64.dmg"
  asset_url="$(select_release_asset "$release_file" "$tag" "$asset_name")" \
    || die "The release does not contain exactly one trusted $asset_name asset."
  ok "Found $tag: $asset_name"

  info "Downloading…"
  /usr/bin/curl --proto '=https' --proto-redir '=https' --tlsv1.2 --fail --silent --show-error --location \
    "$asset_url" -o "$dmg" || die "Download failed."
  /usr/bin/hdiutil verify "$dmg" -quiet || die "The downloaded disk image is invalid."

  info "Mounting read-only…"
  /bin/mkdir "$mount_dir"
  /usr/bin/hdiutil attach "$dmg" -nobrowse -readonly -mountpoint "$mount_dir" -quiet \
    || die "Could not mount the downloaded disk image."
  mounted=true
  source_app="$mount_dir/$APP_NAME"
  [ -d "$source_app" ] || die "Could not find $APP_NAME inside the disk image."

  destination="$INSTALL_DIR/$APP_NAME"
  info "Verifying and installing to $INSTALL_DIR…"
  install_verified_candidate "$source_app" "$destination" "$version"

  ok "NotchFlow installed to $destination"
  info "Launching…"
  /usr/bin/open "$destination" || true
  printf '\n%sDone.%s Hover your notch to wake it. Quit with: %spkill -f NotchFlow.app%s\n' \
    "$bold" "$reset" "$dim" "$reset"
}

if [ "$NOTCHFLOW_INSTALL_LIBRARY_ONLY" != "1" ]; then
  main "$@"
fi
