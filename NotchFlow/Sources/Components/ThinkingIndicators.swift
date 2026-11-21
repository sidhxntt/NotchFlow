import SwiftUI
import AppKit
import Combine
import PDFKit
import ImageIO

/// The calm three-dot "thinking" wave used while the AI works. `dot`/`spacing`
/// scale the wave down for tight homes (the resting notch's busy extension);
/// the defaults are the original in-panel size.
struct ThinkingDots: View {
    var dot: CGFloat = 6
    var spacing: CGFloat = 7
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Tokens.text3)
                    .frame(width: dot, height: dot)
                    .scaleEffect(reduceMotion ? 0.9 : (phase ? 1.0 : 0.82))
                    .opacity(reduceMotion ? 0.55 : (phase ? 0.85 : 0.18))
                    .offset(y: reduceMotion ? 0 : (phase ? -2 : 0))
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.62)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.16),
                        value: phase
                    )
            }
        }
        .frame(minHeight: 22)
        .onAppear { if !reduceMotion { phase = true } }
    }
}

/// The "thinking orb" beside the wait word — a 1:1 port of the reference
/// implementation (orbs.jakubantalik.com, github.com/Jakubantalik/thinking-orbs),
/// NOT an approximation. What's ported, file by file:
///
/// - `engine/core.ts` → `OrbEngine`'s primitives: `fibDir` (Fibonacci lattice),
///   `makeProj` (spin + tilt + orthographic projection), `paint` (z-sorted
///   far→near painter, matte grayscale dots whose ink value is mirrored on the
///   dark substrate so near dots read bright) and `radiusScale` (sub-linear
///   size compensation, tuned around a 300pt frame).
/// - `engine/ribbon.ts` → `drawRibbon` (the demo's "Thinking…." pill),
///   `engine/lattice.ts` → `drawGlobe` (searching — a scan meridian sweeps a
///   dotted globe) and `drawRubik` (solving — the same dot field cut into
///   bands that twist in quarter turns, scramble, then click back),
///   `engine/orbits.ts` → `drawOrbits` (working — particles on tilted
///   orbits), and `engine/web.ts` → `drawWeb` (connecting — a drifting
///   constellation whose nodes wire together and pass bright packets). All
///   verbatim.
/// - `engine/profiles.ts` + `presets.ts` → each mode's base profile with its
///   inline `@ size 20` preset applied through the same `scaleCounts` /
///   `scaleRadii` machinery. The reference's remaining modes (wave / braid /
///   ring / morph) have no Notch wait state to wear them, so they aren't
///   ported — dead code isn't fidelity.
///
/// Which mode shows is SEMANTIC, decided where the activity originates (the
/// agent harness knows which tool it just launched — see
/// `AgentHarness.orbState(for:)`), never sniffed back out of a localized
/// status string:
///   • no tool activity (mood word / bare wait)      → `.composing` (ribbon)
///   • a first search round, or reading a page       → `.searching` (globe)
///   • a repeat search round ("digging deeper")      → `.solving`   (rubik)
///   • any other tool running                        → `.working`   (orbits)
///   • a pinned translation task                     → `.connecting` (web)
/// A state change cross-dissolves on the house beat rather than the
/// reference's hard remount — the one deliberate deviation, matching how
/// `CrossfadeText` melts the wait words this orb sits beside.
///
/// Grayscale literals here are the reference's own ink values, not house
/// tokens, deliberately: fidelity to the source is the point. Under Reduce
/// Motion this renders the reference's static representative frame (t = 0.6),
/// exactly as `ThinkingOrb.tsx` does for `prefers-reduced-motion`.
struct ThinkingOrb: View {
    /// Which of the ported reference states to show. Defaults to the calm
    /// "Thinking…." ribbon; the wait lines pass the live semantic state.
    var state: OrbState = .composing
    /// Rendered size. The reference ships exactly one inline tuning — 20 CSS
    /// px — and every preset below is that tuning, so this stays 20 unless
    /// a new preset is deliberately baked.
    var size: CGFloat = 20

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let preset = OrbEngine.preset(for: state)
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            // The reference clock: seconds × the preset's baked speed. Reduced
            // motion gets the reference's fixed frame (`frame(0.6)`).
            let t = reduceMotion
                ? 0.6
                : timeline.date.timeIntervalSinceReferenceDate * preset.speed
            // The ZStack is the stage for the state cross-dissolve: on a state
            // change the outgoing mode's last frame fades under the incoming
            // live one (`.id` swaps identity, `.transition` overlaps them).
            ZStack {
                Canvas { ctx, canvasSize in
                    preset.draw(&ctx,
                                Double(min(canvasSize.width, canvasSize.height)),
                                t,
                                preset.opts)
                }
                .id(state)
                .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: state)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Center a fixed-size glyph (the orb) on the OPTICAL middle of the text it
    /// sits beside, rather than on its line box.
    ///
    /// `HStack`'s default `.center` aligns the two *boxes*, and a text box is
    /// not centered on its own glyphs: the line box grows to whatever font
    /// actually renders the run, and a mixed Latin/CJK line falls back to
    /// PingFang, whose ascent/descent are both far taller than the glyphs
    /// themselves. The orb then floats visibly above the words it belongs to.
    ///
    /// Anchoring to the baseline instead makes the pairing metric-independent:
    /// the orb's centre lands 0.36em above the baseline — the midpoint of SF's
    /// cap height (0.72em) and, within a third of a point, of the CJK ideographic
    /// square (−0.12em…0.88em). So Latin, Chinese, and a line mixing both all
    /// read centred against the same orb.
    func centeredOnTextGlyphs(fontSize: CGFloat) -> some View {
        alignmentGuide(.firstTextBaseline) { d in d.height / 2 + fontSize * 0.36 }
    }
}

/// The reference states Notch actually wears, named exactly as `types.ts`
/// names them (`OrbState`). The mapping from Notch's wait-line semantics to
/// these lives with the producers (harness / model), not the views.
enum OrbState: Hashable {
    /// Ribbon — the demo's "Thinking…." pairing. The default calm state.
    case composing
    /// Globe with a sweeping scan meridian — the search flow.
    case searching
    /// Bands twisting in quarter turns, scrambling then clicking back to
    /// solved — a second-or-later search round, where the wait line reads
    /// "digging deeper" rather than a fresh search. Named for the reference
    /// state it wears (`solving`), not for Notch's copy; it shares the globe's
    /// dot field on purpose, so a repeat round still reads as the same search
    /// flow instead of a different job starting.
    case solving
    /// Particles on tilted orbits — a non-search tool doing work.
    case working
    /// A drifting constellation wires itself while packets run between nodes —
    /// the translation flow, connecting one language to another.
    case connecting
}
