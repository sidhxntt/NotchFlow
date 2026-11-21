import AppKit
import ApplicationServices
import CoreLocation
import Carbon.HIToolbox
import Carbon.OpenScripting
import EventKit
import SwiftUI
import UserNotifications

/// The prompt editor's two closing actions: full width, fully rounded — the same
/// capsule every other affordance on the island wears, just stretched across the
/// card. `primary` is the island's own glass; `destructive` carries no resting
/// surface at all, so ending the shortcut never reads as loud as finishing the
/// edit — it only takes a whisper of red under the pointer.
struct PromptCardActionStyle: ButtonStyle {
    enum Kind { case primary, destructive }
    var kind: Kind

    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        Group {
            switch kind {
            case .primary:
                configuration.label
                    .glassCapsule(in: Capsule(), brighter: hovering)
            case .destructive:
                configuration.label
                    .background(Capsule().fill(
                        Tokens.danger.opacity(hovering ? 0.13 : 0)))
            }
        }
        .contentShape(Capsule())
        .opacity(configuration.isPressed ? 0.72 : 1)
        .scaleEffect(configuration.isPressed ? 0.985 : 1)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
    }
}

/// The trailing chips in the Shortcuts pane — chord recorders, reset, add. Fully
/// rounded like every other affordance on the island (`PanelBackPill`), and they
/// answer the pointer: wash and hairline brighten on hover, the same easeOut fade
/// every hover on the panel uses. Recording keeps its own brighter, ringed state,
/// which outranks hover so an armed chip never dims when the pointer leaves.
struct ShortcutChipStyle: ButtonStyle {
    /// The armed / recording chip: brighter wash and a full-weight ring.
    var active: Bool = false
    /// Resting wash and hairline, for chips that sit quieter than a chord (reset).
    var rest: Double = 0.07
    var restStroke: Double = 0.13

    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Capsule().fill(.white.opacity(
                    active ? 0.12 : (hovering ? rest + 0.055 : rest)))
            )
            .overlay(
                Capsule().strokeBorder(
                    .white.opacity(active ? 0.45 : (hovering ? restStroke + 0.11 : restStroke)),
                    lineWidth: active ? 1 : 0.5)
            )
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.72 : 1)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
    }
}

/// Backs the quick-tools popover with the panel's glass instead of the stock light
/// popover chrome. On macOS 13.3+ it replaces the presentation background itself
/// (so no light rim shows around the edges); older systems get the glass painted
/// behind the content as a graceful fallback.
struct GlassPopoverBackground: ViewModifier {
    /// Corner radius of the glass slab — matches the content it wraps (small list
    /// popovers use 10; the larger model-picker card uses 14).
    var cornerRadius: CGFloat = 10
    /// The smoked veil painted over the bare glass. The default (0.42) composites
    /// with the 0.34 baked tint to the panel's dark register (~0.62), so an occluding
    /// popover reads as solid material. A lower value lets far more of the liquid-glass
    /// refraction through — the airy, transparent Control-Center look — for cards that
    /// want to read as glass rather than a slab (e.g. the ⌘⇧I model picker).
    var veilOpacity: Double = 0.42
    /// Overrides the darkening baked into the glass material itself (default
    /// `GlassMaterial.bakedTint` = 0.34). The airy picker cards want to read as
    /// near-clear Liquid Glass, and the baked 0.34 is a *floor* on how transparent
    /// the card can get — no amount of lowering `veilOpacity` goes below it. Passing
    /// a lower tint (with `veilOpacity` at 0) lets the wallpaper refract through far
    /// more strongly than the standard occluding popover.
    var glassTint: Double = GlassMaterial.bakedTint

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // `nativeGlass` for the liquid refraction, PLUS a smoked veil bringing the
        // composite to the panel's own dark register (~0.62, the same number the
        // tooltip wafer and the panel's top band use). Bare glass composites to
        // only ~0.34 — a popover hangs over arbitrary windows, and at 0.34 the
        // text underneath stays legible *through* the card, reading as mud rather
        // than material. The veil is what makes it occlude like every other
        // floating layer in the app. (0.42 over the 0.34 baked tint ≈ 0.62.)
        //
        // The two touches that make it read as *glass* rather than a flat dark
        // board — the whole point of an airy card like the ⌘⇧I picker:
        //  · a soft top-down **sheen**, light pooling on the upper face, and
        //  · a directional **specular rim** — bright along the top edge, fading
        //    down the sides — the island's / detached card's edge idiom.
        // A flat, even hairline read as a drawn outline; the lit gradient edge
        // reads as the caught light on the rim of a real glass slab.
        let slab = ZStack {
            shape.fill(.clear).nativeGlass(in: shape, tintOpacity: glassTint)
                .overlay(shape.fill(Color.black.opacity(veilOpacity)))
            shape
                .fill(LinearGradient(colors: [.white.opacity(0.12), .clear],
                                     startPoint: .top, endPoint: .center))
                .blendMode(.plusLighter)
            shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(0.34), .white.opacity(0.08)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 0.75)
        }

        if #available(macOS 13.3, *) {
            content.presentationBackground { slab }
        } else {
            content.background { slab }
        }
    }
}
