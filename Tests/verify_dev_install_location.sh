#!/usr/bin/env bash
# Development builds must not depend on write access to the protected shared
# /Applications directory. The user's Applications folder is LaunchServices-
# indexed and writable without administrator privileges.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/scripts/build_and_run.sh"

grep -Fq 'DEVELOPMENT_APPLICATIONS_DIR="${HOME}/Applications"' "$script"
grep -Fq 'INSTALLED_APP_BUNDLE="$DEVELOPMENT_APPLICATIONS_DIR/$APP_NAME.app"' "$script"
grep -Fq 'mkdir -p "$DEVELOPMENT_APPLICATIONS_DIR"' "$script"

echo 'development install location verification passed.'
