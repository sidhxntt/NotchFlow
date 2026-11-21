import SwiftUI
import AppKit

/// Carries the answer text's intrinsic height up to the body so the scroll area
/// can size itself to the content (capped at the ceiling).
struct AnswerHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        // Take the latest reported height, NOT max(). There's a single reader (the
        // scroll content's GeometryReader), so this just carries its current height
        // through — which must be able to SHRINK, not only grow. `max` latched the
        // measurement to the largest value ever seen (a tall earlier answer, or a
        // transient layout pass), so when a short answer replaced a long one the
        // scroll frame stayed tall and left a dead band under the text. Last-value
        // lets the frame track the real content up and down.
        let next = nextValue()
        if next > 0 { value = next }
    }
}

/// Where the agent detail scroll's content ENDS, measured in the scroll's own
/// coordinate space: equal to the viewport height when the page sits at the tail,
/// larger once the reader has scrolled up. That difference is the whole basis of
/// the tail-follow release (`agentDetailFollowsTail`).
struct AgentDetailContentBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        // Single reader, like `AnswerHeightKey`: carry the current value through
        // so it can fall as well as rise.
        let next = nextValue()
        if next != 0 { value = next }
    }
}

/// Carries the immersive floating header's measured height up to `NotchBody` so the
/// list's top runway and frost band can be sized to whatever the header actually
/// holds — a bare input, or an input topped by a copied-image preview.
struct ImmersiveHeaderHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        // Single reader; last value wins so the runway can SHRINK back when the
        // preview clears, not just grow (same rationale as `AnswerHeightKey`).
        let next = nextValue()
        if next > 0 { value = next }
    }
}

/// The "Set up your model" row that stands in for the follow-up field on the
/// offline stub. Mirrors the follow-up box's chrome — full capsule, faint fill,
/// hairline border — and brightens on hover / gives slightly on press so it reads
/// as the same kind of affordance, just leading somewhere instead of accepting text.
struct SetupModelButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .recessedSurface(in: Capsule(), lit: hovering)
            .scaleEffect(pressed ? 0.985 : 1)
            .opacity(pressed ? 0.85 : 1)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: pressed)
    }
}

