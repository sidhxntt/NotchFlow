import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The pointer-side window's entrance, applied ONCE to the glass and the face
/// it carries together (`DetachedSessionRootView.compactShortcutFace`).
///
/// **Composer.** The whole face closes IN on itself: drawn a touch oversized and
/// settling to true size about its own centre, so every edge travels inward at
/// once and the box arrives by coming into focus rather than by growing out of a
/// corner — the Spotlight move. 1.04 is bounded by the face's own 8pt margin, so
/// the overhang stays inside the window and nothing is clipped mid-flight.
/// Leaving, only the shape moves: the fade belongs to the window, whose alpha
/// takes the shadow with it (`fadeOutAndClose`).
///
/// **Answer.** A card summoned straight into an answer IS an arrival, so it
/// swells out of the corner the pointer called it from. Opening out of this
/// window's own composer is not — `entered` is already true by then, this
/// resolves to the identity, and the only thing moving is the glass reshaping.
struct CompactEntrance: ViewModifier {
    var bare: Bool
    var entered: Bool
    var grownIn: Bool
    var exiting: Bool
    var anchor: UnitPoint
    var reduceMotion: Bool

    /// One chain, no `if bare … else …`.
    ///
    /// A structural branch HERE is not a style choice: a ViewModifier's body is
    /// where its content's identity is decided, so branching on `bare` gives the
    /// composer and the answer two different identities for the same subtree.
    /// Enter flips the flag, and SwiftUI tears the whole face down and builds it
    /// again — glass, mask, chrome and all — in the middle of the spring that is
    /// supposed to be opening the capsule into the card. That teardown is the
    /// double flash on entering a chat: the surface blinks out and back as it is
    /// rebuilt (a fresh `glassEffect` layer fades itself in), and the content's
    /// own crossfade (`compactFaceContent`) never plays, because a rebuilt
    /// subtree is an insertion, not a transition.
    ///
    /// Every difference between the two faces is a VALUE here — a number, an
    /// anchor, an animation — so the face survives the flip as one object and
    /// only the numbers travel.
    func body(content: Content) -> some View {
        // The composer is already on screen when a press stretched it into place
        // (`grownIn`); the answer is only ever shown once `entered` latched, which
        // Enter has already done by the time this is read.
        let shown = bare ? (entered || grownIn) : entered
        return content
            .scaleEffect(shown ? 1 : (bare ? 1.04 : 0.92),
                         anchor: bare ? .center : anchor)
            .opacity(shown ? 1 : 0)
            .offset(y: bare || shown ? 0 : -4)
            .scaleEffect(bare && exiting ? 1.03 : 1, anchor: .center)
            .animation(reduceMotion || !bare ? nil : .easeIn(duration: 0.24),
                       value: exiting)
    }
}

/// The window header's trailing control — pin + close, the two bare glyphs the
/// compact shortcut card wears, so a torn-out session and the composer it grew
/// from keep one set of chrome. Pin here means "float above other windows" (on
/// by default for a fresh tear-off).
///
/// No reattach button: handing the session back to the notch is the drag —
/// pull the window up over the notch and it merges. A glyph for it only
/// duplicated the gesture in a header that has room for two marks.
struct WindowTrailingCluster: View {
    var pinned: Bool
    var togglePin: () -> Void
    var close: () -> Void

    var body: some View {
        GlassSegmentCluster(segments: [
            .init(engaged: pinned,
                  tooltip: shortcutHelp(pinned ? "result.unpin" : "result.pin",
                                        action: .pin),
                  action: togglePin) {
                PinStateGlyph(pinned: pinned, size: 12.5, weight: .semibold)
            },
            .init(tooltip: L("detached.close"), action: close) {
                Image(systemName: "xmark")
                    .font(.sf(11, weight: .semibold))
            },
        ], showsTooltips: false)
    }
}

