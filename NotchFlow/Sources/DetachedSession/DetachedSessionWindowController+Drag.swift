import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
extension DetachedSessionWindowController {
    // MARK: The ride (mid-drag, the window follows the mouse)

    func beginRide() {
        let mouse = NSEvent.mouseLocation
        grabOffset = NSPoint(x: window.frame.origin.x - mouse.x,
                             y: window.frame.origin.y - mouse.y)
        lastMouse = mouse
        lastMouseAt = ProcessInfo.processInfo.systemUptime
        // The original canvas panel owns the AppKit drag session (it took the
        // mouse-down), so its events keep flowing app-locally regardless of what
        // SwiftUI does with the gesture — a local monitor rides them. The window
        // is moved by delta, never by re-anchoring, so the grip point holds.
        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .leftMouseDragged: self.follow()
            case .leftMouseUp:      self.settleAfterRide()
            default: break
            }
            return event
        }
    }

    private func follow() {
        guard dragMonitor != nil else { return }
        // Missed mouse-up (app deactivated mid-drag, monitor starved): settle.
        guard NSEvent.pressedMouseButtons & 1 == 1 else {
            settleAfterRide(); return
        }
        let mouse = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(x: mouse.x + grabOffset.x, y: mouse.y + grabOffset.y))

        // Momentum tilt: the window leans a whisper into its horizontal
        // velocity, hinged at the grip. Spring-smoothed on the SwiftUI side;
        // kept subtle — this is a full window in the hand, not a playing card.
        let now = ProcessInfo.processInfo.systemUptime
        let dt = max(now - lastMouseAt, 1.0 / 240.0)
        let vx = (mouse.x - lastMouse.x) / dt
        lastMouse = mouse
        lastMouseAt = now
        if !Self.reduceMotion {
            state.tilt = max(-1.4, min(1.4, vx * 0.0016))
        }
    }

    func endRide() {
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
        dragMonitor = nil
        state.tilt = 0
    }
    // MARK: Settle (release the ride)

    /// The hand lets go: the window stays exactly where it is — it was already
    /// the full window — and just becomes a normal citizen: normal level,
    /// traffic lights fade in, key. The only motion is the tilt springing to
    /// rest; nothing resizes, nothing crossfades.
    private func settleAfterRide() {
        endRide()
        guard state.phase == .riding else { return }
        state.phase = .settled
        finishSettle()
    }

    func finishSettle() {
        applyPinLevel()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        armSummonGrace()
        armMergeTracking()
    }

    /// Hold this window's focus through the tail of the gesture that opened it.
    ///
    /// A pointer-side window is summoned by a press inside SOMEONE ELSE'S
    /// window, and a force click fires while the button is still down. So the
    /// order of events is: we activate and take key — then the user lifts their
    /// finger, that mouse-up lands in the app underneath, and macOS activates
    /// *it* again. The window we just opened resigns key through no act of the
    /// user's: at `.normal` level it sinks behind that app, and an untouched
    /// composer reads the resign as "the keyboard left" and closes itself
    /// (`windowDidResignKey`) — which is why the box appeared and vanished
    /// before it could be typed in, clicked or dragged.
    ///
    /// For this long, a resign is that echo: key is taken back and nothing
    /// closes. If the button is still down the window waits for the release
    /// first, since the echo cannot arrive before it.
    func armSummonGrace() {
        guard compactShortcut else { return }
        summonGraceUntil = Date().addingTimeInterval(Self.summonGrace)
        reclaimedAfterSummon = false
        summonReleaseTimer?.invalidate()
        summonReleaseTimer = nil
        guard NSEvent.pressedMouseButtons & 1 != 0 else { return }
        // A held button, watched by polling rather than by an event monitor: the
        // press belongs to another app, and the mouse-up that ends it may never
        // pass through this process at all.
        let giveUp = Date().addingTimeInterval(3)
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, let window = self.window, window.isVisible else {
                    return t.invalidate()
                }
                guard NSEvent.pressedMouseButtons & 1 == 0 || Date() > giveUp else { return }
                t.invalidate()
                self.summonReleaseTimer = nil
                // The release is what triggers the other app's activation, so the
                // grace starts counting from here, not from the open.
                self.summonGraceUntil = Date().addingTimeInterval(Self.summonGrace)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        summonReleaseTimer = timer
    }

    /// Take key back after the summoning press handed it to the app underneath.
    ///
    /// Once. Trading activation with the other app for the length of the grace
    /// is a visible flicker and ends in the close anyway; one attempt covers the
    /// echo, and anything after it is the user going somewhere on purpose.
    func reclaimKeyAfterSummon() {
        guard !reclaimedAfterSummon else { return }
        reclaimedAfterSummon = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.isVisible,
                  !window.isKeyWindow, self.isInSummonGrace else { return }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    var isInSummonGrace: Bool {
        if summonReleaseTimer != nil { return true }
        guard let summonGraceUntil else { return false }
        return Date() < summonGraceUntil
    }

    /// Pinned (the default) floats the session above normal windows — torn out
    /// to be watched; unpinned it's an ordinary citizen of the window stack.
    func applyPinLevel() {
        window.level = state.pinned ? .floating : .normal
    }

    func togglePin() {
        state.pinned.toggle()
        if state.phase == .settled { applyPinLevel() }
    }

    /// The app's editable chords, answered by the window that has the keyboard.
    /// The panel's `KeyEventCatcher` bails whenever its own window isn't key
    /// (one catcher per screen, all of them watching the same local monitor), so
    /// every chord the panel owns is dead inside a torn-out window unless it is
    /// re-served here — including ⌘P, which this window's pin chip advertises in
    /// its tooltip.
    ///
    /// Only the chords whose action EXISTS in this window are claimed; the rest
    /// fall through to the system, exactly as they do over settings in the
    /// panel. ⌘F (the recent-list filter), ⌘⇧I (the picker card), ⌘N (a fresh
    /// chat) and ⌃⇧= (detach) all name panel-only surfaces — a detached window
    /// has no recent list, no picker and no idle prompt, and it is already
    /// detached — so swallowing them here would only make them fizzle.
    func handleAppShortcut(_ event: NSEvent) -> Bool {
        // While a chord is being recorded in Shortcuts the keyboard belongs to
        // the recorder — same rule the panel's catcher opens with.
        if ShortcutRecording.isActive { return false }
        // ⌘P floats/unfloats the window — the keyboard twin of the header's pin
        // chip. Unguarded by the field editor: ⌘P is not a text-editing key, and
        // pinning mid-follow-up is exactly when you want it.
        if AppShortcutStore.matches(.pin, event: event) {
            togglePin()
            return true
        }
        // ⌘C / ⌘R mirror the answer footer's copy and regenerate. Guarded on the
        // follow-up field the way the panel guards its composer: with the caret
        // in text, ⌘C copies the selection and ⌘R stays out of the way.
        if window.firstResponder is NSText { return false }
        guard let store = threadStore,
              !store.turns.contains(where: { $0.streaming }) else { return false }
        if AppShortcutStore.matches(.copyAnswer, event: event) {
            // Verbatim markdown — the `doc.on.doc` footer button's text, not the
            // plain-text twin beside it (which has no chord in the panel either).
            let answer = store.turns.last(where: { $0.role == "assistant" })?.text
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !answer.isEmpty else { return false }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(answer, forType: .string)
            model?.rebaselineClipboardAfterInAppWrite()
            return true
        }
        if AppShortcutStore.matches(.regenerate, event: event) {
            // The footer's own gate: only the last settled turn, and never an
            // agent report (it has no round to re-run).
            guard let last = store.turns.last, last.role == "assistant",
                  !last.isAgent else { return false }
            model?.regenerateDetachedAnswer(threadID: store.threadID)
            return true
        }
        return false
    }
    // MARK: Merge back (drag the window home to the notch)

    /// While the settled window rides a user drag, watch its position against
    /// every screen's resting-notch zone; hovering the zone swells the island
    /// (the "it'll take it back" hint), releasing inside it merges the session
    /// home: the window sinks toward the notch and the panel reopens on it.
    func armMergeTracking() {
        guard moveObserver == nil else { return }
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // A pointer-side shortcut window is a transient utility surface,
                // not a torn-out session: there is nothing to hand back to the
                // notch, and the zone reaches far enough (80×56 around the notch)
                // that simply dragging the box out of the way near the top of the
                // screen swallowed it. Moving a window must never be a way to
                // lose it.
                guard !self.compactShortcut else { return }
                self.windowMoved()
            }
        }
    }

    private func windowMoved() {
        guard state.phase == .settled, let model else { return }
        // Only a live user drag can merge — programmatic moves don't count.
        guard NSEvent.pressedMouseButtons & 1 == 1 else { return }
        let inZone = mergeDisplay() != nil
        if inZone != mergeArmed {
            mergeArmed = inZone
            withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
                model.detachMergeHint = inZone
            }
            if inZone { Haptics.alignment() }
        }
        if inZone { watchForMergeDrop() }
    }

    /// The display whose notch zone the window's top edge is currently inside.
    private func mergeDisplay() -> CGDirectDisplayID? {
        guard let model else { return nil }
        let topCenter = NSPoint(x: window.frame.midX, y: window.frame.maxY)
        for display in model.knownDisplays {
            guard let notch = model.restingNotchScreenRect(on: display) else { continue }
            if notch.insetBy(dx: -80, dy: -56).contains(topCenter) { return display }
        }
        return nil
    }

    /// The mouse is down inside the zone — poll for the release that commits the
    /// merge (during a native window drag the app sees no mouse-up event, so a
    /// short poll on `pressedMouseButtons` is the reliable end-of-drag signal).
    private func watchForMergeDrop() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.mergeArmed, self.state.phase == .settled else { return }
            if NSEvent.pressedMouseButtons & 1 == 1 { self.watchForMergeDrop(); return }
            if self.mergeDisplay() != nil {
                self.mergeBack(animated: !Self.reduceMotion)
            } else {
                self.disarmMergeHint()
            }
        }
    }

    func disarmMergeHint() {
        mergeArmed = false
        if let model, model.detachMergeHint {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
                model.detachMergeHint = false
            }
        }
    }

    /// Close the window and hand the session back to the notch panel. With
    /// animation, the window sinks toward the notch as it fades — the reverse
    /// of the tear-off — while the island unfurls to receive it.
    func mergeBack(animated: Bool) {
        guard let model else { window.close(); return }
        let display = mergeDisplay() ?? model.knownDisplays.first
        disarmMergeHint()
        state.phase = .merging

        let reopen = { [weak self] in
            guard let self else { return }
            model.reattachDetachedSession(self.session,
                                          snapshot: self.threadStore?.turns,
                                          draft: self.state.composeDraft,
                                          on: display)
            self.window.close()
        }

        if animated, let notch = display.flatMap({ model.restingNotchScreenRect(on: $0) }) {
            let target = NSRect(x: notch.midX - 160, y: notch.minY - 60,
                                width: 320, height: 88)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.26
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.5, 0.05, 0.85, 0.6)
                window.animator().setFrame(target, display: true)
                window.animator().alphaValue = 0
            } completionHandler: { reopen() }
        } else {
            reopen()
        }
    }
}
