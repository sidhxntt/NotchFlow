#!/usr/bin/env bash
set -euo pipefail

# Agent's compact scrolling settings pane must place each Session control on
# the line below its label. In that context an inline `ViewThatFits` probe is
# offered an unconstrained horizontal size and cannot reliably prevent overlap.
source_file='NotchFlow/Sources/InlineSettingsView.swift'

for row in agentPermissionDelayRow agentStalledAfterRow agentSessionWindowRow agentSubagentBadgeRow; do
  rg -U "(?s)private var ${row}: some View \{.*?settingRow\(.*?forceStacked: true" "$source_file" >/dev/null
done