/// The prompt-shortcut window's numbers. The composer face is laid out from
/// these; the answer face is an ordinary detached session slab and takes its
/// rhythm from `DetachedThreadView` — only the transparent margin is shared.
enum CompactShortcutMetrics {
    /// The transparent margin around the floating pieces — the window's own
    /// breathing room, not padding inside a slab. The answer slab sits in the
    /// same margin, which is why its header lands where this band stood.
    static let inset: CGFloat = 8
    /// The chrome band above the capsule: one `GlassSegmentCluster`'s height (a
    /// 26pt chip in 3pt of glass) — i.e. exactly the answer card's header, which
    /// is what takes this slot once the answer arrives.
    static let band: CGFloat = 32
    /// Band → box.
    static let gap: CGFloat = 8
    /// The capsule's corners. Same value as the window silhouette
    /// (`DetachedSessionRootView.cornerRadius`), capped at half its height so a
    /// resting one-line composer is a true capsule.
    static let corner: CGFloat = DetachedSessionRootView.cornerRadius
    /// Everything the composer face carries around its capsule.
    static var chrome: CGFloat { inset + band + gap + inset }
    /// What an ANSWER window carries around its scrolling thread. It is the
    /// composer's own `chrome` — the margins AND the band the card hangs below,
    /// which the answer keeps rather than rising into (see `compactGlass`) —
    /// plus the header row and the follow-up line. The card's own padding is
    /// added by the caller (`DetachedThreadView`).
    static var answerChrome: CGFloat {
        chrome + DetachedThreadView.headerHeight
            + DetachedThreadView.compactFollowUpGap + DetachedThreadView.followUpHeight
    }

    // MARK: Where the caret lands
    //
    // The composer is placed by its text cursor, not by its corner: a force
    // click puts the caret exactly under the pointer
    // (`DetachedSessionWindowController.compactRect`). These are the offsets that
    // buys, and `ForceClickHerald` draws against the same numbers so the pressure
    // cue and the capsule it becomes occupy one spot.

    /// The card edge to the first glyph's cell: the card's own padding plus the
    /// compact input row's deliberately small internal inset.
    static var capsuleLeading: CGFloat {
        CompactShortcutPromptView.cardPad
            + CompactShortcutPromptView.inputLeadingPadding
            + PromptField.textInset
    }

    /// The face's coordinate space, so the caret can report where it landed in it.
    static let faceSpace = "compactShortcutFace"

    /// Where the text cursor sits inside the composer, from the window's top-left.
    ///
    /// This is MEASURED, not computed. The arithmetic below is only the opening
    /// guess for the very first composer on a fresh install; from then on the
    /// number comes from the laid-out view (`CaretProbe` → `rememberCaret`) and is
    /// persisted.
    ///
    /// It has to work that way. Placing the window by hand-totalled insets, while
    /// the face lays itself out from its own stack, is two sources of truth for one
    /// number — and they have already drifted once: a band moved from above the box
    /// to below it, the face grew a `footer`'s worth of height that the placement
    /// arithmetic didn't know about, and the pressure cue and the capsule it was
    /// supposed to become ended up on different lines of text. Measuring makes that
    /// class of bug impossible: the cue reads whatever the composer last actually
    /// did, so re-laying the face out can move both or neither, never one.
    static var caretOffset: CGPoint {
        if let stored = UserDefaults.standard.array(forKey: caretKey) as? [CGFloat],
           stored.count == 2, stored[0] > 0, stored[1] > 0 {
            return CGPoint(x: stored[0], y: stored[1])
        }
        return CGPoint(x: inset + capsuleLeading,
                       y: inset + band + gap + CompactShortcutPromptView.cardPad
                          + CompactShortcutPromptView.picksBlock(
                              CompactShortcutPromptView.quickPicks.count)
                          + CompactShortcutPromptView.restingRowHeight / 2)
    }

    /// Record where the composer's caret just laid out. Only a real, settled
    /// one-line layout is kept — a zero or a mid-animation measurement would poison
    /// the next window's placement.
    static func rememberCaret(_ offset: CGPoint) {
        guard offset.x > 0, offset.y > 0,
              offset.x.isFinite, offset.y.isFinite else { return }
        let current = caretOffset
        guard abs(current.x - offset.x) > 0.5 || abs(current.y - offset.y) > 0.5 else { return }
        UserDefaults.standard.set([offset.x, offset.y], forKey: caretKey)
    }

