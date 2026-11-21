import SwiftUI
import AppKit
import Combine
import PDFKit
import ImageIO

/// A small circular icon button rendered in the **Liquid Glass** language: a
/// real translucent glass capsule (native `.glassEffect` on macOS 26+, a blurred
/// `NSVisualEffectView` fallback below that) with the signature soft specular rim
/// and a gentle brighten-on-hover. Used for the in-panel settings entry so the
/// affordance reads as a piece of the same glass island, not a flat icon.
struct GlassIconButton: View {
    var systemName: String
    /// Optional destination cue for controls that open another surface. The
    /// glyph cross-fades quickly on hover instead of using a symbol morph.
    var hoverSystemName: String? = nil
    var help: String
    /// Which side the hover hint floats on — `.top` by default, since these chips
    /// sit at the panel's bottom edge where up is where the room is.
    var tipEdge: VerticalEdge = .top
    var size: CGFloat = 30
    /// Glyph point size inside the capsule. Defaults to the original 14pt; the
    /// compact header corners pass a smaller value so the glass reads as a quiet
    /// mark rather than a full button.
    var glyphSize: CGFloat = 14
    /// Whether the hover tooltip shows. Some of these chips are so familiar they
    /// shouldn't cover the panel with a hint; the accessibility label stays either
    /// way.
    var showsTooltip: Bool = true
    var action: () -> Void

    @State private var hovering = false

    @ViewBuilder
    private var glyph: some View {
        if let hoverSystemName {
            Image(systemName: hovering ? hoverSystemName : systemName)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.08), value: hovering)
        } else {
            Image(systemName: systemName)
                .contentTransition(.symbolEffect(.replace))
        }
    }

    var body: some View {
        Button(action: action) {
            glyph
                .font(.sf(glyphSize, weight: .regular))
                .foregroundStyle(hovering ? Tokens.text1 : Tokens.text3)
                .frame(width: size, height: size)
                .glassCapsule(in: Circle(), brighter: hovering)
                .contentShape(Circle())
        }
        .buttonStyle(GlassPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
        // `help` used to be accepted and silently dropped — this chip was the one
        // icon button in the app with NO hover hint at all, while its neighbours
        // carried the glass tip and the segment cluster carried AppKit's yellow
        // bubble. One tooltip species everywhere now.
        .notchTooltip(help, edge: tipEdge, shows: showsTooltip)
        .accessibilityLabel(help)
    }
}

/// The one state transition every pin affordance uses: a loose, tilted outline
/// settles into a filled upright tack. Keeping the symbol replacement, angle and
/// timing together prevents the panel and detached-window variants from drifting.
struct PinStateGlyph: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var pinned: Bool
    var size: CGFloat
    var weight: Font.Weight
    /// Lets a persistent chrome slot morph from its non-pin role into this pin
    /// without replacing the view (the compact composer's sliders are that case).
    var alternateSystemName: String? = nil
    var alternateSize: CGFloat? = nil

    var body: some View {
        let systemName = alternateSystemName ?? (pinned ? "pin.fill" : "pin")
        Image(systemName: systemName)
            .font(.sf(alternateSize ?? size, weight: weight))
            .rotationEffect(.degrees(alternateSystemName == nil && !pinned ? 32 : 0))
            .contentTransition(.symbolEffect(.replace))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: systemName)
    }
}

/// A row of glyphs riding one Liquid Glass capsule — the panel/detached-window
/// trailing-cluster species, extracted so every caller shares one implementation.
/// The capsule is a quiet whisper of glass at rest and comes to full rim+specular
/// strength whenever the pointer is on any segment (or a segment is `engaged`,
/// e.g. a live pin); each segment carries a soft round highlight under its glyph.
/// `ResultTrailingCluster`, `WindowTrailingCluster`, and the agent detail header
/// all build on this — don't hand-roll another two-icon glass pill.
struct GlassSegmentCluster: View {
    struct Segment {
        /// Stable semantic identity for clusters whose leading/trailing segments
        /// can appear or disappear. When omitted, the original index identity is
        /// preserved for fixed clusters.
        var id: String?
        var engaged: Bool
        var tooltip: String
        var action: () -> Void
        var glyph: (Bool) -> AnyView

        init<Glyph: View>(id: String? = nil, engaged: Bool = false, tooltip: String,
                          action: @escaping () -> Void,
                          @ViewBuilder glyph: @escaping () -> Glyph) {
            self.id = id
            self.engaged = engaged
            self.tooltip = tooltip
            self.action = action
            self.glyph = { _ in AnyView(glyph()) }
        }

        init<Glyph: View>(id: String? = nil, engaged: Bool = false, tooltip: String,
                          action: @escaping () -> Void,
                          @ViewBuilder hoverAwareGlyph: @escaping (Bool) -> Glyph) {
            self.id = id
            self.engaged = engaged
            self.tooltip = tooltip
            self.action = action
            self.glyph = { hovering in AnyView(hoverAwareGlyph(hovering)) }
        }
    }

    private enum SegmentIdentity: Hashable {
        case semantic(String)
        case index(Int)
    }

