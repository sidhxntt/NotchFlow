import SwiftUI
import AppKit

/// Hangs a menu card under the view it is attached to, in a window of its OWN —
/// the reason these menus are true overlays instead of another block in the
/// panel's stack, and the reason their glass looks like the island's.
///
/// This is a zero-size probe dropped in an anchor's `.background`. It takes no
/// space, so nothing moves when the menu opens; it reports the anchor's SCREEN
/// rect (from its own `NSView`, so it stays right through island re-layouts and
/// display switches); and it parents a borderless child panel to the island's
/// window, hung just under that rect. Being a separate window is what lets the
/// card overhang the island's edge and spill onto the desktop — inside the
/// SwiftUI tree it would be clipped by the glass form and would push the panel
/// taller.
///
/// It is also the only way these cards can wear the *same* glass. An `NSPopover`
/// hosts its content in a window of the system's own making: `nativeGlass` has no
/// transparent backdrop to refract there, so the card renders as the veil alone —
/// a flat, opaque slab — while the identical recipe over a clear panel reads as
/// glass. One presentation, one look.
///
/// The child panel deliberately **cannot become key** (`MenuCardPanel`), so
/// clicking a row never pulls first-responder off the prompt field — you can keep
/// typing to filter with the pointer sitting on the card. It closes itself when
/// the menu shuts, when the probe leaves the tree (panel folded, thread opened),
/// and when its host window goes away.
struct MenuCardWindow: ViewModifier {
    let open: Bool
    /// Hang the card from the anchor's leading edge (a prompt row, a chip) or
    /// centred on it (the 1pt probe the agent card hangs from).
    var centered: Bool = false
    /// Put the card wholly above and to the left of its anchor, with the card's
    /// bottom-trailing corner nearest the control. Used by result metadata so the
    /// menu doesn't cover the follow-up composer below it.
    var upperLeading: Bool = false
    /// A click that isn't part of using the menu — in another app (`insideApp`
    /// false) or anywhere in ours but the card and the anchor.
    let onDismiss: (_ insideApp: Bool) -> Void
    @ViewBuilder var card: () -> AnyView

    func body(content: Content) -> some View {
        content.background(
            MenuCardHost(open: open, centered: centered, upperLeading: upperLeading,
                         onDismiss: onDismiss, card: card())
        )
    }
}

private struct MenuCardHost: NSViewRepresentable {
    let open: Bool
    let centered: Bool
    let upperLeading: Bool
    let onDismiss: (Bool) -> Void
    let card: AnyView

    func makeNSView(context: Context) -> NSView { MenuCardAnchorView() }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? MenuCardAnchorView)?.apply(card: card, open: open,
                                             centered: centered,
                                             upperLeading: upperLeading,
                                             onDismiss: onDismiss)
    }

    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        (view as? MenuCardAnchorView)?.closeMenu()
    }
}

/// A borderless panel that never takes key focus — a menu card's window.
/// Everything it hosts is pointer-driven; the keyboard stays with the panel the
/// menu was summoned from.
private final class MenuCardPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The probe view: measures, positions, and owns the menu's panel.
private final class MenuCardAnchorView: NSView {
    /// Air between the anchor's bottom edge and the card's top.
    private static let gap: CGFloat = 6
    /// Transparent margin inside the window, around the card — the card draws its
    /// own two shadows in SwiftUI, and a window sized flush to the card would clip
    /// them off. Also the slack the position math has to add back.
    private static let shadowMargin: CGFloat = 28

    private var panel: MenuCardPanel?
    private var hosting: NSHostingView<AnyView>?
    private var isOpen = false
    private var centered = false
    private var upperLeading = false
    /// What a click outside the card reports to — see `installDismissMonitors`.
    private var onDismiss: ((Bool) -> Void)?
    private var clickMonitors: [Any] = []
    /// The host window's move/resize notifications. The card is a child window
    /// holding an ABSOLUTE screen frame, so anything that shifts the anchor
    /// without re-running this probe's `layout()` — the island animating open,
    /// the panel growing, a display change — would otherwise leave the card
    /// parked at the last position it was told about. That is the drift.
    private var frameObservers: [NSObjectProtocol] = []

    func apply(card: AnyView, open: Bool, centered: Bool, upperLeading: Bool,
               onDismiss: @escaping (Bool) -> Void) {
        self.onDismiss = onDismiss
        self.centered = centered
        self.upperLeading = upperLeading
        guard open else {
            closeMenu()
            return
        }
        let padded = AnyView(card.padding(Self.shadowMargin))
        if let hosting {
            hosting.rootView = padded
        } else {
            openMenu(with: padded)
        }
        reposition()
    }

