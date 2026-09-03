#!/usr/bin/env bash
set -euo pipefail

# The persistent Awake settings occupy the same two visual rows as the
# immediate actions, so the duration/display-sleep controls need the same
# padded card treatment as the screensaver action beside them.
rg -P -U '(?s)HStack\(spacing: 6\) \{.*?Toggle\("Display may sleep"(?:(?!private var actionsColumn).)*?\.padding\(\.vertical, 8\).*?\.padding\(\.horizontal, 10\).*?\.background\(\s*RoundedRectangle\(cornerRadius: 10, style: \.continuous\)\s*\.fill\(Color\.white\.opacity\(0\.05\)\)\)' \
  NotchFlow/Sources/PowerUtilityOverlayView.swift >/dev/null

# Mini toggles make the Awake rows taller than a text-only action. Reserve the
# same 18-point content height for Right now so both columns share row guides.
rg -P -U '(?s)private func actionRow.*?HStack\(spacing: 7\) \{.*?\.frame\(minHeight: 18\).*?\.padding\(\.vertical, 8\)' \
  NotchFlow/Sources/PowerUtilityOverlayView.swift >/dev/null