    private struct IdentifiedSegment: Identifiable {
        let id: SegmentIdentity
        let segment: Segment
    }

    var segments: [Segment]
    /// Square tap target per segment (also the pill's height).
    var chip: CGFloat = 26
    /// Which side the hover hints float on. Every caller parks this cluster in a
    /// header at the top of its panel/window, so the tip drops DOWN by default —
    /// floating it up would run it off the top edge.
    var tipEdge: VerticalEdge = .bottom
    /// Some compact surfaces already make every action self-evident and do not
    /// want hover cards covering their content. Accessibility labels remain.
    var showsTooltips = true
    /// Drop the glass pill and render the glyphs bare. For the panel's result
    /// header, where these chips are hover-only chrome: a slab of glass appearing
    /// and vanishing with the pointer reads as the panel twitching, while bare
    /// marks just arrive. Without the pill the glyphs carry their own resting
    /// dimming (the glass used to do it) and stand further apart, since nothing
    /// binds them into one control any more.
    var glass: Bool = true
    /// The capsule floats over a foreign window, not over one of our dark slabs
    /// (the prompt-shortcut band). Smokes the glass so the white glyphs keep
    /// their contrast over a light backdrop, and drops the resting dimming —
    /// 55% of a dark pill over a white page is a pale smudge, not quiet chrome.
    var smoked: Bool = false

    // Fixed clusters keep their index identity. A cluster with conditional
    // segments can supply semantic ids so removing a neighbour does not make
    // SwiftUI replace every glyph after it — and the hover follows the actual
    // button while it slides into its new slot.
    @State private var hoveredSegmentID: SegmentIdentity? = nil
    /// Is the pointer anywhere on the CLUSTER — which is not the same question as
    /// "is it on a segment". Crossing from one mark to the other passes through
    /// the pill's own padding and the gap between them, and there the per-segment
    /// hovers read `nil` for a beat: the pill was fading out and back in every
    /// time the pointer moved between its two halves. The capsule belongs to the
    /// whole control, so it takes the whole control's hover.
    @State private var clusterHovered = false

    /// With one glassed segment the pill *is* the segment: its own brightening
    /// already answers "the pointer is here", so the per-segment round highlight
    /// would only draw a second circle inside the capsule — two nested pieces of
    /// glass for one control (the detached window's close ×). The highlight earns
    /// its keep only when there are siblings to tell apart.
    private var segmentHighlight: Bool { !glass || segments.count > 1 }

    private var identifiedSegments: [IdentifiedSegment] {
        segments.enumerated().map { index, segment in
            IdentifiedSegment(
                id: segment.id.map(SegmentIdentity.semantic) ?? .index(index),
                segment: segment
            )
        }
    }

    var body: some View {
        HStack(spacing: glass ? 2 : 6) {
            ForEach(identifiedSegments) { item in
                let seg = item.segment
                if showsTooltips {
                    segmentButton(id: item.id, segment: seg)
                        .notchTooltip(seg.tooltip, edge: tipEdge)
                        .accessibilityLabel(seg.tooltip)
                } else {
                    segmentButton(id: item.id, segment: seg)
                        .accessibilityLabel(seg.tooltip)
                }
            }
        }
        .padding(glass ? 3 : 0)
        // The whole cluster is the chip: glass carries ALL the resting dimming
        // (rendered behind the glyphs, so they stay pure white even at rest) and
        // lights fully when hovered or while a segment is engaged.
        .background {
            if glass {
                let lit = clusterHovered || segments.contains { $0.engaged }
                // At rest the pill is barely there: no rim, no contact shadow,
                // and the glass itself down to a whisper — a drawn outline
                // standing around two marks that are doing nothing reads as a
                // second frame inside the card's own rim, and even the material's
                // own specular edge is that outline at any real opacity. The
                // hover is what makes it a control: the whole capsule comes back
                // — glass, rim and all — under the pointer (see `rim:`).
                Color.clear
                    .glassCapsule(in: Capsule(), brighter: lit, smoked: smoked,
                                  rim: lit ? 1 : 0)
                    .opacity(smoked ? 1 : (lit ? 1 : 0.15))
            }
        }
        .onHover { inside in
            clusterHovered = inside
            // Leaving fast can outrun a segment's own exit — drop the highlight
            // with the cluster rather than leaving one mark lit behind us.
            if !inside { hoveredSegmentID = nil }
        }
        .animation(.easeOut(duration: 0.18), value: hoveredSegmentID)
        .animation(.easeOut(duration: 0.18), value: clusterHovered)
        .animation(.easeOut(duration: 0.18), value: segments.map(\.engaged))
    }

