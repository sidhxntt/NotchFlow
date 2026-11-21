import SwiftUI
import AppKit
import Combine
import PDFKit
import ImageIO

/// One ghost icon in a settled answer's footer toolbar — copy, regenerate, and
/// continue-elsewhere all share this recipe. The copy affordance exists because
/// SwiftUI selection can't cross the per-block `Text` views the answer renders
/// through — a drag stops at every block edge, so multi-line copy needs one tap.
///
/// Island-hover in three levels: nearly invisible at rest, the whole row
/// surfaces together when the cursor enters the owning turn (`rowHovered`), and
/// the pointed-at button alone goes full — so the toolbar reads as one unit on
/// approach, not scattered dots that light up one by one. `confirms` flips the
/// icon to a checkmark for a beat after the tap, for copy-style actions whose
/// effect is otherwise invisible; regenerate skips it (the answer visibly
/// re-streaming IS the feedback).
struct AnswerFooterButton: View {
    let icon: String
    let help: String
    /// True while the cursor is anywhere over the owning turn — brightens the
    /// whole footer as one unit (owned by `AssistantTurnView`).
    let rowHovered: Bool
    var showsTooltip: Bool = true
    var confirms: Bool = false
    let action: () -> Void

    @State private var hovering = false
    @State private var confirmed = false

    var body: some View {
        Button {
            action()
            guard confirms else { return }
            Haptics.confirm()
            withAnimation(.easeOut(duration: 0.15)) { confirmed = true }
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                withAnimation(.easeOut(duration: 0.25)) { confirmed = false }
            }
        } label: {
            Image(systemName: confirmed ? "checkmark" : icon)
                .font(.sf(11, weight: .regular))
                .foregroundStyle(confirmed ? Tokens.text2 : Tokens.text3)
                // Native SF Symbols swap — icon morphs to the check, no hard cut.
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Rest → row hover → direct hover/checkmark: 0.25 → 0.7 → 1.
        .opacity(confirmed || hovering ? 1.0 : rowHovered ? 0.7 : 0.25)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
        .animation(.easeOut(duration: 0.18), value: rowHovered)
        .animation(.easeOut(duration: 0.15), value: confirmed)
        .notchTooltip(help, shows: showsTooltip)
    }
}

/// The floating source popup's request, published up the view tree by the hovered
/// badge: where it is (`anchor`, the pill's frame) and what to show (`sources`).
/// `nil` when no badge is hovered. An ancestor *outside* the conversation
/// ScrollView reads this and draws the panel, so the popup escapes the scroll's
/// clip that was chopping it off (XII-118).
struct SourcePopoverRequest: Equatable {
    let id: UUID
    let anchor: Anchor<CGRect>
    let sources: [WebSource]
    static func == (a: SourcePopoverRequest, b: SourcePopoverRequest) -> Bool { a.id == b.id }
}

struct SourcePopoverKey: PreferenceKey {
    static let defaultValue: SourcePopoverRequest? = nil
    static func reduce(value: inout SourcePopoverRequest?, nextValue: () -> SourcePopoverRequest?) {
        // Last writer wins — at most one badge is hovered at a time.
        if let next = nextValue() { value = next }
    }
}

/// A source badge shown under a search-grounded answer (XII-118). Rests as a
/// compact pill — just the first source's site name plus "+N" for the rest, e.g.
/// "tmtpost + 3", no icons. **Hover** the pill and a floating panel pops up over
/// the content listing every source as "site · title (date)"; click a row to open
/// the original page. The panel is rendered by an ancestor (see
/// `conversationOverlay`) so it floats above the answer and is never clipped by
/// the scroll view.
///
/// `hoveredID` is the shared "which badge is open" state owned by `NotchBody`: the
/// badge sets it to its own `id` on hover and clears it on exit; the floating
/// panel keeps it set while the cursor is over the panel, so moving up onto a row
/// doesn't dismiss it. The pill only *publishes its anchor* when it's the open one.
struct SourceBadge: View {
    let sources: [WebSource]
    @Binding var hoveredID: UUID?
    /// Shared deferred-close handle (owned by `NotchBody`): when the cursor leaves
    /// the pill we don't close immediately — we schedule a close ~140ms out, and
    /// the floating panel cancels it the moment the cursor lands on it. Without
    /// this, the 6pt gap between pill and panel is a dead zone that snaps the popup
    /// shut before the cursor can cross it.
    @Binding var pendingClose: DispatchWorkItem?

