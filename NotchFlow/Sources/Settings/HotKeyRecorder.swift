import AppKit
import ApplicationServices
import CoreLocation
import Carbon.HIToolbox
import Carbon.OpenScripting
import EventKit
import SwiftUI
import UserNotifications

struct HotKeyRecorder: NSViewRepresentable {
    var active: Bool
    var onCapture: (UInt32, NSEvent.ModifierFlags) -> Void
    var onDoubleModifier: (UInt32) -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSView {
        context.coordinator.onCapture = onCapture
        context.coordinator.onDoubleModifier = onDoubleModifier
        context.coordinator.onCancel = onCancel
        return NSView(frame: .zero)
    }

    func updateNSView(_: NSView, context: Context) {
        context.coordinator.onCapture = onCapture
        context.coordinator.onDoubleModifier = onDoubleModifier
        context.coordinator.onCancel = onCancel
        context.coordinator.setActive(active)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_: NSView, coordinator: Coordinator) {
        coordinator.setActive(false)
    }

    final class Coordinator {
        var onCapture: ((UInt32, NSEvent.ModifierFlags) -> Void)?
        var onDoubleModifier: ((UInt32) -> Void)?
        var onCancel: (() -> Void)?
        private var monitor: Any?
        private var pendingModifierTap: UInt32?
        private var lastModifierTap: (modifier: UInt32, time: TimeInterval)?

        func setActive(_ active: Bool) {
            if active, monitor == nil {
                // Announce first: the global hot keys must be unregistered before
                // the monitor goes up, or the chords Notch owns still never arrive.
                ShortcutRecording.setActive(true)
                pendingModifierTap = nil
                lastModifierTap = nil
                monitor = NSEvent.addLocalMonitorForEvents(
                    matching: [.keyDown, .flagsChanged]
                ) { [weak self] event in
                    guard let self else { return event }
                    if event.type == .flagsChanged {
                        self.captureDoubleModifierIfNeeded(event)
                        return event
                    }
                    // Esc cancels recording without committing anything. Clearing
                    // the armed target is the whole point — leaving it armed makes
                    // the *next* keystroke anywhere land on that row.
                    guard event.keyCode != UInt16(kVK_Escape) else {
                        self.onCancel?()
                        return nil
                    }
                    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    self.onCapture?(UInt32(event.keyCode), flags)
                    return nil // swallow — don't let the chord reach the panel
                }
            } else if !active, let m = monitor {
                NSEvent.removeMonitor(m)
                monitor = nil
                pendingModifierTap = nil
                lastModifierTap = nil
                ShortcutRecording.setActive(false)
            }
        }

        /// Recognize two clean Command or Option down/up taps inside the same
        /// 300 ms window used by the live monitor. Any other held modifier
        /// invalidates the sequence, so normal chords never become a double tap.
        private func captureDoubleModifierIfNeeded(_ event: NSEvent) {
            let watched: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
            let active = event.modifierFlags.intersection(watched)

            let pressed: UInt32? = switch active {
            case .command: UInt32(cmdKey)
            case .option: UInt32(optionKey)
            default: nil
            }
            if let pressed {
                pendingModifierTap = pressed
                return
            }

            guard active.isEmpty else {
                pendingModifierTap = nil
                lastModifierTap = nil
                return
            }

            guard let completed = pendingModifierTap else { return }
            pendingModifierTap = nil

            let now = event.timestamp
            if let last = lastModifierTap,
               last.modifier == completed, now - last.time <= 0.30 {
                lastModifierTap = nil
                onDoubleModifier?(completed)
            } else {
                lastModifierTap = (completed, now)
            }
        }

        deinit {
            if let m = monitor {
                NSEvent.removeMonitor(m)
                ShortcutRecording.setActive(false)
            }
        }
    }
}
