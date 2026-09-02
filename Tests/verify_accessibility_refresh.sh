#!/usr/bin/env bash
set -euo pipefail

# System Settings can change Accessibility while this LSUIElement app stays
# inactive. The panel must therefore poll the process-level TCC flag while its
# permission rows are visible, rather than relying only on an activation event.
source_file="NotchFlow/Sources/InlineSettingsView.swift"

rg -U '(?s)Timer\.publish\(every: 0\.5, on: \.main, in: \.common\).*?refreshAccessibilityPermission\(\)' \
  "$source_file" >/dev/null
