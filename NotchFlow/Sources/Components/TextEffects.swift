import SwiftUI
import AppKit
import Combine
import PDFKit
import ImageIO

/// A single status-line slot that dissolves whenever its `text` changes, so a
/// rotating mood word ("Glowing" → "Drifting") or a status change ("Searching the
/// web…" → "Reading the results…") melts from one into the next rather than
/// hard-cutting. Two things make the seam read soft instead of stiff:
///
/// 1. **True overlap.** The outgoing and incoming words are two live layers in the
///    same leading slot, animated in opposite directions at once — the slot always
///    has a word in it. (The previous implementation faded out, swapped, then
///    faded in: sequential legs with a fully-blank beat in the middle.)
/// 2. **Blur + drift.** A plain opacity crossover double-exposes the two words at
///    the midpoint — both at half strength, glyph shapes fighting. So each layer
///    also blurs slightly and drifts a few points vertically (out: up and away;
///    in: settling up from below). The blur melts the overlap into one soft mass,
///    and the shared upward direction makes it read as one word giving way to the
///    next — the "blur replace" feel — instead of two ghosts stacked.
///
/// The word also carries the wait-line shimmer (`WaitShimmer`): a slow highlight
/// sweeping the glyphs that marks "the AI is working on this right now". Both the
/// dissolve and the shimmer collapse to a plain opacity swap / static text under
/// Reduce Motion.
struct CrossfadeText: View {
    let text: String
    var font: CGFloat = 15
    var color: Color = Tokens.text2

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The word currently lit; swapping it drives the transition below.
    @State private var shown: String = ""

    /// One dissolve. 0.45s reads as a calm melt, not a blink, and completes well
    /// inside the caller's rotation dwell (4s mood words, 1.2s host walk).
    private static let fade: Double = 0.45

    /// The out leg is a touch quicker than the in leg, so the incoming word owns
    /// the second half of the window instead of meeting the outgoing one at a
    /// muddy 50/50 midpoint.
    private var removal: AnyTransition {
        .modifier(
            active: DissolvePhase(opacity: 0, blur: 2.5, y: -3),
            identity: DissolvePhase(opacity: 1, blur: 0, y: 0)
        )
        .animation(.easeIn(duration: Self.fade * 0.7))
    }

    private var insertion: AnyTransition {
        .modifier(
            active: DissolvePhase(opacity: 0, blur: 2, y: 4),
            identity: DissolvePhase(opacity: 1, blur: 0, y: 0)
        )
        .animation(.easeOut(duration: Self.fade))
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Text(shown)
                .font(.sf(font, weight: .regular))
                .foregroundStyle(color)
                .modifier(WaitShimmer(active: !reduceMotion))
                .id(shown)
                .transition(reduceMotion
                    ? .opacity
                    : .asymmetric(insertion: insertion, removal: removal))
        }
        .onAppear {
            // First appearance lights up immediately — no fade-from-blank that
            // would read as a flicker on the very first word.
            shown = text
        }
        .onChange(of: text) { _, newValue in
            guard newValue != shown else { return }
            withAnimation(.easeInOut(duration: Self.fade)) {
                shown = newValue
            }
        }
    }
}

/// One frozen pose of the dissolve — the transition interpolates between the
/// `active` (fully out / not yet in) and `identity` (at rest) poses.
private struct DissolvePhase: ViewModifier {
    var opacity: Double
    var blur: CGFloat
    var y: CGFloat
    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .blur(radius: blur)
            .offset(y: y)
    }
}

/// The slow highlight that sweeps across the wait line while the AI works — the
/// shared visual convention for "generating right now" (ChatGPT's thinking label,
/// Claude Code's spinner text, Gemini's status lines all carry one). Deliberately
/// the most restrained cut: a soft white gleam over the existing grey, clipped to
/// the glyphs themselves — no colour shift, no underlying band. One pass takes
/// 2.6s (the ChatGPT/Claude ballpark); the band starts and ends fully off the
/// text, so the loop restart is invisible. Static under Reduce Motion.
struct WaitShimmer: ViewModifier {
    var active: Bool = true

    /// Horizontal position of the gleam band, in multiples of the text width:
    /// −0.7 parks it fully off the left edge, 1.25 fully off the right.
    @State private var phase: CGFloat = -0.7

    func body(content: Content) -> some View {
        if active {
            content
                .overlay(
                    GeometryReader { geo in
                        LinearGradient(
                            gradient: Gradient(stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .white.opacity(0.75), location: 0.5),
                                .init(color: .clear, location: 1),
                            ]),
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: max(geo.size.width * 0.45, 36))
                        .offset(x: geo.size.width * phase)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                )
                .onAppear {
                    phase = -0.7
                    withAnimation(.linear(duration: 2.6).repeatForever(autoreverses: false)) {
                        phase = 1.25
                    }
                }
        } else {
            content
        }
    }
}

/// The quiet elapsed-time suffix at the end of the wait line — proof that a long
/// agent round is alive, not hung. Appears only once the wait has crossed
/// `threshold` (quick answers never see a timer), then ticks once a second in a
/// smaller, fainter cut than the wait word so it reads as a footnote, not a
/// stopwatch. The ChatGPT / Claude Code elapsed-time convention, reduced to its
/// minimum.
struct WaitElapsedSuffix: View {
    /// When the round started thinking; nil hides the suffix entirely.
    let since: Date?
    var font: CGFloat = 15

    /// How long the wait must run before the timer surfaces.
    private static let threshold: TimeInterval = 6

    var body: some View {
        if let since {
            TimelineView(.periodic(from: since, by: 1)) { context in
                let s = Int(context.date.timeIntervalSince(since))
                if s >= Int(Self.threshold) {
                    Text("\(s)s")
                        .font(.sf(font - 2))
                        .monospacedDigit()
                        .foregroundStyle(Tokens.text4)
                        .transition(.opacity)
                }
            }
        }
    }
}