    private static let caretKey = "composerCaretOffset"

    /// The diameter of the capsule's rounded left cap — a full row, since the
    /// resting capsule is a true pill.
    static var capDiameter: CGFloat { NotchBody.idleRowHeight }
}

/// Reports where the prompt's first glyph cell sits inside the window, so the
/// composer can be *placed* by its caret instead of by a hand-totalled stack of
/// insets that nothing verifies (`CompactShortcutMetrics.caretOffset`).
struct CaretProbe: View {
    var report: (CGPoint) -> Void

    var body: some View {
        GeometryReader { geo in
            let box = geo.frame(in: .named(CompactShortcutMetrics.faceSpace))
            Color.clear
                .onAppear { report(Self.caret(in: box)) }
                .onChange(of: box) { _, new in report(Self.caret(in: new)) }
        }
        .allowsHitTesting(false)
    }

    /// The field's box begins `textInset` before its first glyph, and a one-line
    /// caret is centred on the row.
    private static func caret(in box: CGRect) -> CGPoint {
        CGPoint(x: box.minX + PromptField.textInset, y: box.midY)
    }
}

/// The compact composer's one trailing action slot. Collapsed History owns it
/// while the field is empty; once expanded, its disclosure moves to the drawer's
/// bottom-right corner like the main flow. Send uses this same footprint whenever
/// text exists, so typing never creates a second button or shifts the row.
struct CompactShortcutTrailingControl: View {
    var hasText: Bool
    var showsHistory: Bool
    var historyExpanded: Bool
    var send: () -> Void
    var toggleHistory: () -> Void

    /// The shared footprint, held whether Send is showing or not.
    /// Same diameter as the main-flow `IdleTrailingCluster` Recent disclosure.
    private static let slot: CGFloat = 30

    var body: some View {
        ZStack {
            if hasText {
                GlassIconButton(
                    systemName: "arrow.up",
                    help: L("shortcuts.send"),
                    size: Self.slot,
                    glyphSize: 13,
                    showsTooltip: false,
                    action: send)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else if showsHistory && !historyExpanded {
                CompactHistoryDisclosure(
                    expanded: historyExpanded,
                    action: toggleHistory)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .frame(width: Self.slot, height: Self.slot)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hasText)
    }
}

/// The main-flow disclosure, now standing beside rather than inside the compact
/// input recess.
struct CompactHistoryDisclosure: View {
    var expanded: Bool
    var action: () -> Void
    @State private var hovering = false

    /// Same diameter as the main-flow `IdleTrailingCluster` Recent disclosure.
    private static let size: CGFloat = 30

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.down")
                .font(.sf(11.5, weight: .semibold))
                .foregroundStyle(hovering ? Tokens.text1 : Tokens.text2)
                .rotationEffect(.degrees(expanded ? 180 : 0))
                .frame(width: Self.size, height: Self.size)
                .glassCapsule(in: Circle(), brighter: hovering)
                .contentShape(Circle())
        }
        .buttonStyle(GlassPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
        .animation(CompactHistoryMotion.spring, value: expanded)
        .accessibilityLabel("History")
    }
}

/// The compact composer's notification-style close control: smaller than the
/// row controls, genuinely backdrop-blurred, and locally responsive when the
/// pointer catches it.
struct CompactNotificationCloseButton: View {
    var action: () -> Void
    @State private var hovering = false

    private static let size: CGFloat = 18

