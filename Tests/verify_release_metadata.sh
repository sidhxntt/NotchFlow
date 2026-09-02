#!/usr/bin/env bash
# Verifies the source-controlled contract for a direct-download NotchFlow
# release. This intentionally runs without signing credentials or a build so it
# can fail early on stale notes, unsafe public URLs, or a misconfigured workflow.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

fail() {
  printf 'release metadata check failed: %s\n' "$*" >&2
  exit 1
}

require_file() {
  [ -f "$1" ] || fail "missing $1"
  if git check-ignore -q "$1"; then
    fail "$1 is ignored and cannot be released"
  fi
}

require_text() {
  local needle="$1"
  local file="$2"
  grep -Fq -- "$needle" "$file" || fail "missing $needle in $file"
}

require_file CHANGELOG.md
require_file PRIVACY.md
require_file scripts/gen-releases.mjs
require_file scripts/create-dmg.sh
require_file scripts/create-zip.sh
require_file scripts/next-release-version.sh
require_file scripts/protect-main-branch.sh
require_file .github/workflows/auto-release-tag.yml
require_file .github/workflows/validate-pull-request.yml
require_file README.zh-CN.md
require_text '[Release Notes](CHANGELOG.md)' README.md

# App-source pushes to main receive a version tag. Website-only commits remain
# the responsibility of pages.yml and must never publish a macOS build.
auto_workflow=.github/workflows/auto-release-tag.yml
require_text 'branches: [main]' "$auto_workflow"
require_text 'paths-ignore:' "$auto_workflow"
require_text "- 'web/**'" "$auto_workflow"
require_text 'contents: write' "$auto_workflow"
require_text 'actions: write' "$auto_workflow"
require_text 'bash scripts/next-release-version.sh "$GITHUB_SHA"' "$auto_workflow"
require_text 'git tag -a "$TAG" "$GITHUB_SHA"' "$auto_workflow"
require_text 'gh workflow run release.yml --ref "$TAG"' "$auto_workflow"

# This unique check is deliberately run for every pull request, including a
# website-only PR, so it can be required by the protected main branch without
# leaving a path-skipped check permanently pending.
pr_workflow=.github/workflows/validate-pull-request.yml
require_text 'name: Validate Pull Request' "$pr_workflow"
require_text 'pull_request:' "$pr_workflow"
require_text 'branches: [main]' "$pr_workflow"
require_text 'name: app-verification' "$pr_workflow"
require_text 'bash Tests/verify_release_metadata.sh' "$pr_workflow"
require_text 'bash Tests/verify_next_release_version.sh' "$pr_workflow"

# The remotely applied protection requires a pull request, the unique PR
# validation check, linear history, conversation resolution, and blocks force
# pushes and deletion (including for repository administrators).
protection_script=scripts/protect-main-branch.sh
require_text 'repository="${1:-sidhxntt/NotchFlow}"' "$protection_script"
require_text 'branches/main/protection' "$protection_script"
require_text 'Validate Pull Request / app-verification' "$protection_script"
require_text '"required_approving_review_count": 0' "$protection_script"
require_text '"required_linear_history": true' "$protection_script"
require_text '"allow_force_pushes": false' "$protection_script"
require_text '"allow_deletions": false' "$protection_script"
require_text '"required_conversation_resolution": true' "$protection_script"
require_text '"enforce_admins": true' "$protection_script"
if grep -Fq 'dismissal_restrictions' "$protection_script"; then
  fail 'main protection must not send organization-only dismissal restrictions'
fi

# The notarized ticket must be stapled to the source app before the DMG/ZIP
# helpers copy it. Stapling only after DMG creation leaves the mounted app
# without a ticket even though the build-directory app validates successfully.
workflow=.github/workflows/release.yml
require_text 'workflow_dispatch:' "$workflow"
line_number() {
  local needle="$1"
  local line
  line="$(grep -n -F -- "$needle" "$workflow" | head -n1 | cut -d: -f1)"
  [ -n "$line" ] || fail "missing $needle in $workflow"
  printf '%s\n' "$line"
}

app_staple_line="$(line_number 'xcrun stapler staple "$APP"')"
app_submit_line="$(line_number 'xcrun notarytool submit "$SUBMISSION_ZIP"')"
dmg_package_line="$(line_number 'bash scripts/create-dmg.sh "$APP" "$DMG_NAME"')"
dmg_staple_line="$(line_number 'xcrun stapler staple "$DMG"')"
zip_package_line="$(line_number 'bash scripts/create-zip.sh "$APP" "$ZIP_NAME"')"
[ "$app_submit_line" -lt "$app_staple_line" ] \
  || fail 'the app must be notarized before its ticket is stapled'
[ "$app_staple_line" -lt "$dmg_package_line" ] \
  || fail 'the app must be stapled before it is copied into the DMG'
[ "$dmg_package_line" -lt "$dmg_staple_line" ] \
  || fail 'the completed DMG must be notarized and stapled after packaging'
[ "$app_staple_line" -lt "$zip_package_line" ] \
  || fail 'the app must be stapled before it is copied into the ZIP fallback'

