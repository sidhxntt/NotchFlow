#!/usr/bin/env bash
set -euo pipefail

# A rebuild must keep the same designated requirement. Otherwise macOS regards
# the app as a new TCC client and asks for Accessibility, Reminders, and
# Notifications again even when the user already approved NotchFlow.
./scripts/build_and_run.sh --verify-tcc-identity
codesign --verify --deep --strict build/Build/Products/Debug/NotchFlow.app