    var body: some View {
        let shape = Circle()
        return Button(action: action) {
            Image(systemName: "xmark")
                .font(.sf(7.5, weight: .semibold))
                .foregroundStyle(hovering ? Tokens.text1 : Tokens.text2)
                .frame(width: Self.size, height: Self.size)
                .background {
                    shape.fill(.clear)
                        .nativeGlass(in: shape, tintOpacity: 0.18)
                        .overlay(shape.fill(Color.black.opacity(hovering ? 0.16 : 0.22)))
                        .overlay(shape.fill(Color.white.opacity(hovering ? 0.12 : 0.04)))
                        .overlay(shape.strokeBorder(
                            Color.white.opacity(hovering ? 0.34 : 0.18), lineWidth: 0.6))
                }
                .contentShape(Circle())
        }
        .buttonStyle(GlassPressStyle())
        .scaleEffect(hovering ? 1.08 : 1)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel(L("detached.close"))
    }
}

/// The same smoked glass the window slab wears (`DetachedWindowGlass`), cut to
/// an arbitrary shape. The bare composer has no slab to sit on, so its badge
/// and its input capsule each carry this themselves and still read as pieces of
/// the island rather than two foreign chips.
struct CompactComposerGlass<S: InsettableShape>: View {
    var shape: S
    /// How tall the CARD is right now, in points, when that differs from this
    /// surface. Only the veil reads it, and only to decide where its hem lands —
    /// the glass itself still fills whatever it is given, so nothing about the
    /// layout (or the card's edges, which the reveal mask owns) depends on this.
    ///
    /// It exists because the window keeps the disclosure's OPEN height until the
    /// reveal lands (`animateCompactHeight`), so during a fold this surface is
    /// taller than the card drawn on it. With the veil's stops being fractions of
    /// the surface, that stretched the gradient over the open height and left the
    /// mask showing only its smoked top — the transparent hem sat below the
    /// mask's edge — until the frame commit re-flowed the whole gradient into the
    /// collapsed box in one frame. That one frame is the flash.
    var cardHeight: CGFloat? = nil

    /// Smoked at the crown, letting go at the hem, and deliberately NOT a
    /// straight ramp between them: the top half gives up 0.13 of veil over its
    /// whole length while the bottom half gives up 0.27, so the surface reads as
    /// something lit from below rather than as a linear wash.
    ///
    /// The stops are FRACTIONS of the surface, not points off its edges. This
    /// glass carries a 56pt composer capsule, the Recent list unfolded under it,
    /// and the answer card — and all three are the same object at three heights,
    /// so the gradient has to stretch with it. Anchoring the hem to a fixed depth
    /// (which it was, briefly) left everything but the last 30pt of an unfolded
    /// list wearing the old even veil: the capsule shaded and the drawer under it
    /// flat, i.e. two materials in one window.
    /// `hem` is where location 1.00 lands, as a fraction of the surface — 1 for
    /// a surface that IS the card. Below the hem the gradient simply carries its
    /// last colour on, and that region is under the reveal mask anyway.
    private static func veil(hem: CGFloat) -> LinearGradient { LinearGradient(stops: [
        .init(color: .black.opacity(0.47), location: 0.00),
        .init(color: .black.opacity(0.41), location: 0.16),
        .init(color: .black.opacity(0.34), location: 0.40),
        .init(color: .black.opacity(0.28), location: 0.66),
        .init(color: .black.opacity(0.18), location: 0.86),
        .init(color: .black.opacity(0.07), location: 1.00),
    ], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: hem)) }

    var body: some View {
        Color.clear
            .nativeGlass(in: shape)
            // An overlay carrying a GeometryReader: it reads the size it is
            // handed and proposes nothing back, so the veil can be painted
            // against the card's height without any of it reaching layout.
            .overlay {
                GeometryReader { geo in
                    let hem = cardHeight.map {
                        min(max($0 / max(geo.size.height, 1), 0.05), 1)
                    } ?? 1
                    shape.fill(Self.veil(hem: hem))
                }
            }
    }
}

/// The same smoked-glass slab the History window wears — one even dark Liquid
/// Glass surface with a whisper of top sheen, so a detached session reads as a
/// piece of the island that left home, not as a foreign window.
struct DetachedWindowGlass: View {
    var body: some View {
        Rectangle()
            .fill(.clear)
            .nativeGlass(in: Rectangle())
            .overlay(Color.black.opacity(0.30))
            .overlay(
                LinearGradient(colors: [.white.opacity(0.05), .white.opacity(0.0)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 90)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            )
            .ignoresSafeArea()
    }
}
