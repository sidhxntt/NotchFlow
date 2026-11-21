import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
extension DetachedSessionWindowController {
    // MARK: - The force click, before it is a composer

    /// Still on screen in some pressure phase. `ForceClickHerald`'s latch checks
    /// this, so a window closed from underneath it (Escape, ⌘W, another shortcut
    /// retiring it) can't leave the press stream latched out for good.
    var isPressureAlive: Bool { isDrawingPressure && window?.isVisible == true }

    /// Open the composer *as the force click itself*: the real window, at the real
    /// geometry, drawing nothing but its own input capsule's rounded left cap.
    ///
    /// This is the one-glass rule (see `ForceClickHerald`). The press is not a
    /// stand-in that later hands over to a window — it IS this window, small. The
    /// cue and the composer were two `.clear` glass surfaces before, and glass
    /// multiplies: every frame where both stood measured more than twice as dark as
    /// either alone, which is exactly the "opens opaque, then turns into glass"
    /// this replaces.
    static func beginPressureComposer(shortcutID: UUID, model: NotchModel,
                                      at pointer: NSPoint)
        -> DetachedSessionWindowController? {
        guard requireProductEntitlement() else { return nil }
        guard NSScreen.containing(pointer) != nil else { return nil }
        // A composer already standing for this shortcut owns an unsent draft and a
        // spot the user put it in. A press must not shrink that back to a cap and
        // drag it to the pointer, so it draws nothing and the fire path re-anchors
        // the existing window exactly as it always did.
        if let existing = controllers.first(where: { $0.compactShortcutID == shortcutID }) {
            return existing.isDrawingPressure ? existing : nil
        }
        let session = DetachedSession.shortcutComposer(id: shortcutID)
        let face = DetachedCardFace(title: L("shortcuts.promptAction.window.context"),
                                    subtitle: "", isAgent: false, running: false)
        let c = DetachedSessionWindowController(
            session: session, face: face, model: model,
            compactShortcut: true, compactShortcutID: shortcutID)
        c.isDrawingPressure = true
        c.state.forceTouchInvocation = true
        c.state.pressDepth = 0
        // The capsule is already standing by the time there is anything to put in
        // it, so the face must never replay its own swell on top of the stretch.
        c.state.grownIn = true
        c.state.phase = .settled
        c.summonPointer = pointer
        controllers.append(c)
        let rect = composerWindowRect(near: pointer)
        c.anchorEntrance(rect: rect, pointer: pointer)
        c.makeWindow(at: rect, model: model)
        // It is a cue until it fires: it must never take a click, a key press or
        // the pointer away from the app the user is pressing inside of. The whole
        // gesture happens in someone else's window.
        c.window.ignoresMouseEvents = true
        c.window.alphaValue = 0
        // AppKit derives a borderless window's shadow from the drawn silhouette and
        // caches it, so a shadow sampled around the cap would stay cap-sized for the
        // window's whole life. It comes on once the stretch has settled.
        c.window.hasShadow = false
        return c
    }

    /// One trackpad frame. The cap is drawn at full size and scaled about its own
    /// centre, so a press costs one transform and no layout at all.
    func drawPressure(_ eased: Double, at pointer: NSPoint) {
        guard isDrawingPressure, let window else { return }
        // A press can wobble back under the floor and push again inside the 130ms
        // it takes to fade out. Kill the retreat before writing this frame's alpha,
        // or the fade keeps driving the window to 0 underneath the live press.
        if pressureRetracting {
            pressureRetracting = false
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0
                window.animator().alphaValue = eased
            }
        }
        summonPointer = pointer
        let rect = Self.composerWindowRect(near: pointer)
        window.setFrame(rect, display: false)
        let scale = ForceClickHerald.seedScale + (1 - ForceClickHerald.seedScale) * eased
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let layer = window.contentView?.layer {
            // The cap's centre in the content view's own (bottom-left) coordinates.
            let centre = CGPoint(x: CompactShortcutMetrics.inset
                                    + CompactShortcutMetrics.capDiameter / 2,
                                 y: rect.height - CompactShortcutMetrics.caretOffset.y)
            layer.transform = CATransform3DConcat(
                CATransform3DMakeTranslation(-centre.x, -centre.y, 0),
                CATransform3DConcat(CATransform3DMakeScale(scale, scale, 1),
                                    CATransform3DMakeTranslation(centre.x, centre.y, 0)))
        }
        window.alphaValue = eased
        CATransaction.commit()
        // The fill deepens on its own axis, so a slow press keeps showing progress
        // after the growth has all but finished — the solidifying half of the cue.
        state.pressDepth = eased
        if !window.isVisible { window.orderFrontRegardless() }
    }

    /// The press fired: the cap springs out to the capsule's full width and the
    /// window stops being a cue. One surface, one spring — the composer's field and
    /// badge arrive *inside* a shape that is already standing there.
    func openFromPressure() {
        guard isDrawingPressure, let window else { return }
        // Hand the shape back to SwiftUI at its true size before stretching it: the
        // press scaled the whole layer, and stretching a still-scaled capsule would
        // carry that scale into the composer's final geometry.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        window.contentView?.layer?.transform = CATransform3DIdentity
        window.alphaValue = 1
        CATransaction.commit()
        window.ignoresMouseEvents = false
        withAnimation(ForceClickHerald.stretch) { state.pressDepth = nil }
        applyPinLevel()
        armMergeTracking()
        // The silhouette the shadow is derived from is only final once the spring
        // is — the same beat `playPointerEntrance` waits out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            guard let self, let window = self.window, self.isDrawingPressure else { return }
            self.isDrawingPressure = false
            window.hasShadow = true
            window.invalidateShadow()
        }
    }

    /// The press let go — it fell short, or it fired and found nothing to work on.
    /// The capsule fades out the way it came and the window goes with it: nothing
    /// was typed into it and nothing was captured, so there is nothing to keep.
    func dismissPressure(collapsing: Bool) {
        guard isDrawingPressure else { return }
        guard let window, window.isVisible else { return closePressureWindow() }
        if collapsing, !Self.reduceMotion {
            withAnimation(.easeOut(duration: 0.13)) { state.pressDepth = 0 }
        }
        pressureRetracting = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.13
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // A press that resumed during the fade has already re-shown the window
            // at a live alpha; closing it here would blink it away.
            guard let self, self.pressureRetracting,
                  self.window?.alphaValue ?? 0 < 0.02 else { return }
            self.closePressureWindow()
        }
    }

    private func closePressureWindow() {
        guard isDrawingPressure else { return }
        isDrawingPressure = false
        pressureRetracting = false
        state.pressDepth = nil
        window?.contentView?.layer?.transform = CATransform3DIdentity
        window?.close()
    }
}
