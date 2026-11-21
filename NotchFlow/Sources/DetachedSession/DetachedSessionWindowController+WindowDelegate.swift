import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
extension DetachedSessionWindowController {
    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        hasHeldKey = true
        // The user came back mid-retreat (clicked the capsule while it was on its
        // way out). Put the window back at full strength — the fade already wrote
        // alpha down the animator's path, so it has to be written back by hand.
        guard state.exiting else { return }
        state.exiting = false
        window?.animator().alphaValue = 1
    }

    /// A force-click composer nobody typed into takes itself off screen the
    /// moment the keyboard leaves it.
    ///
    /// Nothing else ever closed it. Unpinned it only *slips behind* the app in
    /// front, which reads as gone — but it is still there, on every Space
    /// (`.moveToActiveSpace`), and the next `NSApp.activate(ignoringOtherApps:)`
    /// from any other part of the app raises it back over everything. A gesture
    /// as easy to trip as a force click then leaves a trail of empty capsules
    /// that keep reappearing, which is what `retirePointerWindows` was patching
    /// from the far end (retire the *previous* one when a new one opens) instead
    /// of never leaving one behind.
    ///
    /// Only the untouched composer goes. A draft, an answer, or a tack is the
    /// user's, and stays until they close it.
    func windowDidResignKey(_ notification: Notification) {
        // Still inside the gesture that opened this window: the app underneath
        // has just taken activation back off the summoning click. That is not
        // the user leaving — take key back and close nothing.
        if isInSummonGrace { return reclaimKeyAfterSummon() }
        guard isUntouchedComposer else { return }
        // Resign also fires on the way *to* another window of this app, and
        // AppKit can hand key across in two steps. Settle first, then check.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isUntouchedComposer,
                  let window = self.window, window.isVisible, !window.isKeyWindow
            else { return }
            self.fadeOutAndClose()
        }
    }

    /// A pointer-side composer with nothing in it and nothing holding it open.
    private var isUntouchedComposer: Bool {
        guard compactShortcut, hasHeldKey, !state.pinned, !isDrawingPressure,
              case .shortcutComposer = state.session
        else { return false }
        // The pointer is ON the box. Whatever took the keyboard away, the user is
        // reaching for this — picking it up, going for one of its shortcuts,
        // about to type in it. A window is never taken out from under the hand
        // that is on it, and this is what closed the box mid-drag: the press
        // that grabbed it also handed activation back to the app underneath, and
        // the box read that as the keyboard leaving and dissolved.
        if let window,
           window.frame.insetBy(dx: -8, dy: -8).contains(NSEvent.mouseLocation) {
            return false
        }
        return state.compactPromptDraft
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The entrance, run backwards: the face settles back toward the pointer it
    /// grew out of while the window sinks under it.
    ///
    /// A bare alpha ramp on its own was the stiff version — the capsule arrives by
    /// swelling out of the caret over a 0.36s spring and left by simply ceasing to
    /// be there, on a curve half that long, with nothing moving. The shape has to
    /// go the way it came: `state.exiting` collapses the face on its entrance
    /// anchor, and the window's own alpha carries the shadow (which AppKit derives
    /// from the silhouette and will not fade with SwiftUI's opacity) out with it.
    private func fadeOutAndClose() {
        guard let window else { return }
        guard !Self.reduceMotion else { return window.close() }
        state.exiting = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.26
            // Holds near full for the first third, so the collapse is *seen*
            // before the window is gone; a symmetric ease would have faded the
            // shape out from under its own move.
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.55, 0, 0.85, 0.35)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // Key came back during the retreat: `windowDidBecomeKey` has already
            // put it back, and this completion is the tail of a cancelled fade.
            guard let self, let window = self.window,
                  !window.isKeyWindow, self.state.exiting else { return }
            window.close()
        }
    }

    func windowWillClose(_ notification: Notification) {
        endRide()
        stopCompactGlide()
        // The reveal's commit now also rides SwiftUI's animation completion, which
        // no work item can cancel — the generation bump is what retires it.
        compactRevealGeneration += 1
        compactRevealCompletion?.cancel()
        compactRevealCompletion = nil
        state.onRevealArmed = nil
        summonReleaseTimer?.invalidate()
        summonReleaseTimer = nil
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        moveObserver = nil
        disarmMergeHint()
        if let threadStore {
            // Match the main panel's close semantics for Force Touch: closing the
            // surface drops our cancellation handle, never the round itself. The
            // task keeps feeding its in-flight snapshot and settles into Recent.
            if state.forceTouchInvocation {
                model?.detachCompactRound(threadID: threadStore.threadID)
            }
            model?.releaseDetachedThread(threadStore.threadID)
        }
        Self.controllers.removeAll { $0 === self }
    }
}
