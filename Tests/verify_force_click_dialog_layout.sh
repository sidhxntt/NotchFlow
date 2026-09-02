#!/usr/bin/env bash
set -euo pipefail

# The force-click sheet is an overlay, so it must reserve enough island height
# for its trackpad illustration instead of allowing the image to collapse.
rg -F 'static let minimumIslandHeight: CGFloat = 360' NotchFlow/Sources/Components.swift >/dev/null
rg -U '(?s)Image\("TrackpadLookupHint"\).*?frame\(height: 154\)' \
  NotchFlow/Sources/Components.swift >/dev/null
rg -U '(?s)forceClickDialogMinimumHeight: CGFloat\?.*?ForceClickLookupDialog\.minimumIslandHeight' \
  NotchFlow/Sources/ContentView.swift >/dev/null
rg -U '(?s)private var forceClickDialogMinimumHeight: CGFloat\? \{.*?guard isOpen, model\.forceClickLookupConflict != nil else \{ return nil \}' \
  NotchFlow/Sources/ContentView.swift >/dev/null
rg -F 'minHeight: forceClickDialogMinimumHeight' \
  NotchFlow/Sources/ContentView.swift >/dev/null
