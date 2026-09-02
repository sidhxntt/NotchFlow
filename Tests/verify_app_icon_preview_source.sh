#!/usr/bin/env bash
set -euo pipefail

# AppIcon.appiconset PNGs have opaque corners. In-app previews must request the
# bundle's native icon and clip to the icon shape, rather than drawing that PNG
# as a square against NotchFlow's charcoal background.
! rg -F 'return NSImage(named: "AppIcon")' NotchFlow/Sources/AppDelegate.swift
rg -F 'return NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)' \
  NotchFlow/Sources/AppDelegate.swift >/dev/null
rg -F 'clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))' \
  NotchFlow/Sources/InlineSettingsView.swift >/dev/null
rg -F 'clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))' \
  NotchFlow/Sources/InlineSettingsView.swift >/dev/null
