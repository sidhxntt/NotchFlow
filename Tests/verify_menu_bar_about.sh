#!/usr/bin/env bash
set -euo pipefail

# About is a destination, not an informational dead end: it must appear directly
# above Quit and open the established About settings pane.
menu='NotchFlow/Sources/MenuBarController.swift'
delegate='NotchFlow/Sources/AppDelegate.swift'
strings='NotchFlow/Sources/Localization.swift'

rg -U '(?s)menu\.addItem\(item\(L\("menuBar\.about"\).*?let quit = item\(L\("menuBar\.quit"\)' "$menu" >/dev/null
rg -F 'var openAbout: () -> Void' "$menu" >/dev/null
rg -F '@objc private func openAbout() { actions.openAbout() }' "$menu" >/dev/null
rg -U '(?s)openAbout: \{ \[weak self\] in.*?self\?\.model\.settingsSection = InlineSettingsView\.Section\.about\.rawValue.*?NotificationCenter\.default\.post\(name: \.openSettingsRequested' "$delegate" >/dev/null

# Every supported interface language needs an About label; otherwise the menu
# exposes the localization key itself.
test "$(rg -F '"menuBar.about":' "$strings" | wc -l | tr -d ' ')" -eq 7