/// The idle prompt's trailing controls — the pin and the Recent disclosure. Each is
/// its own round glass chip, in exactly the language of the recent panel's ⋯ entry
/// (`GlassIconButton`): a translucent glass circle that brightens under the cursor.
/// They used to share one capsule, which wrapped the lone chevron in a pill of
/// dead space — the chip IS the target now, no padding around it.
///
/// Engaged state (pinned, or Recent open) reads through the glyph alone — the
/// filled, upright tack and the flipped chevron — never a wash.
///
/// The idle prompt shows no pin *button*: an unpinned panel offers only Recent, and
/// ⌘P/⌘D (ContentView's key handler) is how pinning happens. The tack appears here
/// only once the panel IS pinned — state made visible, and the click that releases it.
struct IdleTrailingCluster: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var pinned: Bool
    var recentOpen: Bool
    /// Recent has nothing to show on a first run — the pill then carries the pin
    /// alone and shrinks to a single round segment.
    var showsRecent: Bool
    /// How many agent runs are live. Non-zero swaps the round chevron for a
    /// "N running ⌄" capsule *while the list is closed* — the live count rides the
    /// disclosure itself instead of a standalone status strip below the prompt.
    /// With Recent open the count is redundant (the runs head the list), so the
    /// chevron comes back plain.
    var runningCount: Int = 0
    /// The chip's diameter. Defaults one step down from the ⋯ chip — in the prompt
    /// row these sit inside the input's chrome, not on the panel's. The manage bar
    /// passes the ⋯'s own 34 so the bar's two corners read as a matched pair.
    var chipSize: CGFloat = 30
    var togglePin: () -> Void
    var toggleRecent: () -> Void

    /// Nothing to draw when neither segment is live — an empty capsule of glass
    /// would still read as a control. A live run always draws (the "N running"
    /// chip), even before any Recent history exists to disclose.
    var isEmpty: Bool { !pinned && !showsRecent && runningCount == 0 }

    private enum Segment { case pin, recent }

    @State private var hovered: Segment? = nil

    /// Glyph point size, held at the 11.5/30 ratio the 30pt chip was drawn at, so a
    /// bigger chip doesn't end up with a proportionally smaller mark inside it.
    private var glyphSize: CGFloat { chipSize * (11.5 / 30) }

    var body: some View {
        HStack(spacing: 6) {
            // The pin has no button at rest — ⌘P/⌘D is the way in. Once pinned it
            // surfaces here as the state's own affordance: it shows the panel is held
            // open, and clicking it lets go.
            if pinned {
                segment(.pin, engaged: true, action: togglePin,
                        tooltip: shortcutHelp("result.unpin", action: .pin)) {
                    PinStateGlyph(pinned: true, size: glyphSize, weight: .semibold)
                }
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            // Live runs fold their count into the disclosure — "N running ⌄" — so
            // the resting panel stays at its input while a background agent works;
            // the standalone status strip stays hidden until nothing's running.
            // Once the list IS open the count has served its purpose — the runs are
            // right there at the top of it, with their own status dots — so the
            // capsule collapses back to the plain chevron that closes the list.
            if runningCount > 0 && !recentOpen {
                runningRecentChip
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
            } else if showsRecent || recentOpen {
                segment(.recent, engaged: recentOpen, action: toggleRecent,
                        tooltip: L("recent.recent"), showsTooltip: false) {
                    // A downward chevron reads as "pull the recent list down"; it flips
                    // to point up once the list is open, so the same control says
                    // "close" on the way back.
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(recentOpen ? 180 : 0))
                        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: recentOpen)
                }
                .transition(.scale(scale: 0.7).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: showsRecent)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: pinned)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: runningCount)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: recentOpen)
    }

    /// The disclosure while runs are live: the same glass, stretched to a capsule
    /// that carries a breathing bead, the "N running" count, and the chevron. Tapping
    /// it drops the Recent list, whose top rows are those very runs (with their
    /// cancel controls) — so the count is a live handle, never a dead badge.
    private var runningRecentChip: some View {
        let hovering = hovered == .recent
        return Button(action: toggleRecent) {
            HStack(spacing: 5) {
                AgentStatusDot(running: true, outcome: nil)
                Text(L("agent.running.count", runningCount))
                    .font(.sf(glyphSize, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(runningCount)))
                    // Roll the digit natively, the way the row clock ticks: the
                    // animation has to ride the Text itself for `numericText` to
                    // fire — on the outer Button it only drives the layout.
                    .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: runningCount)
                Image(systemName: "chevron.down")
                    .font(.sf(glyphSize - 1.5, weight: .semibold))
                    .rotationEffect(.degrees(recentOpen ? 180 : 0))
                    .animation(.spring(response: 0.32, dampingFraction: 0.8), value: recentOpen)
            }
            .foregroundStyle(hovering ? Tokens.text1 : Tokens.text2)
            .padding(.horizontal, 10)
            .frame(height: chipSize)
            .glassCapsule(in: Capsule(), brighter: hovering)
            .contentShape(Capsule())
        }
        .buttonStyle(GlassPressStyle())
        .onHover { inside in
            if inside { hovered = .recent }
            else if hovered == .recent { hovered = nil }
        }
        .animation(.easeOut(duration: 0.18), value: hovered)
        .animation(.snappy(duration: 0.3), value: runningCount)
    }

    /// One round glass chip — the ⋯ entry's `GlassIconButton` body, with an extra
    /// `engaged` ink step (pinned / Recent open) the shared component doesn't carry.
    private func segment<Glyph: View>(
        _ segment: Segment, engaged: Bool, action: @escaping () -> Void,
        tooltip: String, showsTooltip: Bool = true, @ViewBuilder glyph: () -> Glyph
    ) -> some View {
        let hovering = hovered == segment
        return Button(action: action) {
            glyph()
                .font(.sf(glyphSize, weight: .semibold))
                .foregroundStyle(hovering ? Tokens.text1 : (engaged ? Tokens.text2 : Tokens.text3))
                .frame(width: chipSize, height: chipSize)
                .glassCapsule(in: Circle(), brighter: hovering)
                .contentShape(Circle())
        }
        .buttonStyle(GlassPressStyle())
        .onHover { inside in
            if inside { hovered = segment }
            else if hovered == segment { hovered = nil }
        }
        .animation(.easeOut(duration: 0.18), value: hovered)
        .notchTooltip(tooltip, shows: showsTooltip)
        .accessibilityLabel(tooltip)
    }
}

