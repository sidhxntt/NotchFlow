import AppKit
import ApplicationServices
import CoreLocation
import Carbon.HIToolbox
import Carbon.OpenScripting
import EventKit
import SwiftUI
import UserNotifications

@MainActor
extension InlineSettingsView {
    // MARK: - System permissions

    /// The protected capabilities NotchFlow currently consumes. Keeping the list in
    /// General makes the system's invisible TCC state explicit, and the trailing
    /// action gives every missing permission a recovery path in the same place.
    var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) { permissionsSectionOpen.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.sf(9, weight: .semibold))
                        .rotationEffect(.degrees(permissionsSectionOpen ? 90 : 0))
                    Text(L("permissions.title"))
                        .font(.sf(12, weight: .medium))
                }
                .foregroundStyle(Tokens.text1)
                .padding(.horizontal, 10)
                .frame(height: 26)
                // The disclosure's own glass chip — a translucent pill that
                // brightens under the pointer, so the fold itself reads as a
                // control on the panel's glass rather than a bare line of text.
                .background(
                    Capsule()
                        .fill(.white.opacity(hoveredDisclosure == .permissions ? 0.12 : 0.06))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(.white.opacity(hoveredDisclosure == .permissions ? 0.22 : 0.12),
                                      lineWidth: 0.5)
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { inside in
                if inside { hoveredDisclosure = .permissions }
                else if hoveredDisclosure == .permissions { hoveredDisclosure = nil }
            }
            .animation(.easeOut(duration: Tokens.hoverFade), value: hoveredDisclosure)

            if permissionsSectionOpen {
                VStack(alignment: .leading, spacing: 9) {
                    permissionRow(label: L("permissions.reminders"),
                                  status: remindersPermission) {
                        requestRemindersPermission()
                    }
                    permissionRow(label: L("permissions.notes"),
                                  status: notesPermission) {
                        requestNotesPermission()
                    }
                    permissionRow(label: L("permissions.notifications"),
                                  status: notificationsPermission) {
                        requestNotificationsPermission()
                    }
                    permissionRow(label: L("permissions.accessibility"),
                                  status: accessibilityPermission) {
                        requestAccessibilityPermission()
                    }
                    permissionRow(label: L("permissions.location"),
                                  status: locationPermission) {
                        requestLocationPermission()
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipped()
        .onAppear { refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
        // An LSUIElement app is not guaranteed to receive an activation event
        // when the user returns from System Settings. Accessibility is an
        // inexpensive, process-local check, so refresh it while these rows are
        // visible and reflect an in-place TCC change without requiring reopen.
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            guard permissionsSectionOpen else { return }
            refreshAccessibilityPermission()
        }
    }

    private func permissionRow(label: String,
                               status: SettingsPermissionStatus,
                               action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.sf(13, weight: .medium))
                .foregroundStyle(Tokens.text2)
                .lineLimit(1)
            Spacer(minLength: 12)
            PermissionStatusPill(status: status, action: action)
        }
    }

    /// None of this may run on the render path. It is called from
    /// `permissionsSection`'s `onAppear`, which fires *inside* the 0.16s section
    /// swap — and every probe in here is a blocking round-trip to a system
    /// daemon, not a property read:
    ///
    /// - `EKEventStore.authorizationStatus` is a TCC lookup that measured
    ///   **50–70 ms** whenever its in-process cache is cold (it warms after two
    ///   calls and drops again on any TCC change) — three to four dropped frames
    ///   of an animation that only lasts ten, which is the visible hitch on
    ///   landing on General;
    /// - `UNUserNotificationCenter.current()` opens its XPC connection on first
    ///   touch;
    /// - the Notes probe walks LaunchServices and may launch Notes.app.
    ///
    /// Same rule `refreshProxyStatus` already follows: resolve off the main
    /// thread, let the pills fill in a beat later. They start on `.checking`, so
    /// there is nothing to flash.
    private func refreshPermissions() {
        Task.detached(priority: .userInitiated) {
            let reminders = Self.remindersStatus()
            await MainActor.run { remindersPermission = reminders }

            UNUserNotificationCenter.current().getNotificationSettings { settings in
                let status = Self.notificationsStatus(settings.authorizationStatus)
                Task { @MainActor in notificationsPermission = status }
            }

            await MainActor.run { refreshNotesPermission() }
        }
        // Not in the detached task with the others: `AXIsProcessTrusted` is an
        // in-process bool, not a daemon round-trip, so there is nothing to move
        // off the main thread.
        refreshAccessibilityPermission()
        locationPermission = Self.locationStatus(CLLocationManager().authorizationStatus)
    }

    private func refreshAccessibilityPermission() {
        accessibilityPermission = AXIsProcessTrusted() ? .granted : .notDetermined
    }

    private static func locationStatus(_ status: CLAuthorizationStatus) -> SettingsPermissionStatus {
        switch status {
        case .authorized, .authorizedAlways: return .granted
        case .notDetermined:                 return .notDetermined
        case .denied, .restricted:           return .denied
        @unknown default:                    return .unavailable
        }
    }

    /// macOS shows the Location prompt once per app. After that the only route is
    /// System Settings, so a second press opens it there — same shape as the
    /// Accessibility row above.
    private func requestLocationPermission() {
        let status = CLLocationManager().authorizationStatus
        if status == .notDetermined {
            WeatherLocationProvider.shared.requestAuthorization()
        } else {
            openPrivacySettings("Privacy_LocationServices")
        }
    }

    /// Ask macOS for Accessibility, then send the user where they can grant it.
    ///
    /// Both halves matter. The prompting check is what REGISTERS this build in
    /// the Accessibility list — without it the user has to find the app bundle in
    /// a file dialog, and a dev build living under `/private/tmp` is effectively
    /// unfindable. But macOS shows that dialog only once per app, so on every
    /// later press it is a no-op; opening the pane is what makes the button keep
    /// working after the first time.
    private func requestAccessibilityPermission() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        accessibilityPermission = trusted ? .granted : .notDetermined
        guard !trusted else { return }
        openPrivacySettings("Privacy_Accessibility")
    }

    /// `nonisolated` on purpose: it touches no view state, and `refreshPermissions`
    /// deliberately runs it off the main thread (the TCC lookup blocks).
    nonisolated private static func remindersStatus() -> SettingsPermissionStatus {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .authorized, .fullAccess: return .granted
        case .notDetermined:           return .notDetermined
        case .denied, .restricted:     return .denied
        case .writeOnly:               return .denied
        @unknown default:              return .unavailable
        }
    }

    private static func notificationsStatus(
        _ status: UNAuthorizationStatus
    ) -> SettingsPermissionStatus {
        switch status {
        case .authorized, .provisional, .ephemeral: return .granted
        case .notDetermined:                       return .notDetermined
        case .denied:                              return .denied
        @unknown default:                          return .unavailable
        }
    }

    private func requestRemindersPermission() {
        guard remindersPermission != .denied else {
            openPrivacySettings("Privacy_Reminders")
            return
        }
        remindersPermission = .checking
        EKEventStore().requestFullAccessToReminders { _, _ in
            Task { @MainActor in remindersPermission = Self.remindersStatus() }
        }
    }

    private func requestNotificationsPermission() {
        guard notificationsPermission != .denied else {
            openSystemSettings("com.apple.Notifications-Settings.extension")
            return
        }
        notificationsPermission = .checking
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                let status = Self.notificationsStatus(settings.authorizationStatus)
                Task { @MainActor in notificationsPermission = status }
            }
        }
    }

    /// Apple Events is the one protected API without a public status query for a
    /// dormant target. `AEDeterminePermission…` requires Notes to be running, so
    /// launch it quietly (never activate it or open a window), then ask TCC for
    /// the live state without prompting.
    private func refreshNotesPermission() {
        notesPermission = .checking
        withRunningNotes { pid in
            guard let pid else {
                notesPermission = .unavailable
                return
            }
            determineNotesPermission(pid: pid, ask: false)
        }
    }

    private func requestNotesPermission() {
        guard notesPermission != .denied else {
            openPrivacySettings("Privacy_Automation")
            return
        }
        notesPermission = .checking
        withRunningNotes { pid in
            guard let pid else {
                notesPermission = .unavailable
                return
            }
            determineNotesPermission(pid: pid, ask: true)
        }
    }

    /// Supply a running Notes process without bringing it to the foreground.
    /// Existing instances are reused; otherwise the app is launched without
    /// activation because the AE permission API only accepts a live target.
    ///
    /// Both lookups are LaunchServices round-trips (`urlForApplication` measured
    /// ~7 ms cold), and this is reached from `permissionsSection`'s `onAppear` —
    /// mid-section-swap. They run off the main thread; only the launch and the
    /// completion come back to it. A `pid` crosses the boundary rather than the
    /// `NSRunningApplication`, since the pid is all the AE probe wants.
    private func withRunningNotes(_ completion: @escaping @MainActor (pid_t?) -> Void) {
        Task.detached(priority: .userInitiated) {
            if let running = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.Notes").first {
                let pid = running.processIdentifier
                await MainActor.run { completion(pid) }
                return
            }
            guard let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.apple.Notes") else {
                await MainActor.run { completion(nil) }
                return
            }
            await MainActor.run {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                configuration.addsToRecentItems = false
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, _ in
                    let pid = app?.processIdentifier
                    Task { @MainActor in completion(pid) }
                }
            }
        }
    }

    /// This call can block behind the secure consent sheet, so it always runs off
    /// the main thread. The result is then translated back onto the view state.
    private func determineNotesPermission(pid: pid_t, ask: Bool) {
        DispatchQueue.global(qos: .userInitiated).async {
            let target = NSAppleEventDescriptor(processIdentifier: pid)
            let result = AEDeterminePermissionToAutomateTarget(
                target.aeDesc,
                AEEventClass(typeWildCard),
                AEEventID(typeWildCard),
                ask)
            let status: SettingsPermissionStatus
            switch result {
            case noErr:                              status = .granted
            case OSStatus(errAEEventNotPermitted):  status = .denied
            case OSStatus(errAEEventWouldRequireUserConsent): status = .notDetermined
            default:                                 status = .unavailable
            }
            Task { @MainActor in notesPermission = status }
        }
    }

    private func openPrivacySettings(_ anchor: String) {
        openSystemSettings("com.apple.preference.security?\(anchor)")
    }

    private func openSystemSettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Whether opening the panel carries in whatever the user had highlighted in
    /// the app they came from (`NotchModel.selectionContext`). On by default; off
    /// stops the accessibility read itself, not just the badge.
    var selectionContextRow: some View {
        settingRow(label: L("general.selectionContext"),
                   info: L("general.selectionContext.hint")) {
            Toggle("", isOn: Binding(
                get: { model.selectionContextEnabled },
                set: { Haptics.levelChange(); model.selectionContextEnabled = $0 }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(Tokens.text2)
        }
    }

    /// Whether the collapsed notch shows any preview. When it is off, the notch
    /// stays clear; the finished badge and completion notification stay.
    var liveActivityRow: some View {
        settingRow(label: L("appearance.liveActivity"),
                   info: L("appearance.liveActivity.hint"),
                   aligned: true) {
            Toggle("", isOn: Binding(
                get: { model.liveActivityEnabled },
                set: { Haptics.levelChange(); model.liveActivityEnabled = $0 }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(Tokens.text2)
        }
    }

    /// Whether the assistant's answers come out in a hand instead of typeset.
    /// Prose only — your question, the interface and every code block stay as
    /// they are, and nothing about the copied text changes. That scope is the
    /// one thing the label can't say, so it's the whole of the hint.
    var handwrittenAnswersRow: some View {
        settingRow(label: L("appearance.handwritten"),
                   info: L("appearance.handwritten.hint"),
                   aligned: true) {
            Toggle("", isOn: Binding(
                get: { model.handwrittenAnswers },
                set: { Haptics.levelChange(); model.handwrittenAnswers = $0 }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(Tokens.text2)
        }
    }
}
