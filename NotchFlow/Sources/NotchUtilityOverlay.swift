import SwiftUI

struct NotchUtilityOverlay: View {
    let selection: UtilityOverlayKind
    @ObservedObject var model: NotchModel
    @ObservedObject var focusTimer: FocusTimerStore
    @ObservedObject var quickNote: QuickNoteStore
    @ObservedObject var quickReminder: QuickReminderStore
    @ObservedObject var system: SystemUtilityService
    let close: () -> Void

    var body: some View {
        Group {
            switch selection {
            case .pomodoro:
                FocusTimerOverlayView(store: focusTimer, close: close)
            case .quickNote:
                QuickNoteOverlayView(store: quickNote, close: close)
            case .reminder:
                QuickReminderOverlayView(store: quickReminder, close: close)
            case .power:
                PowerUtilityOverlayView(system: system, close: close)
            case .devices:
                DeviceUtilityOverlayView(system: system, close: close)
            case .clipboard:
                ClipboardHistoryOverlayView(history: ClipboardHistoryService.shared, close: close)
            case .shortcuts:
                ShortcutsUtilityOverlayView(close: close)
            }
        }
        .onAppear { model.setUtilityOverlayPresented(true) }
        .onDisappear { model.setUtilityOverlayPresented(false) }
        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
    }
}
