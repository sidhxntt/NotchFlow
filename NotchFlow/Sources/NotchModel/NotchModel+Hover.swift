import SwiftUI
import Combine
import AppKit   // NSWorkspace — opening Notes/Reminders for a Recent capture
import Carbon.HIToolbox
import UniformTypeIdentifiers   // UTType — is a pasted file URL an image? (agent ⌘V)

@MainActor
extension NotchModel {
    // MARK: - Hover ground truth

    func registerPanelFrame(_ frame: CGRect, restHeight: CGFloat,
                            hardwareNotchWidth: CGFloat?,
                            for display: CGDirectDisplayID) {
        panelScreenFrames[display] = frame
        restHeights[display] = restHeight
        hardwareNotchWidths[display] = hardwareNotchWidth
    }

    /// Deliberately a plain var write — this fires per frame during the island's
    /// springs, and publishing it would invalidate the whole tree each frame.
    func registerIslandFrame(_ frame: CGRect, for display: CGDirectDisplayID?) {
        guard let display else { return }
        islandFrames[display] = frame
        onIslandFrameChange?(display, frame)
    }

    func registerRestingEars(left: CGFloat, right: CGFloat) {
        restingEarLeft = left
        restingEarRight = right
    }

    /// Whether the pointer is really over `display`'s island right now.
    /// `slop` pads the test outward, absorbing measurement/animation slack.
    /// Returns nil when the geometry isn't known (yet) — callers then fall back
    /// to trusting the event, which is the pre-verification behavior.
    func pointerInsideIsland(on display: CGDirectDisplayID?, slop: CGFloat) -> Bool? {
        guard let display,
              let panel = panelScreenFrames[display],
              let island = islandFrames[display] else { return nil }
        // SwiftUI global space (top-left origin, relative to the borderless
        // canvas window) → screen space (bottom-left origin).
        let screenIsland = CGRect(x: panel.minX + island.minX,
                                  y: panel.maxY - island.maxY,
                                  width: island.width, height: island.height)
        return screenIsland.insetBy(dx: -slop, dy: -slop).contains(NSEvent.mouseLocation)
    }

    /// Where the RESTING notch sits on `display`, in screen coordinates —
    /// computed from the registered canvas frame and rest height, NOT from the
    /// live layout, so it holds still while the island animates. This is the
    /// reference for enter events on a closed panel: during the collapse the
    /// live frame is mid-sweep and would validate exactly the synthetic enters
    /// the sweep generates.
    ///
    /// The width is the MEASURED hardware notch (`hardwareNotchWidths`), falling
    /// back to the drawn constant only on screens with no cutout to measure. The
    /// drawn island is 192pt against a ~185pt physical notch, so trusting the
    /// design constant here made ~3.5pt of live menu bar on each shoulder open
    /// the panel on contact.
    private func pointerInsideRestingNotch(on display: CGDirectDisplayID?, slop: CGFloat) -> Bool? {
        guard let display,
              let panel = panelScreenFrames[display],
              let restHeight = restHeights[display] else { return nil }
        let width = hardwareNotchWidths[display] ?? Tokens.notchWidth
        var rect = CGRect(x: panel.midX - width / 2,
                          y: panel.maxY - restHeight,
                          width: width,
                          height: restHeight)
        // While the resting notch is flexed into its ears — background work's
        // verb/clock, the finished-count badge, or the copy-sense hint — those
        // strips are hoverable too. Widths come from the view's registration
        // (measured content); both are zero on a bare notch.
        if !open {
            rect.origin.x -= restingEarLeft
            rect.size.width += restingEarLeft + restingEarRight
        }
        return rect.insetBy(dx: -slop, dy: -slop).contains(NSEvent.mouseLocation)
    }

    /// The hover-enter entry point (the view calls this, not `openPanel`,
    /// so keyboard summons and notification taps stay ungated): drop enters
    /// whose pointer isn't actually over the island — synthetic events fired
    /// by the animating boundary sweeping under a parked pointer.
    ///   · Panel closed → test against the STATIC resting-notch rect (the live
    ///     frame is mid-collapse and would validate its own sweep artifacts).
    ///   · Panel open → test against the live island frame with generous slop
    ///     (an honest re-entry during the close dissolve must still cancel it).
    /// Unknown geometry (nil) falls back to trusting the event.
    ///
    /// On the closed→open edge a dwell gate applies: reaching for a menu-bar
    /// item near the notch must not unfurl the panel over it.
    func hoverEntered(on display: CGDirectDisplayID?, velocity: CGVector) {
        if open {
            if pointerInsideIsland(on: display, slop: 16) == false { return }
            openPanel(on: display, velocity: velocity)
            return
        }
        if pointerInsideRestingNotch(on: display, slop: 0) == false { return }
        let sensitivity = HoverSensitivity.current
        // The pointer has to have DONE the entering. A stationary cursor can be
        // handed a mouseEntered by AppKit whenever the tracked geometry moves
        // under it — and the resting notch's geometry moves on its own: the busy
        // verb/clock and the copy-sense hint flex the ears out by tens of points,
        // straight over the menu bar. That is the island arriving at the cursor,
        // not the cursor arriving at the island, and it must not open anything.
        // (`collapseOnLeave` has carried the mirror of this test for exits all
        // along; this is the missing half.)
        guard MouseVelocityTracker.shared.cursorMoved(within: 0.2) else { return }
        // The click level answers a hover with a gesture instead of an unfurl:
        // one haptic tap and a few points of outward flex (see `hoverPeek`), so
        // the notch is visibly awake and reachable while the panel stays folded
        // until the click. Nothing below this line runs: there is no dwell to
        // schedule because this level never opens from hover.
        if sensitivity.opensOnClickOnly {
            beginHoverPeek(on: display)
            return
        }
        guard let delay = sensitivity.hoverOpenDelay else { return }
        if delay == 0 {
            openPanel(on: display, velocity: velocity)
        } else {
            armHoverDwell(on: display, delay: delay)
        }
    }

