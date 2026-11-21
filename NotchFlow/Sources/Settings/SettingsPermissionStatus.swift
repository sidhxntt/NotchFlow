import AppKit
import ApplicationServices
import CoreLocation
import Carbon.HIToolbox
import Carbon.OpenScripting
import EventKit
import SwiftUI
import UserNotifications

/// A common vocabulary for the TCC-backed capabilities shown in General. Some
/// frameworks use different native enums, but the settings UI only needs these
/// four user-facing states.
enum SettingsPermissionStatus: Equatable {
    case checking
    case notDetermined
    case denied
    case granted
    case unavailable

    var label: String {
        switch self {
        case .checking:      return L("permissions.status.checking")
        case .notDetermined: return L("permissions.status.notGranted")
        case .denied:        return L("permissions.status.denied")
        case .granted:       return L("permissions.status.granted")
        case .unavailable:   return L("permissions.status.unavailable")
        }
    }

    var pillLabel: String {
        switch self {
        case .notDetermined, .unavailable: return L("permissions.action.allow")
        case .denied:                      return L("permissions.action.settings")
        case .checking, .granted:           return label
        }
    }
}

/// A deliberately neutral system-style status capsule. Permission state is not
/// an alert or a score: granted rests in quiet grey, while a missing permission
/// uses the same shape as its action instead of introducing traffic-light color.
struct PermissionStatusPill: View {
    let status: SettingsPermissionStatus
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Group {
            if status == .granted || status == .checking {
                pillLabel
            } else {
                Button(action: action) { pillLabel }
                    .buttonStyle(.plain)
                    .onHover { hovering = $0 }
            }
        }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
    }

    private var pillLabel: some View {
        Text(status.pillLabel)
            .font(.sf(11, weight: .semibold))
            .foregroundStyle(missing
                             ? Color.red.opacity(hovering ? 0.88 : 0.72)
                             : (hovering ? Tokens.text1 : Tokens.text2))
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(
                Capsule()
                    .fill(missing
                          ? Color.red.opacity(hovering ? 0.14 : 0.09)
                          : Color.white.opacity(hovering ? 0.12 : 0.07))
            )
            .overlay(
                Capsule()
                    .strokeBorder(missing
                                  ? Color.red.opacity(hovering ? 0.22 : 0.15)
                                  : Color.white.opacity(hovering ? 0.15 : 0.08),
                                  lineWidth: 0.5)
            )
            .contentShape(Capsule())
    }

    private var missing: Bool {
        status != .granted && status != .checking
    }
}
