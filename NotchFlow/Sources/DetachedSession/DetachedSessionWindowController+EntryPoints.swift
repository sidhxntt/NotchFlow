import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
extension DetachedSessionWindowController {
    // MARK: Entry points

    /// V0 (the header button): open (or focus) the session's window, fading in
    /// right where the panel is — the full window from frame one, no thumbnail
    /// stage.
    static func present(session: DetachedSession, face: DetachedCardFace,
                        model: NotchModel, from spawnRect: NSRect?) {
        guard requireProductEntitlement() else { return }
        if let existing = controller(for: session) {
            existing.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let c = DetachedSessionWindowController(session: session, face: face, model: model)
        controllers.append(c)
        c.makeWindow(at: spawnRect ?? c.centeredDefaultRect(), model: model)
        if reduceMotion {
            c.window.alphaValue = 1
        } else {
            c.window.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                c.window.animator().alphaValue = 1
            }
        }
        c.state.phase = .settled
        c.finishSettle()
    }

    /// V1: the tear-off crossed its threshold mid-drag. The COMPLETE window is
    /// born in place over the panel — full size, full session content — and
    /// rides the mouse until release. No intermediate card: what's under the
    /// hand IS the window.
    static func beginDragDetach(session: DetachedSession, face: DetachedCardFace,
                                model: NotchModel, spawnRect: NSRect) {
        guard requireProductEntitlement() else { return }
        if let existing = controller(for: session) {
            // Already windowed (shouldn't normally arm, but never fork a twin).
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        let c = DetachedSessionWindowController(session: session, face: face, model: model)
        controllers.append(c)
        c.makeWindow(at: spawnRect, model: model)
        c.beginRide()
    }

    /// The pointer's side of the screen holds exactly ONE shortcut window: a new
    /// answer beside the cursor retires whatever the last shortcut left there.
    ///
    /// Without this they pile up invisibly. Nothing closes a compact window when
    /// it loses focus, and it is unpinned (`.normal` level), so clicking back
    /// into the source app merely slips it *behind* that app — the user reads
    /// that as "gone". It isn't: every later `NSApp.activate(ignoringOtherApps:)`
    /// raises the whole app, that window with it, and since every shortcut
    /// anchors beside the same pointer they stack on the same spot. Esc then
    /// closes only the front one and hands key status to the app's next window —
    /// the older answer, sitting right underneath, looking like it came back from
    /// the dead.
    ///
    /// Windows torn out of the panel are the user's own and are left alone; this
    /// is only the transient pointer-side surface.
    private static func retirePointerWindows(besides shortcutID: UUID) {
        for c in controllers
        where c.compactShortcut && c.compactShortcutID != shortcutID {
            c.window.close()
        }
    }

    /// Open a prompt-shortcut result beside the pointer location captured at the
    /// hot-key edge. The thread is already running headlessly, so the first frame
    /// can attach to its live mirror without ever unfolding the notch.
    static func presentCompactShortcut(shortcutID: UUID, threadID: UUID, title: String,
                                       model: NotchModel, near pointer: NSPoint,
                                       sourceApplication: NSRunningApplication?) {
        guard requireProductEntitlement() else { return }
        retirePointerWindows(besides: shortcutID)
        if let existing = controllers.first(where: {
            $0.compactShortcutID == shortcutID
        }) {
            existing.replaceCompactThread(with: threadID, title: title,
                                          near: pointer,
                                          sourceApplication: sourceApplication)
            return
        }
        let session = DetachedSession.thread(id: threadID)
        if let existing = controller(for: session) {
            existing.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let face = DetachedCardFace(title: title, subtitle: "",
                                    isAgent: false, running: true)
        let c = DetachedSessionWindowController(
            session: session, face: face, model: model,
            compactShortcut: true, compactShortcutID: shortcutID,
            replacementApplication: sourceApplication)
        controllers.append(c)
        let rect = c.compactRect(near: pointer)
        c.anchorEntrance(rect: rect, pointer: pointer)
        c.makeWindow(at: rect, model: model)
        c.playPointerEntrance()
        c.state.phase = .settled
        c.finishSettle()
    }

    /// Open the empty-prompt form of a prompt shortcut. Selection capture has
    /// already happened; the small window merely asks what to do with that text.
    /// Enter promotes the same shell into the streaming result, so there is no
    /// second window and no intermediate trip through the notch.
    static func presentCompactShortcutComposer(shortcutID: UUID, selectedText: String,
                                               model: NotchModel, near pointer: NSPoint,
                                               sourceApplication: NSRunningApplication?,
                                               forceTouch: Bool = false) {
        guard requireProductEntitlement() else { return }
        retirePointerWindows(besides: shortcutID)
        if let existing = controllers.first(where: {
            $0.compactShortcutID == shortcutID
        }) {
            existing.replaceCompactComposer(selectedText: selectedText,
                                             near: pointer,
                                             sourceApplication: sourceApplication,
                                             forceTouch: forceTouch)
            return
        }
        let session = DetachedSession.shortcutComposer(id: shortcutID)
        let face = DetachedCardFace(title: L("shortcuts.promptAction.window.context"),
                                    subtitle: "", isAgent: false, running: false)
        let c = DetachedSessionWindowController(
            session: session, face: face, model: model,
            compactShortcut: true, compactShortcutID: shortcutID,
            replacementApplication: sourceApplication)
        c.state.compactSourceText = selectedText
        c.state.forceTouchInvocation = forceTouch
        c.summonPointer = pointer
        controllers.append(c)
        let rect = c.compactRect(near: pointer, asComposer: true)
        c.anchorEntrance(rect: rect, pointer: pointer)
        c.state.grownIn = ForceClickHerald.shared.isPresenting
        c.makeWindow(at: rect, model: model)
        if c.state.grownIn {
            // Nothing to fade up: a press that drew a capsule grew THIS window
            // (`beginPressureComposer`), so the shape is already standing and the
            // branch above should have found it. Reaching here means the press let
            // go of it — appear at full strength rather than swelling over it.
            c.window.alphaValue = 1
            ForceClickHerald.shared.handOff()
        } else {
            c.playPointerEntrance()
        }
        c.state.phase = .settled
        c.finishSettle()
    }

    /// A selection that only answered after its composer was already standing.
    ///
    /// The composer no longer waits for the accessibility read: the first,
    /// synchronous pass answers instantly for a native app, and when it comes
    /// back empty the box opens anyway while a browser's web tree is still being
    /// woken up (`SelectedTextCapture.current(firstPassEmpty:completion:)`). This
    /// is where that late text lands.
    ///
    /// It only ever ADDS context. A window the user has already sent, or one
    /// whose badge they dropped, is left exactly as it is — a late arrival must
    /// never overwrite what someone did in the meantime.
    static func attachCompactSelection(shortcutID: UUID, text: String) {
        guard !text.isEmpty,
              let c = controllers.first(where: { $0.compactShortcutID == shortcutID }),
              c.state.compactSourceText.isEmpty
        else { return }
        guard case .shortcutComposer = c.state.session else { return }
        withAnimation(.easeOut(duration: 0.18)) { c.state.compactSourceText = text }
    }
}