    /// Identity for "this badge is the open one". MUST be `@State`, not a plain
    /// `let`: the parent turn re-runs its body whenever its own `turnHovered`
    /// flips — which happens the instant the cursor moves onto the floating
    /// panel, because the panel (an overlay above the ScrollView) steals the
    /// hit test from the turn underneath. A plain `let UUID()` would be
    /// regenerated by that re-init, so `hoveredID` (holding the old UUID) no
    /// longer matches, `isOpen` flips false, the anchor unpublishes, and the
    /// panel tears itself down one frame after the cursor reaches it. `@State`
    /// storage survives struct re-inits, keeping the badge's identity stable
    /// for as long as it exists in the hierarchy.
    @State private var id = UUID()
    private var isOpen: Bool { hoveredID == id }

    var body: some View {
        Text(pillLabel)
            .font(.sf(11, weight: .medium))
            .tracking(0.1)
            .foregroundStyle(Tokens.text3)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(Color.white.opacity(isOpen ? 0.10 : 0.06))
            )
            .overlay(Capsule().stroke(Tokens.hairline, lineWidth: 0.5))
            .contentShape(Capsule())
            // Publish this pill's frame + sources up to the ancestor overlay, but
            // only while it's the open one — so the ancestor knows where to float
            // the panel. A hidden tracking value when closed keeps the key present.
            .anchorPreference(key: SourcePopoverKey.self, value: .bounds) { anchor in
                isOpen ? SourcePopoverRequest(id: id, anchor: anchor, sources: sources) : nil
            }
            .onHover { hovering in
                if hovering {
                    pendingClose?.cancel()      // re-entered the pill — cancel any close
                    pendingClose = nil
                    hoveredID = id
                } else if isOpen {
                    scheduleClose()             // grace period to reach the panel
                }
            }
    }

    /// Close after a short grace period, unless something (the panel's hover, or
    /// re-entering the pill) cancels it first.
    private func scheduleClose() {
        pendingClose?.cancel()
        let work = DispatchWorkItem {
            if hoveredID == id { hoveredID = nil }
        }
        pendingClose = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
    }

    /// "tmtpost + 3" — the first source's short site name, plus a count of the
    /// rest. A single source just shows its site, no "+".
    private var pillLabel: String {
        let lead = sources.first?.site ?? L("source.badge.fallback")
        let extra = sources.count - 1
        return extra > 0 ? "\(lead) + \(extra)" : lead
    }
}

extension View {
    /// Float the hovered source badge's popup above this view. Attach it to an
    /// ancestor OUTSIDE the conversation ScrollView: the hovered badge publishes
    /// its frame through `SourcePopoverKey`, we resolve it in this view's
    /// coordinate space and place the panel just ABOVE the badge, clamped to the
    /// left edge so a badge near the right doesn't push it off-screen. Rendered
    /// here, the popup escapes the scroll's clip that was chopping its top off
    /// (XII-118).
    ///
    /// EVERY surface that shows a `SourceBadge` must carry this — the badge alone
    /// only publishes an anchor, so a window without the overlay renders the pill
    /// and then nothing happens on hover. The panel and the detached thread
    /// window both go through this one implementation so neither can drift.
    ///
    /// `hoveredID` / `closeWork` are the host's shared "which badge is open" and
    /// deferred-close state, the same pair the badges are handed.
    func sourcePopoverOverlay(hoveredID: Binding<UUID?>,
                              closeWork: Binding<DispatchWorkItem?>) -> some View {
        overlayPreferenceValue(SourcePopoverKey.self) { request in
            GeometryReader { geo in
                if let request {
                    let rect = geo[request.anchor]
                    SourcePopoverPanel(
                        sources: request.sources,
                        keepOpen: {
                            // Cursor reached the panel — cancel the pending close
                            // and keep this badge open.
                            closeWork.wrappedValue?.cancel()
                            closeWork.wrappedValue = nil
                            hoveredID.wrappedValue = request.id
                        },
                        dismiss: {
                            // Left the panel — close after the same grace period so
                            // a slip back toward the pill doesn't flicker it shut.
                            closeWork.wrappedValue?.cancel()
                            let work = DispatchWorkItem {
                                if hoveredID.wrappedValue == request.id {
                                    hoveredID.wrappedValue = nil
                                }
                            }
                            closeWork.wrappedValue = work
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14,
                                                          execute: work)
                        }
                    )
                    // Horizontal fixed (the panel sets its own width); leave
                    // vertical flexible so the panel's own maxHeight cap applies and
                    // overflowing rows scroll instead of growing the card.
                    .fixedSize(horizontal: true, vertical: false)
                    // Anchor the panel's BOTTOM-leading right at the badge's top,
                    // so it pops up over the answer. No visual gap is subtracted
                    // here: the panel carries its own transparent `bridgeGap` strip
                    // at its bottom, which spans the gap as a continuous hover
                    // region so the pill → panel crossing never falls into a dead
                    // zone.
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    // Held inside the host on BOTH sides: at the badge's own left
                    // edge normally, pulled back when the card would otherwise
                    // hang out past the right rim (the compact window is barely
                    // wider than the card).
                    .offset(x: min(max(0, rect.minX),
                                   max(0, geo.size.width - SourcePopoverPanel.width)),
                            y: rect.minY - geo.size.height)
                    .transition(.opacity)
                }
            }
            .allowsHitTesting(request != nil)
            .animation(.easeInOut(duration: 0.16), value: request)
        }
    }
}

