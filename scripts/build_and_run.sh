#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="NotchFlow"
PROJECT_NAME="NotchFlow.xcodeproj"
SCHEME_NAME="NotchFlow"
BUILD_CONFIGURATION="Debug"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_BUNDLE="$BUILD_DIR/Build/Products/$BUILD_CONFIGURATION/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
# `/Applications` can be protected by macOS even for a bundle whose Unix owner
# is the current user. Keep the developer install under the user's Applications
# directory so `make dev` neither requires administrator access nor fails after
# an OS update changes that protection.
DEVELOPMENT_APPLICATIONS_DIR="${HOME}/Applications"
INSTALLED_APP_BUNDLE="$DEVELOPMENT_APPLICATIONS_DIR/$APP_NAME.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

cd "$ROOT_DIR"
xcodebuild \
  -project "$PROJECT_NAME" \
  -scheme "$SCHEME_NAME" \
  -configuration "$BUILD_CONFIGURATION" \
  -derivedDataPath "$BUILD_DIR" \
  build

# Xcode's "Sign to Run Locally" fallback is an ad-hoc signature whose
# designated requirement is the binary's CDHash. That hash changes whenever
# the app is rebuilt, so macOS TCC (Accessibility, Reminders, Notifications,
# and Location) treats every build as a different application and discards the
# permissions the user already granted. Re-sign local builds with a stable
# requirement based on the app's bundle identifier while retaining the
# entitlements Xcode generated for the app.
stabilize_tcc_identity() {
  local bundle_identifier
  bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$APP_BUNDLE/Contents/Info.plist")"

  # Sign nested executables before the outer wrapper. `codesign --deep` signs
  # them after the wrapper and invalidates its resource seal on current Xcode
  # debug products.
  while IFS= read -r framework; do
    [[ -d "$framework" ]] || continue
    /usr/bin/codesign --force --sign - "$framework"
  done < <(find "$APP_BUNDLE/Contents" -type d -name '*.framework')

  while IFS= read -r nested_code; do
    [[ "$nested_code" == "$APP_BINARY" ]] && continue
    # Re-signing a nested executable can briefly create a sibling `.cstemp`
    # file. `find` may yield it after it has already been removed, which must
    # not abort the build before the freshly built Debug app is installed.
    [[ -f "$nested_code" ]] || continue
    /usr/bin/codesign --force --sign - "$nested_code"
  done < <(find "$APP_BUNDLE/Contents" -type f -perm -111)

  /usr/bin/codesign --force --sign - \
    --preserve-metadata=identifier,entitlements,flags,runtime \
    --requirements "=designated => identifier \"$bundle_identifier\"" \
    "$APP_BUNDLE"
}

verify_tcc_identity() {
  local bundle_identifier expected_requirement
  bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$APP_BUNDLE/Contents/Info.plist")"
  expected_requirement="designated => identifier \"$bundle_identifier\""

  /usr/bin/codesign -d -r- "$APP_BUNDLE" 2>&1 | grep -F "$expected_requirement" >/dev/null
  echo "TCC identity is stable: $expected_requirement"
}

stabilize_tcc_identity

install_app() {
  # LaunchServices indexes the installed bundle, not Xcode's DerivedData product.
  # Mirror it instead of merging with `ditto`: stale frameworks or resources
  # from an earlier build invalidate the bundle's signature and can leave the
  # launched app out of sync with the verified build product.
  mkdir -p "$DEVELOPMENT_APPLICATIONS_DIR"
  /usr/bin/rsync -a --delete "$APP_BUNDLE/" "$INSTALLED_APP_BUNDLE/"
  # An app may not be registered yet on its first development launch.
  "$LSREGISTER" -u "$INSTALLED_APP_BUNDLE" >/dev/null 2>&1 || true
  "$LSREGISTER" -f "$INSTALLED_APP_BUNDLE"
}

open_app() {
  install_app
  /usr/bin/open -n "$INSTALLED_APP_BUNDLE"
}

case "$MODE" in
  --bundle|bundle)
    echo "Built $APP_BUNDLE"
    ;;
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    echo "$APP_NAME launched successfully"
    ;;
  --verify-tcc-identity)
    verify_tcc_identity
    ;;
  *)
    echo "usage: $0 [run|--bundle|--debug|--logs|--telemetry|--verify|--verify-tcc-identity]" >&2
    exit 2
    ;;
esac
