import SwiftUI
import AppKit

/// Presents a popover only once its anchor is standing still — and re-pins it
/// if the anchor moves underneath.
///
/// `.popover` on macOS is an NSPopover: it computes its screen position ONCE,
/// from the anchor's frame at presentation time, and never re-tracks SwiftUI
/// layout (the island animates entirely inside one hosting NSView, so AppKit
/// sees nothing move). Fire a picker mid-spring — ⌘⇧I pressed right on the
/// open edge, or a flag left armed while the body was unmounted — and the
/// card lands wherever the island happened to be that frame, its tail
/// visibly torn off the glass. The fix is temporal, not spatial: hold the
/// actual presentation until the anchor's global frame has been quiet for a
/// beat, and if the anchor slides under an open popover (the island
/// re-laying out, a chip growing on pick), drop and re-present so the tail
/// is glued again.
struct SettledPopover<PopContent: View>: ViewModifier {
    /// The caller's intent flag (usually a model @Published). `shown` is what
    /// the real `.popover` sees — it trails this by however long the anchor
    /// needs to stop moving, and reflects click-away dismissals back into it.
    @Binding var isPresented: Bool
    var arrowEdge: Edge
    @ViewBuilder var popoverContent: () -> PopContent

    @State private var shown = false
    /// True while `shown` is being cycled false→true to re-pin after an
    /// anchor move — tells the dismiss-sync below the drop wasn't the user's.
    @State private var regluing = false
    /// When the anchor's global frame last changed. `.distantPast` means "no
    /// move ever seen" — a settled anchor presents with zero added latency.
    @State private var lastMove = Date.distantPast

    /// How long the anchor must hold still to count as settled. The open
    /// spring (response 0.42) stops emitting layout deltas well inside this
    /// once its tail goes sub-pixel.
    private static var quiet: TimeInterval { 0.15 }

    init(isPresented: Binding<Bool>,
         arrowEdge: Edge = .bottom,
         @ViewBuilder popoverContent: @escaping () -> PopContent) {
        _isPresented = isPresented
        self.arrowEdge = arrowEdge
        self.popoverContent = popoverContent
    }

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { g in
                let frame = g.frame(in: .global)
                Color.clear
                    .onChange(of: frame) { old, new in
                        lastMove = Date()
                        // Anchor slid under an open popover — NSPopover won't
                        // follow, so re-pin once it settles. Sub-pixel layout
                        // jitter doesn't count; a real move does.
                        guard shown, !regluing,
                              abs(new.midX - old.midX) + abs(new.maxY - old.maxY) > 2
                        else { return }
                        regluing = true
                        shown = false
                        afterSettle {
                            shown = isPresented
                            regluing = false
                        }
                    }
            })
            .popover(isPresented: $shown, arrowEdge: arrowEdge) { popoverContent() }
            .onChange(of: isPresented) { _, wants in
                if wants {
                    afterSettle { if isPresented { shown = true } }
                } else {
                    shown = false
                }
            }
            // Click-away/Esc dismisses the NSPopover directly — reflect that
            // back into the intent flag so the model knows the card is gone.
            .onChange(of: shown) { _, s in
                if !s, !regluing, isPresented { isPresented = false }
            }
            // The intent flag can be armed while this view is unmounted (⌘⇧I
            // with the island closed leaves it set): present once the mount's
            // open spring lands. Seeding `lastMove` here is what makes the
            // gate wait — the spring's first frames haven't emitted a change
            // yet, and presenting on the mount frame is exactly the bug.
            .onAppear {
                guard isPresented else { return }
                lastMove = Date()
                afterSettle { if isPresented { shown = true } }
            }
    }

    /// Run `action` once the anchor has been still for `quiet`, checking on
    /// short hops (a spring's tail emits no "done" signal to observe). Gives
    /// up after ~1.2s and runs anyway — a continuously-reflowing body (a
    /// streaming answer) must not eat the popover entirely.
    private func afterSettle(_ action: @escaping () -> Void) {
        afterSettle(deadline: Date().addingTimeInterval(1.2), action)
    }

    private func afterSettle(deadline: Date, _ action: @escaping () -> Void) {
        let since = Date().timeIntervalSince(lastMove)
        if since >= Self.quiet || Date() >= deadline {
            action()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + (Self.quiet - since) + 0.02) {
                afterSettle(deadline: deadline, action)
            }
        }
    }
}