/// The floating source list — a self-contained card backed by the **same Liquid
/// Glass** the island uses (`nativeGlass`: genuine `.glassEffect(.clear)` on
/// macOS 26+, blurred fallback below) so the wallpaper refracts through it and the
/// panel reads as a piece of the same glass surface floated out, not a flat opaque
/// block. A soft dark veil under the glass keeps the source rows legible over any
/// wallpaper, and a specular hairline rim + soft shadow seat it as a layer above
/// the answer. Rendered by an ancestor overlay (escaping the scroll clip) and
/// positioned over the badge by the caller. `keepOpen`/`dismiss` let it hold the
/// badge open while the cursor is over its rows.
struct SourcePopoverPanel: View {
    let sources: [WebSource]
    let keepOpen: () -> Void
    let dismiss: () -> Void

    // Show at most this many rows; the rest scroll. ~18pt per row (11pt line +
    // 2pt padding top/bottom) plus the 7pt inter-row gap.
    private static let visibleRows = 4
    private static let rowHeight: CGFloat = 18
    private static let rowSpacing: CGFloat = 7
    // Runways the edge fades taper across when the list scrolls. They live INSIDE
    // the scroll viewport (as content padding), so they double as the card's
    // vertical padding — see `cardPadding` below.
    private static let topRunway: CGFloat = 14
    private static let bottomRunway: CGFloat = 24
    private static let cardPadding: CGFloat = 14

    /// Transparent hover bridge below the card, spanning the gap down to the
    /// badge's top edge. Without it the cursor crosses a dead strip on its way
    /// from pill → panel, and both `.onHover`s read "not hovering" during the
    /// crossing — which fires the pill's deferred close before the panel can
    /// cancel it, snapping the popup shut mid-reach. The bridge is part of the
    /// panel's hover region, so hover stays continuous the whole way across.
    /// Must match the gap the caller leaves in `NotchBody` (`bridgeGap`).
    static let bridgeGap: CGFloat = 6

