#!/usr/bin/env bash
set -euo pipefail

# Full-screen hiding is no longer a feature: no persisted preference, event
# observer, runtime policy, UI control, or agent-facing setting may remain.
! rg -i 'HideNotchInFullscreen|hideNotchInFullscreenChanged|hide_in_fullscreen|fullscreenAutoHide|fullScreenStateMaybeChanged|scheduleFullScreenHidingUpdate|updateFullScreenHiding|hasFullScreenWindow' \
  NotchFlow/Sources

# The two display cards must still map to distinct panel sets and rebuild live.
rg -F 'case .all:     return NSScreen.screens' NotchFlow/Sources/AppDelegate.swift >/dev/null
rg -F 'case .builtIn: return preferredScreen().map { [$0] } ?? []' NotchFlow/Sources/AppDelegate.swift >/dev/null
rg -F 'DisplayPlacement.current = newValue' NotchFlow/Sources/InlineSettingsView.swift >/dev/null
rg -F 'NotificationCenter.default.post(name: .displayPlacementChanged' \
  NotchFlow/Sources/InlineSettingsView.swift >/dev/null