    func cancelHoverDwell() {
        hoverDwellTask?.cancel()
        hoverDwellTask = nil
    }

    /// A timer rather than an arrival-vector heuristic makes each setting
    /// perceptible on every approach. The pointer is checked again at the end,
    /// so crossing the notch on the way to a menu-bar item cannot open it.
    private func armHoverDwell(on display: CGDirectDisplayID?, delay: TimeInterval) {
        cancelHoverDwell()
        hoverDwellTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.hoverDwellTask = nil
            guard !self.open,
                  self.pointerInsideRestingNotch(on: display, slop: 0) != false
            else { return }
            self.openPanel(on: display,
                           velocity: MouseVelocityTracker.shared.entryVelocity())
        }
    }
    // MARK: - Click to open (the `.click` sensitivity)

    /// How far the resting notch swells out under the pointer at the click level,
    /// and — the same number, deliberately — how far past the resting rect the
    /// pointer may drift before the swell drops. Small on purpose: the shape has
    /// to read as the notch *noticing* you, not as it opening. Anything bigger and
    /// it starts promising an unfurl it isn't going to deliver. `NotchIsland`
    /// turns it into the scale it renders.
    static let hoverPeekOut: CGFloat = 5

    /// Poll interval of the peek watch — the entry watch's cadence, for the same
    /// reason: short enough that the flex drops the moment the pointer is gone.
    private static let hoverPeekTick: TimeInterval = 0.1

    /// Raise the acknowledgement flex, tap once, and watch for the pointer to go.
    ///
    /// The leave is POLLED against the static resting rect rather than driven by
    /// the island's `.onHover`, because the flex moves the island's own tracking
    /// boundary — precisely the geometry that synthesizes bogus enter/exit events
    /// (see `pointerInsideIsland`). Judging both edges against a rect the flex
    /// can't move, and releasing at the flex's own reach rather than at the rect's
    /// edge, gives the peek plain hysteresis: it cannot flap, and drifting onto
    /// the flexed shoulder doesn't cancel the very gesture that put it there.
    private func beginHoverPeek(on display: CGDirectDisplayID?) {
        // Geometry has to be known — the watch below is the only thing that ever
        // lowers the flex, and it can't answer against a rect it can't compute.
        guard let display,
              pointerInsideRestingNotch(on: display, slop: 0) == true else { return }
        if hoverPeek != display {
            hoverPeek = display
            // The same tap the open would have given, at the moment the notch
            // acknowledges the pointer. It IS the feedback here: with no unfurl
            // to watch, the flex alone is a very quiet "seen you".
            Haptics.alignment()
        }
        armHoverPeekWatch(display: display)
    }

    private func armHoverPeekWatch(display: CGDirectDisplayID?) {
        hoverPeekTask?.cancel()
        hoverPeekTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(NotchModel.hoverPeekTick * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.hoverPeekTask = nil
            guard self.hoverPeek != nil, !self.open else { return self.endHoverPeek() }
            guard self.pointerInsideRestingNotch(on: display,
                                                 slop: NotchModel.hoverPeekOut) == true
            else { return self.endHoverPeek() }
            self.armHoverPeekWatch(display: display)
        }
    }

    /// Drop the flex and stop watching. Idempotent — the open path, the level
    /// change and the watch itself all call it.
    func endHoverPeek() {
        hoverPeekTask?.cancel()
        hoverPeekTask = nil
        if hoverPeek != nil { hoverPeek = nil }
    }

    /// A click landed on the resting notch. Only the click level mounts the
    /// target (see `NotchIsland`), so a click arriving here is unambiguously the
    /// open gesture.
    ///
    /// It opens at ZERO velocity, deliberately. The entry vector exists to let a
    /// hover-open inherit the momentum of the approach that caused it — but a
    /// click has no approach: the pointer has been parked on the notch since the
    /// peek went up. Feeding it `entryVelocity()` anyway read the last 120ms of
    /// samples, which by then is nothing but the hand's final settle and the
    /// click's own jitter — a couple of points, but over a few milliseconds, so
    /// hundreds of points per second. Every click therefore unfurled with a
    /// sideways lean and shove it had no reason to have. A parked pointer gets
    /// the calm, centered bloom.
    func notchClicked(on display: CGDirectDisplayID?) {
        // The press fires this; the rest of that drag's ticks find it already
        // open and turn back.
        guard !open else { return }
        // The flex is NOT retired here. Dropping it in this call would put it in
        // the same transaction as `open`, and the island's own peek animation
        // would then govern the unfurl instead of the open spring. The rendered
        // swell already collapses on the open (see `NotchIsland.peekScaleX`); the
        // watch clears the flag a tick later, when nothing on screen depends on it.
        openPanel(on: display)
    }

    /// The one writer of the hover level: persists it and updates the observable
    /// shadow the island renders from, so switching away from `.click` retires a
    /// standing flex instead of leaving it stuck out.
    func applyHoverSensitivity(_ newValue: HoverSensitivity) {
        HoverSensitivity.current = newValue
        hoverSensitivity = newValue
        cancelHoverDwell()
        if !newValue.opensOnClickOnly { endHoverPeek() }
    }
}
