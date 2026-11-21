import SwiftUI
import AppKit
import Combine
import PDFKit
import ImageIO

/// A one-shot **rim glow** that pulses whenever a watched value changes — the input
/// field's outer acknowledgement that its *destination* just flipped (Ask → Note →
/// Remind). The destination pill below already cross-fades its word; this brightens
/// the field's own border for a beat so the change registers in peripheral vision
/// too, not only where the eye is reading.
///
/// Mechanics: brighten instantly (no animation) on the change, then ease back to rest —
/// a struck-then-settles curve, the same shape the entry kick uses, so the field reads
/// as having been *tapped* by the switch rather than slowly glowing. Keyed on an
/// `Equatable` trigger so it fires once per real transition; passing the intent
/// *category* (not the full label) keeps a "Remind · Daily" → "Remind · Weekly" suffix
/// edit from pulsing, since the destination itself didn't move.
private struct IntentChangePulse<Trigger: Equatable, S: InsettableShape>: ViewModifier {
    var trigger: Trigger
    var shape: S
    /// The colour of the flash — the NEW destination's tint (read live from the
    /// call site, so the rim strikes in the colour the field just switched TO).
    /// Defaults to the original white for callers without a destination colour.
    var tint: Color = .white
    @State private var glow: Double = 0

    func body(content: Content) -> some View {
        content
            .overlay(
                shape
                    .strokeBorder(tint.opacity(0.55 * glow), lineWidth: 1)
                    .blur(radius: 1.5)
                    .allowsHitTesting(false)
            )
            .onChange(of: trigger) { _, _ in
                // Strike: jump to full on its own (instant) transaction so the brighten
                // is a hit, not a ramp; then release back to rest on a soft ease.
                var instant = Transaction(); instant.disablesAnimations = true
                withTransaction(instant) { glow = 1 }
                withAnimation(.easeOut(duration: 0.45)) { glow = 0 }
            }
    }
}

extension View {
    /// Pulse a soft rim glow on `shape` each time `trigger` changes — see
    /// `IntentChangePulse`. Used on the prompt field to flash its border when the
    /// Ask/Note/Remind destination flips; `tint` colours the flash with the new
    /// destination's hue (defaults to the original white).
    func intentChangePulse<T: Equatable, S: InsettableShape>(
        on trigger: T, shape: S, tint: Color = .white
    ) -> some View {
        modifier(IntentChangePulse(trigger: trigger, shape: shape, tint: tint))
    }
}

extension View {
    /// Wrap the content in a Liquid Glass chip of the given shape — genuine system
    /// glass on macOS 26+, a dark blur fallback below — topped with the same
    /// whisper-thin specular rim the island uses, so it sits in the same material
    /// family. Works for both circular icon chips and capsule text pills.
    ///
    /// `smoked` is for a capsule that floats free over ANOTHER app's window
    /// rather than over one of our own dark slabs: clear glass takes its
    /// character from whatever is behind it, so over a white page it comes back
    /// white and the white glyphs on it vanish. Smoked bakes the island's glass
    /// tint into the material and lays the same black veil the free-floating
    /// composer chrome wears (`CompactComposerGlass`, `DetachedWindowGlass`), so
    /// the pill reads as the island's glass on any backdrop, light or dark.
    @ViewBuilder
    /// `rim` scales the specular border. A chip that only means something once
    /// the pointer is on it (`GlassSegmentCluster`) rests at 0: the glass is
    /// still there, but nothing draws its outline until the hover lights it.
    func glassCapsule<S: InsettableShape>(in shape: S, brighter: Bool, tint: Color? = nil,
                                          smoked: Bool = false,
                                          rim: Double = 1) -> some View {
        self
            .background {
                if #available(macOS 26.0, *) {
                    shape.fill(.clear)
                        .glassEffect(smoked
                            ? .clear.tint(.black.opacity(GlassMaterial.bakedTint)).interactive()
                            : .clear.interactive(), in: shape)
                } else {
                    LegacyGlassBackdrop().clipShape(shape)
                }
            }
            .overlay {
                if smoked {
                    shape.fill(Color.black.opacity(0.30)).allowsHitTesting(false)
                }
            }
            // Both overlays are purely decorative (tint + specular rim). They sit ON
            // TOP of the content, and a filled/stroked Shape is hit-testable by
            // default — which would swallow taps meant for any control *nested* inside
            // a capsule (e.g. a remove × or inline button). Mark them non-interactive
            // so clicks pass through to the content below.
            //
            // `tint`, when set, washes the fill in a colour instead of plain white — a
            // whisper of hue so a chip can read as a slightly different colour from its
            // untinted siblings while staying in the same glass material.
            .overlay(
                shape.fill((tint ?? .white)
                    .opacity(tint != nil ? (brighter ? 0.30 : 0.20) : (brighter ? 0.10 : 0.04)))
                    .allowsHitTesting(false)
            )
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity((brighter ? 0.32 : 0.20) * rim),
                            .white.opacity(0.06 * rim),
                        ],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
                .allowsHitTesting(false)
            )
            // Real Liquid Glass barely casts a shadow — it reads as a thin chip of
            // glass, not a floating card. Just a whisper of a contact shadow to
            // seat it on the island; the specular rim does the rest of the work.
            .shadow(color: .black.opacity(0.10 * rim), radius: 1.5, y: 0.5)
    }
}

/// A minimal left-aligned flow layout: lays children left-to-right, wrapping to the
/// next line when the next child would overflow the proposed width. Used for the
/// model-picker chip row, which can carry more chips than fit the panel on one
/// line. Deliberately tiny — no alignment knobs beyond leading — since that's all the
/// chip row needs; reach for a real grid if a second caller wants more.
struct FlowLayout: Layout {
    var hSpacing: CGFloat = 6
    var vSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                // Wrap: bank the finished row's width, drop to the next line.
                widest = max(widest, x - hSpacing)
                x = 0; y += rowHeight + vSpacing; rowHeight = 0
            }
            x += size.width + hSpacing
            rowHeight = max(rowHeight, size.height)
        }
        widest = max(widest, x - hSpacing)
        return CGSize(width: min(widest, maxWidth), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0; y += rowHeight + vSpacing; rowHeight = 0
            }
            view.place(
                at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + hSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