# A release build must contain the real public Lemon configuration. Placeholders
# leave the app blocked by design, so publishing them would create a product no
# customer can activate. These values are public identifiers, never credentials.
node --input-type=module <<'NODE'
import { readFileSync } from 'node:fs';

const input = JSON.parse(readFileSync('NotchFlow/Resources/input.json', 'utf8'));
const licensing = input.licensing;
if (!licensing || typeof licensing !== 'object') {
  throw new Error('missing licensing configuration in NotchFlow/Resources/input.json');
}
for (const key of ['storeID', 'productID', 'variantID']) {
  if (!Number.isInteger(licensing[key]) || licensing[key] <= 0) {
    throw new Error(`licensing.${key} must be a non-zero integer for a release`);
  }
}
let checkout;
try { checkout = new URL(licensing.checkoutURL); }
catch { throw new Error('licensing.checkoutURL must be a valid HTTPS URL for a release'); }
if (checkout.protocol !== 'https:' || !checkout.hostname) {
  throw new Error('licensing.checkoutURL must be a valid HTTPS URL for a release');
}
NODE

# Public install snippets must resolve the shipped script from the release
# branch, never an obsolete default branch.
if grep -nE \
  'raw\.githubusercontent\.com/[[:alnum:]_.-]+/[[:alnum:]_.-]+/master/' \
  README.md README.zh-CN.md RELEASING.md install.sh .github/workflows/release.yml; then
  fail 'a shipped raw GitHub URL still targets /master/'
fi
require_text '/main/install.sh' README.md
require_text '/main/install.sh' README.zh-CN.md
require_text '/main/install.sh' .github/workflows/release.yml

# Each note entry must have a generated changelog counterpart. The current
# release is explicit so a version regression cannot leave the trial/licensing
# disclosure without a user-facing release note.
require_text 'version: "1.0.2"' NotchFlow/Sources/WhatsNewService.swift
while IFS= read -r version; do
  [ -n "$version" ] || continue
  require_text "## [$version]" CHANGELOG.md
done < <(sed -nE 's/^[[:space:]]*version: "([^"]+)".*/\1/p' NotchFlow/Sources/WhatsNewService.swift)
node scripts/gen-releases.mjs --check
awk '/^## \[/ { if (previous != "") exit 1 } { previous = $0 }' CHANGELOG.md \
  || fail 'each CHANGELOG.md release heading must be separated by a blank line'

# The release job stamps both Info.plist versions from a strictly semver tag,
# produces Apple-silicon-only assets, and validates the resulting bundle rather
# than trusting the build command's requested settings.
require_text 'RELEASE_VERSION="${GITHUB_REF_NAME#v}"' .github/workflows/release.yml
require_text '[[ ! "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]' .github/workflows/release.yml
require_text 'MARKETING_VERSION="$RELEASE_VERSION"' .github/workflows/release.yml
require_text 'CURRENT_PROJECT_VERSION="$RELEASE_VERSION"' .github/workflows/release.yml
require_text 'ARCHS=arm64' .github/workflows/release.yml
require_text 'NotchFlow-v${RELEASE_VERSION}-arm64.dmg' .github/workflows/release.yml
require_text 'NotchFlow-v${RELEASE_VERSION}-arm64.zip' .github/workflows/release.yml
require_text 'EXPECTED_BUNDLE_ID="com.notchflow.app"' .github/workflows/release.yml
require_text 'APPLE_TEAM_ID: ${{ vars.APPLE_TEAM_ID }}' .github/workflows/release.yml
require_text 'EXPECTED_TEAM_ID="${APPLE_TEAM_ID:?Missing required repository variable APPLE_TEAM_ID}"' .github/workflows/release.yml
require_text 'lipo -archs "$EXECUTABLE"' .github/workflows/release.yml
require_text 'CFBundleShortVersionString' .github/workflows/release.yml
require_text 'CFBundleVersion' .github/workflows/release.yml
require_text 'uses: actions/checkout@08c6903cd8c0fde910a37f88322edcfb5dd907a8' .github/workflows/release.yml
require_text 'uses: softprops/action-gh-release@3bb12739c298aeb8a4eeaf626c5b8d85266b0e65' .github/workflows/release.yml
require_text 'ditto -c -k --keepParent "$APP" "$SUBMISSION_ZIP"' .github/workflows/release.yml

# DMG remains the normal install route; the matching ZIP is an explicit
# fallback. The helpers must only accept the canonical arm64 names.
require_text 'NotchFlow-v([0-9]+\.[0-9]+\.[0-9]+)-arm64\.dmg' scripts/create-dmg.sh
require_text 'NotchFlow-v([0-9]+\.[0-9]+\.[0-9]+)-arm64\.zip' scripts/create-zip.sh
require_text 'DMG (primary)' README.md
require_text 'ZIP fallback' README.md

# The policy is source-controlled now. Publishing it at the configured URL is
# deliberately a release prerequisite, not something this repository claims to
# have deployed.
require_text 'Deployment requirement' PRIVACY.md
require_text 'Lemon Squeezy' PRIVACY.md
require_text 'Keychain' PRIVACY.md
require_text 'Retention and deletion' PRIVACY.md

printf 'Release metadata is internally consistent.\n'