    private func segmentButton(id: SegmentIdentity, segment seg: Segment) -> some View {
        let hovering = hoveredSegmentID == id
        return Button(action: seg.action) {
            seg.glyph(hovering)
                // Glassed: pure white, the pill behind carries the resting
                // dimming. Bare: the glyph does it itself, and rests QUIET —
                // the answer-footer icons' level (text3), not a second row of
                // bright chrome competing with the text. Direct hover (or a
                // live pin) brings it up to full ink.
                .foregroundStyle(glass ? Tokens.ink
                                      : (hovering || seg.engaged ? Tokens.text1
                                                                 : Tokens.text3))
                .frame(width: chip, height: chip)
                .background {
                    if glass {
                        Circle().fill(.white.opacity(
                            segmentHighlight
                                ? (seg.engaged ? 0.20 : (hovering ? 0.12 : 0))
                                : 0))
                    } else {
                        // Bare cluster: there is no pill to brighten, so the glass
                        // arrives per glyph — one round chip that lights under the
                        // pointer and fades back to nothing, instead of a slab
                        // sitting behind both marks at rest.
                        // Quiet: the resting glass strength, at less than full
                        // opacity. Under a single glyph, a fully lit chip reads
                        // as a button that appeared — this should read as the
                        // pointer catching a little light. An engaged segment (a
                        // live pin) is the exception: it means "on", so it takes
                        // the full brightened chip.
                        Color.clear
                            .glassCapsule(in: Circle(), brighter: seg.engaged)
                            .opacity(seg.engaged ? 1 : (hovering ? 0.65 : 0))
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(GlassPressStyle())
        .onHover { inside in
            if inside { hoveredSegmentID = id }
            else if hoveredSegmentID == id { hoveredSegmentID = nil }
        }
    }
}

/// A small **text** pill in the same Liquid Glass language as `GlassIconButton`
/// — a translucent glass capsule that brightens on hover. Used for word actions
/// like "Clear" so they read as part of the glass island, not flat link text.
struct GlassTextButton: View {
    var title: String
    /// Text size; the capsule's padding scales with it so the pill stays
    /// proportional. Defaults to the original 11pt.
    var fontSize: CGFloat = 11
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.sf(fontSize, weight: .medium))
                .foregroundStyle(hovering ? Tokens.text2 : Tokens.text4)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .glassCapsule(in: Capsule(), brighter: hovering)
                .contentShape(Capsule())
        }
        .buttonStyle(GlassPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
    }
}

/// The panel header's back control as **one whole piece of Liquid Glass** —
/// chevron and panel title live inside a single glass capsule instead of a bare
/// glyph sitting next to a loose caption. The header then reads as one physical
/// affordance you press, in the same material as every other chip on the island,
/// rather than two unrelated marks that happen to share a row.
struct PanelBackPill: View {
    var title: String
    var help: String
    var action: () -> Void

    @State private var hovering = false

    init(title: String, help: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.help = help ?? title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left")
                    .font(.sf(10.5, weight: .semibold))
                Text(title)
                    .font(.sf(11, weight: .semibold))
                    .tracking(0.4)
                    .lineLimit(1)
            }
            .foregroundStyle(hovering ? Tokens.text1 : Tokens.text3)
            .padding(.leading, 8)
            .padding(.trailing, 11)
            .frame(height: 26)
            .glassCapsule(in: Capsule(), brighter: hovering)
            .contentShape(Capsule())
        }
        .buttonStyle(GlassPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
        .accessibilityLabel(help)
    }
}

/// The panel header's back chevron — the one control that walks a full-panel
/// module (Settings, What's New, the first-run guide) back where it came from.
/// A quiet 26pt glyph over the same soft capsule wash every other row-level
/// affordance uses, so the three headers open and close with one gesture in one
/// voice. Three copies of this used to drift apart: two byte-identical, and the
/// onboarding's a 30pt `.plain` button at a lighter weight and a dimmer ink that
/// gave no hover feedback at all.
///
/// Not to be confused with the result header's `GlassBackButton` — that one is a
/// real glass circle because it sits *on* the glass, opposite the glass trailing
/// cluster; this one sits inside a panel's own chrome.
struct PanelBackButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.sf(13, weight: .semibold))
                .foregroundStyle(Tokens.text2)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(RecentEntryStyle())
    }
}

/// Scales the glass capsule down a touch on press for a tactile, physical feel —
/// the glass "gives" under the cursor like the rest of the island. Internal so
/// other glass chips (e.g. the manage menu's filter capsules) share the feel.
struct GlassPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// The trailing "open in Notes/Reminders" pill on a capture row — one control
/// shared by the notch's Recent list and the standalone archive window, so the
/// jump looks and feels identical wherever the row is read. A quiet tinted glass
/// capsule at rest that brightens under the cursor, the same hover language the
/// rows themselves speak, and gives on press like every other glass chip.
struct CaptureJumpButton: View {
    let title: String
    let tint: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title)
                    .font(.sf(11, weight: .medium))
                Image(systemName: "arrow.up.right")
                    .font(.sf(8, weight: .semibold))
            }
            .foregroundStyle(hovering ? Tokens.text2 : Tokens.text3)
            .padding(.vertical, 3)
            .padding(.horizontal, 8)
            .glassCapsule(in: Capsule(), brighter: hovering, tint: tint)
            .contentShape(Capsule())
        }
        .buttonStyle(GlassPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
    }
}