/// The result header's trailing control — the pin — held in a Liquid Glass capsule
/// (`glassCapsule` = native `.glassEffect` on macOS 26+, blur fallback below). The
/// capsule is a circle around the lone pin. A bare glyph would read as an unrelated
/// control in a different material; the system's own grouped-glass shape gives it a
/// proper pane, the way a Safari toolbar button sits.
///
/// The glass lives on the capsule and only there: a hovered segment marks itself
/// with ink and a soft circle of light, never a second pane of glass nested inside
/// the first. Glyphs stay pure white — engaged (pinned) reads through the filled
/// tack, its upright tilt, and a white wash, never a colour tint.
///
/// Toggling routes back through the model so an un-pin can immediately re-arm
/// the leave-fold if the pointer is already gone.
struct ResultTrailingCluster: View {
    var pinned: Bool
    var togglePin: () -> Void
    /// Tear-off action. When set, a detach chip joins the pin, to its left — the
    /// two view actions read as one pair (tight 6pt spacing), set apart from the
    /// composer chip further left by the header's wider 10pt gap.
    var detach: (() -> Void)? = nil

    var body: some View {
        GlassSegmentCluster(segments: {
            var segs: [GlassSegmentCluster.Segment] = []
            if let detach {
                segs.append(.init(tooltip: shortcutHelp("detached.open", action: .detach),
                                  action: detach) {
                    Image(systemName: "macwindow.on.rectangle")
                        .font(.sf(10.5, weight: .medium))
                })
            }
            segs.append(.init(engaged: pinned,
                              tooltip: shortcutHelp(pinned ? "result.unpin" : "result.pin",
                                                    action: .pin),
                              action: togglePin) {
                PinStateGlyph(pinned: pinned, size: 11, weight: .medium)
            })
            return segs
        }(), glass: false)
        // Hover-only chrome sitting right beside the answer: it should be
        // findable, not loud. This drops the bare cluster's own levels onto the
        // history footer's meta pair — text4 at rest, text2 under the pointer —
        // without giving this one caller a private tint API.
        .opacity(0.72)
    }
}

/// The header's back chevron, wearing the panel's **Liquid Glass** language: a
/// real glass circle (native `.glassEffect` on macOS 26+, blurred fallback below)
/// with the signature specular rim, brightening under the cursor like every other
/// chip in the header. It used to be a bare glyph over a flat white-wash hover
/// pill, which read as a different material from the glass cluster opposite it.
struct GlassBackButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.sf(13, weight: .semibold))
                .foregroundStyle(hovering ? Tokens.text1 : Tokens.text2)
                .frame(width: 26, height: 26)
                .glassCapsule(in: Circle(), brighter: hovering)
                .contentShape(Circle())
        }
        .buttonStyle(GlassPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
    }
}

struct RecentEntryStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // A Capsule, not a Circle: it collapses to a perfect circle behind a
            // square icon button (e.g. the 27×27 continue-elsewhere icon) but reads
            // as a proper pill behind a wide text label. A Circle stretched to the
            // label's wide rectangular bounds rendered as an oversized ellipse that
            // bled above and below the text.
            .background(
                Capsule().fill(.white.opacity(hovering ? 0.08 : 0))
            )
            .opacity(configuration.isPressed ? 0.5 : (hovering ? 1 : 0.85))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: Tokens.rowFade), value: hovering)
    }
}