    private func openMenu(with card: AnyView) {
        guard let host = window else { return }
        let hosting = NSHostingView(rootView: card)
        let panel = MenuCardPanel(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false          // the card draws its own
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = false
        // Dark like the island, and along for the ride across Spaces / full-screen.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                    .stationary, .ignoresCycle]
        panel.contentView = hosting
        panel.alphaValue = 0
        // A CHILD of the island's window: it rides along when that window moves,
        // stays ordered above it whatever level the island is at (the panel drops
        // to `.floating` while an IME is composing), and goes away with it.
        host.addChildWindow(panel, ordered: .above)
        self.panel = panel
        self.hosting = hosting
        self.isOpen = true
        installDismissMonitors()
        installFrameObservers(on: host)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    func closeMenu() {
        removeDismissMonitors()
        removeFrameObservers()
        guard let panel else { return }
        self.panel = nil
        self.hosting = nil
        self.isOpen = false
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func installFrameObservers(on host: NSWindow) {
        guard frameObservers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                     NSWindow.didChangeScreenNotification] {
            frameObservers.append(
                center.addObserver(forName: name, object: host, queue: .main) { [weak self] _ in
                    self?.reposition()
                })
        }
    }

    private func removeFrameObservers() {
        frameObservers.forEach(NotificationCenter.default.removeObserver)
        frameObservers.removeAll()
    }

    // MARK: - Click-away

    /// A click anywhere but the card takes the menu down — the one thing an
    /// `NSMenu` gives for free and a hand-built floating card does not. The panel
    /// can't become key (that's what keeps the caret in the prompt), so no
    /// resign-key event ever arrives to close it; watching the mouse is the way.
    /// Two monitors: `global` for clicks in other apps and on the desktop, `local`
    /// for clicks inside our own windows.
    private func installDismissMonitors() {
        guard clickMonitors.isEmpty else { return }
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] event in
            self?.dismiss(on: event, insideApp: false)
        }) {
            clickMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { [weak self] event in
            self?.dismiss(on: event, insideApp: true)
            return event
        }) {
            clickMonitors.append(local)
        }
    }

    private func removeDismissMonitors() {
        clickMonitors.forEach(NSEvent.removeMonitor)
        clickMonitors.removeAll()
    }

    /// Take the menu down for a click that isn't part of using it. Two clicks are
    /// NOT that: one on the card (a row is being picked — it must land first, and
    /// closing here would pull the row out from under it), and one on the anchor
    /// this probe measures (the chip that opened the menu, or the prompt row whose
    /// command word the user is editing — dismissing there would wipe what they
    /// are mid-way through fixing).
    private func dismiss(on event: NSEvent, insideApp: Bool) {
        guard isOpen, let onDismiss else { return }
        if insideApp {
            if event.window === panel {
                // The panel is padded for the card's shadows. Its top padding
                // overlaps the chip that opened it, so treating the WHOLE panel
                // as menu content leaves an invisible sheet over the chip: a
                // second click lands in that sheet and can never toggle the menu
                // closed. Only the inset card itself is interactive; a click in
                // the transparent shadow gutter is click-away and dismisses.
                if let contentView = panel?.contentView {
                    let point = contentView.convert(event.locationInWindow, from: nil)
                    let cardBounds = contentView.bounds.insetBy(
                        dx: Self.shadowMargin, dy: Self.shadowMargin)
                    if cardBounds.contains(point) { return }
                }
                onDismiss(true)
                return
            }
            if event.window === window,
               bounds.contains(convert(event.locationInWindow, from: nil)) { return }
        }
        onDismiss(insideApp)
    }

    /// Park the card just under the anchor, left edges flush (or centred on it).
    /// Runs on every apply and on every layout pass, so a growing prompt box (or
    /// the island re-laying out under it) carries the card with it instead of
    /// leaving it stranded mid-panel.
    private func reposition() {
        guard let panel, let hosting, let host = window else { return }
        let size = hosting.fittingSize
        let anchor = host.convertToScreen(convert(bounds, to: nil))
        let margin = Self.shadowMargin
        var origin: CGPoint
        if upperLeading {
            // Actual card bounds exclude `shadowMargin`: align their bottom-right
            // with the control's top-right. The card therefore opens above and to
            // the left while still belonging visually to the button, rather than
            // floating a full button-width too far left.
            origin = CGPoint(
                x: anchor.maxX - size.width + margin,
                y: anchor.maxY + Self.gap - margin
            )
        } else {
            origin = CGPoint(
                x: (centered ? anchor.midX - (size.width - margin * 2) / 2
                             : anchor.minX) - margin,
                y: anchor.minY - Self.gap - size.height + margin
            )
        }
        // Never let it walk off the bottom of the display it's on.
        if let visible = (host.screen ?? NSScreen.main)?.visibleFrame {
            origin.y = max(origin.y, visible.minY + 8 - margin)
            origin.y = min(origin.y, visible.maxY - size.height + margin - 8)
            // Nor off either side — a chip near the island's edge would otherwise
            // hang its card half off the screen.
            origin.x = min(max(origin.x, visible.minX + 8 - margin),
                           visible.maxX - size.width + margin - 8)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    override func layout() {
        super.layout()
        if isOpen { reposition() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { closeMenu() } else if isOpen { reposition() }
    }

    // The probe is invisible chrome: it must never eat a click meant for the row
    // it is sitting behind.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