    /// The card's fixed width. Public because the host overlay clamps the panel
    /// inside its own bounds with it — a compact pointer-side window is only a
    /// little wider than this card, so a badge at the reading inset would push
    /// its right edge out through the window without the clamp.
    static let width: CGFloat = 350

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let scrolls = sources.count > Self.visibleRows
        // Cap the visible height at `visibleRows` rows; shorter lists size down to
        // their own content (no empty space, no scroll). Computing the height
        // explicitly — rather than letting `.fixedSize` measure it — lets the
        // ScrollView scroll the overflow once there are more rows than fit.
        //
        // The runways count toward that height. They're content padding, so they
        // occupy the viewport: leaving them out capped the viewport at bare row
        // math and the runways then ate it from both ends — the 4th row fell out
        // of view and the card read as two blank bands squeezing three rows.
        let topRunway = scrolls ? Self.topRunway : 0
        let bottomRunway = scrolls ? Self.bottomRunway : 0
        let shownRows = CGFloat(min(sources.count, Self.visibleRows))
        let rowsHeight = max(0, shownRows * Self.rowHeight + (shownRows - 1) * Self.rowSpacing)
        let visibleHeight = rowsHeight + topRunway + bottomRunway
        ScrollView(.vertical, showsIndicators: scrolls) {
            VStack(alignment: .leading, spacing: Self.rowSpacing) {
                ForEach(sources) { source in
                    SourceRow(source: source)
                }
            }
            // Breathing room each fade falls across, so the first / last row rests
            // outside its taper at full strength at either end of the scroll.
            .padding(.top, topRunway)
            .padding(.bottom, bottomRunway)
        }
        .scrollBounceBehavior(.basedOnSize)
        // The shared dissolve at both overflow edges (`scrollEdgeFade`) instead of a
        // hard cut — only when the list actually scrolls; a short list that fits
        // stays crisp. A thin feather up top, where only a row on its way out needs
        // swallowing.
        .scrollEdgeFade(top: scrolls, bottom: scrolls,
                        topFade: Self.topRunway, bottomFade: Self.bottomRunway)
        .frame(height: visibleHeight)
        .padding(.horizontal, 16)
        // A scrolling list already carries its own vertical inset (the runways) —
        // stacking the card's padding on top of it doubled the gap above the first
        // row. Only a short, runway-less list needs the card padding here.
        .padding(.vertical, scrolls ? 0 : Self.cardPadding)
        // A fixed width gives the rows a definite bound to truncate long titles
        // against (instead of stretching the popup to the longest line).
        .frame(width: Self.width, alignment: .leading)
        .background {
            // Real Liquid Glass: the high-transparency `.clear` material refracts
            // the wallpaper through the whole card; a soft dark veil over it keeps
            // the rows readable against bright backgrounds (the same recipe the
            // quick-tools popover uses — glass over a legibility veil).
            shape.fill(.clear).nativeGlass(in: shape)
                .overlay(shape.fill(Color.black.opacity(0.55)))
        }
        .overlay(
            // Specular hairline rim — a top-bright → bottom-faint edge, the
            // signature glass bevel, instead of a flat uniform outline.
            shape.strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(0.22), .white.opacity(0.06)],
                    startPoint: .top, endPoint: .bottom
                ),
                lineWidth: 0.75
            )
        )
        .clipShape(shape)
        .shadow(color: .black.opacity(0.5), radius: 18, y: 6)
        // Extend the hover region downward by `bridgeGap` with a transparent
        // strip so the pill → panel crossing is never un-hovered (see comment
        // on `bridgeGap`). The card keeps its visual position; only the
        // hit-testable area grows down to meet the badge.
        .padding(.bottom, Self.bridgeGap)
        .background(Color.clear.contentShape(Rectangle()))
        // Hovering the panel (card + bridge) keeps the badge open; leaving it
        // dismisses — so the round-trip pill → row works, and moving away closes.
        .onHover { $0 ? keepOpen() : dismiss() }
    }
}

/// One expanded source row: "site · title", with the date trailing if known.
/// Clicking opens the URL. Hover lifts it slightly so it reads as actionable.
private struct SourceRow: View {
    let source: WebSource
    @State private var hovering = false

    var body: some View {
        Button {
            if let url = URL(string: source.url) { NSWorkspace.shared.open(url) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(source.site)
                    .font(.sf(11, weight: .semibold))
                    .foregroundStyle(Tokens.text3)
                    .lineLimit(1)
                    .fixedSize()
                Text(source.title)
                    .font(.sf(11))
                    .foregroundStyle(hovering ? Tokens.text2 : Tokens.text4)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let date = source.date, let day = Self.dayOnly(date) {
                    Text(day)
                        .font(.sf(10))
                        .foregroundStyle(Tokens.text4)
                        .fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    /// Show just the calendar day, not a full timestamp. Providers report dates
    /// inconsistently — some send a clean "2026-06-23", others a full ISO instant
    /// like "2026-06-20T10:26:35.000Z". Take the leading "YYYY-MM-DD" when the
    /// string is ISO-shaped; otherwise pass it through unchanged (a non-ISO label
    /// like "Jun 2026" stays as-is). Returns nil for empty input so the row hides
    /// the date entirely.
    static func dayOnly(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        // ISO-shaped: the date is the part before any "T" (or space) separator.
        let datePart = s.prefix { $0 != "T" && $0 != " " }
        // Only trust the truncation when it really is a YYYY-MM-DD prefix; for any
        // other shape, show the original string untouched.
        let isISODay = datePart.count == 10
            && datePart.allSatisfy { $0.isNumber || $0 == "-" }
        return isISODay ? String(datePart) : s
    }
}
