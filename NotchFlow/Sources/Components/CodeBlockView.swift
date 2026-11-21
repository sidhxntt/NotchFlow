import SwiftUI
import AppKit
import Combine
import PDFKit
import ImageIO

/// A code island with its own ghost one-tap copy button. Split out of
/// `MarkdownBlocks.row(for:)` so it can hold the `hovering`/`copied` `@State` the
/// button needs. The button is a tap target overlaid on the island — independent of
/// scroll position and text-selection hit-testing — so it works identically while
/// the answer streams (once the closing fence parses this block into the tree) and
/// after it settles, where multi-line drag-select on the narrow panel is unreliable.
///
/// The button is *sticky*: it rides the top-right corner of the island's VISIBLE
/// part, not of its layout frame. A long block is usually taller than the thread's
/// viewport, so a corner-pinned button scrolls away with the block's first line and
/// the copy affordance disappears exactly when the block is big enough to need it.
/// See `stickyOffset(in:)`.
struct CodeBlockView: View {
    let text: String
    let baseFont: CGFloat
    let color: Color
    /// Fired after the in-app pasteboard write so the owner can re-baseline the
    /// clipboard and keep this copy from being re-injected into the next Ask.
    let onInAppCopy: (() -> Void)?

    @Environment(\.stickyScrollTopInset) private var stickyTopInset

    @State private var hovering = false
    @State private var copied = false

    /// The button's own box, and its inset off the island's corner — the SAME on
    /// both edges, so the glass circle reads as concentric inside the island's 8pt
    /// radius instead of hanging off-centre. It clears macOS's overlay scroller
    /// (which floats above the scroll content without taking layout space) because
    /// the thread stack is already inset 8pt from the viewport's right edge.
    private static let side: CGFloat = 26
    private static let inset: CGFloat = 8

    var body: some View {
        // NOTE: the parent `MarkdownBlocks` container in NotchBody wraps the whole
        // answer in `.textSelection(.disabled)` WHILE STREAMING (so tail-follow
        // scroll can't collapse a drag) and `.enabled` once settled — so the inner
        // `.textSelection(.enabled)` here is only effective post-stream. The copy
        // button below works in BOTH states; don't remove the parent wrapper without
        // auditing this.
        Text(text)
            .font(.system(size: baseFont - 1, weight: .regular, design: .monospaced))
            .foregroundStyle(color)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Tokens.hairline, lineWidth: 0.5)
            )
            .overlay(alignment: .topTrailing) {
                GeometryReader { geo in
                    copyButton
                        .padding(Self.inset)
                        .offset(y: stickyOffset(in: geo))
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: .topTrailing)
                }
            }
            .onHover { hovering = $0 }
    }

    private var copyButton: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            onInAppCopy?()
            Haptics.confirm()
            withAnimation(.easeOut(duration: 0.15)) { copied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                withAnimation(.easeOut(duration: 0.25)) { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.sf(12, weight: .regular))
                .foregroundStyle(hovering || copied ? Tokens.text1 : Tokens.text3)
                // Native SF Symbols swap — the doc morphs to the check
                // instead of hard-cutting.
                .contentTransition(.symbolEffect(.replace))
                .frame(width: Self.side, height: Self.side)
                // Sticky, this chip spends most of its life parked over dense code
                // rather than over the island's quiet first line — so it wears the
                // same Liquid Glass circle as every other icon chip that floats ON
                // the glass (`GlassIconButton`), not a flat wash that lets the code
                // read straight through it.
                .glassCapsule(in: Circle(), brighter: hovering)
                .contentShape(Circle())
        }
        .buttonStyle(GlassPressStyle())
        // Quiet at rest, full on hover and while showing the check.
        .opacity(copied ? 1.0 : hovering ? 1.0 : 0.6)
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
        .animation(.easeOut(duration: 0.15), value: copied)
    }

    /// How far down the island the button has to travel to stay in the reader's
    /// view. `bounds(of: .scrollView)` hands back the thread scroller's visible
    /// rect **in this island's own coordinates**, so a positive `minY` is exactly
    /// the slice of the block that has scrolled up past the viewport's top edge —
    /// push the button down by that much (plus the host's dissolve band, see
    /// `stickyScrollTopInset`) and it holds the visible top-right corner.
    ///
    /// Clamped at both ends: never above the island's own top (a block sitting
    /// fully in view keeps the plain corner placement), and never past its bottom,
    /// so the button leaves with the block instead of hanging off it. Returns 0
    /// wherever there is no scroller at all — the unclipped short-answer layout,
    /// the hidden height probes, the blur overlay copies.
    private func stickyOffset(in geo: GeometryProxy) -> CGFloat {
        guard let visible = geo.bounds(of: .scrollView) else { return 0 }
        let travel = max(geo.size.height - Self.side - Self.inset * 2, 0)
        return min(max(visible.minY + stickyTopInset, 0), travel)
    }
}
