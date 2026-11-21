import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Window content

/// The window's one mutable knob set: its life phase (riding the drag →
/// settled → merging away), the ride's momentum tilt, and whether it floats
/// pinned above other windows (the default — a torn-out session is a thing
/// being watched; unpin demotes it to a normal window).
@MainActor
final class DetachedWindowState: ObservableObject {
    enum Phase { case riding, settled, merging }
    @Published var phase: Phase = .riding
    @Published var tilt: Double = 0
    @Published var pinned = true
    /// What the window holds. Mutable because a `.compose` window becomes the
    /// `.thread` it starts — the same window keeps writing where the composer
    /// stood, so this can't be fixed at birth.
    @Published var session: DetachedSession
    /// The live mirror of the thread being watched — nil while composing.
    @Published var threadStore: DetachedThreadStore?
    /// The composer's unsent line: seeded from the panel's box at tear-off, and
    /// handed back to it on a merge home.
    @Published var composeDraft = ""
    /// The empty-prompt shortcut's captured context and one-off instruction.
    /// They live on the window state so invoking the same shortcut again can
    /// atomically replace both without creating a second controller.
    @Published var compactSourceText = ""
    @Published var compactPromptDraft = ""
    @Published var compactPromptGeneration = 0
    /// The corner the pointer summoned this window from — the entrance grows out
    /// of it, so the window reads as opening *from* the selection rather than
    /// fading in on top of it. Trailing when it had to open on the pointer's
    /// left (`DetachedSessionWindowController.compactRect`).
    @Published var entranceAnchor: UnitPoint = .topLeading
    /// True when a force click already stretched this capsule into place
    /// (`ForceClickHerald`). The face then skips its own swell — replaying it over
    /// the identical shape the press is holding is exactly the cross-fade the
    /// stretch exists to avoid. The badge under the box still arrives on its own
    /// beat.
    @Published var grownIn = false
    /// How far the force click that is drawing this window has come, 0…1 — `nil`
    /// once it has fired and this is an ordinary composer.
    ///
    /// While it is set, the window draws its input capsule's rounded left cap and
    /// nothing else: no field, no band, no badge. That cap is not a stand-in for
    /// the composer's capsule, it IS the composer's capsule at its cap width, so
    /// firing only springs one number. Two surfaces were tried first — a cue panel
    /// above the window — and could not be made to hand over invisibly: `.clear`
    /// Liquid Glass multiplies, so the frames where both stood came out more than
    /// twice as dark as either alone.
    @Published var pressDepth: Double?
    /// Bumped whenever the window lands at a new pointer without being re-made
    /// (the same shortcut fired again somewhere else) — the face replays its
    /// entrance there instead of teleporting.
    @Published var entranceToken = 0
    /// True while the answer face is taking over from THIS window's own composer
    /// (Enter in the capsule). The card is then already standing when it appears —
    /// no swell, no fade up from nothing: the capsule opens into it as one move.
    /// An entrance here would read as a second, foreign window popping over the
    /// line the user just typed, which is exactly what the morph exists to avoid.
    @Published var openingFromComposer = false
    /// True when this pointer-side shell was summoned by an actual Force Touch,
    /// rather than the selected-text keyboard action that reuses the same view.
    /// Drives both the scoped History affordance and the origin stamp on submit.
    @Published var forceTouchInvocation = false
    /// The inline ledger beneath the Force Touch composer. Its height is part of
    /// this window's own measured face; it never opens a secondary window.
    @Published var forceTouchHistoryExpanded = false
    /// During a discrete compact resize the actual window is already at the
    /// destination size (or stays at its old size until a collapse completes).
    /// This top-aligned mask is the only animated edge, so the window's upper
    /// border never participates in the disclosure animation.
    @Published var compactRevealHeight: CGFloat? = nil
    /// Whether the next swap between the card's two faces is NAVIGATION — a saved
    /// conversation opened out of the ledger, or Back out of it — rather than the
    /// capsule morphing into the answer it was just asked for. The two read
    /// differently on purpose; see `compactFaceTransition`.
    @Published var compactFaceDrills = false
    /// Called by the face the first time SwiftUI has actually DRAWN a freshly
    /// installed `compactRevealHeight`. The controller may only grow the NSWindow
    /// once that has happened — see `animateCompactHeight`, where waiting on this
    /// rather than on a guessed delay is what removes the flash.
    var onRevealArmed: (() -> Void)?
    /// The window is on its way out (`fadeOutAndClose`). The composer face reads
    /// it to collapse back onto its entrance anchor instead of just vanishing.
    @Published var exiting = false

    init(session: DetachedSession) {
        self.session = session
    }
}

/// Root view: the glass slab, wearing the tear-off card while riding the drag
/// and crossfading into the full session view on landing.
struct DetachedSessionRootView: View {
    @ObservedObject var state: DetachedWindowState
    /// Only the composer talks to the panel model directly (its placeholder, its
    /// armed bucket, its note-save feedback all live there) — and only IT
    /// observes it. Held here as a plain reference on purpose: observing the
    /// model at this level would re-render a streaming thread window on every
    /// unrelated model publish.
    let model: NotchModel
    /// The answer's voice, tracked on its own key so this view can follow the
    /// setting live without observing the whole model — see `sessionBody`.
    @AppStorage(Handwriting.defaultsKey) private var handwrittenAnswers = false
    var onTogglePin: () -> Void
    var onClose: () -> Void
    // Thread-window actions (unused by the agent-task face, which talks to
    // `AgentTaskManager` directly).
    var onInAppCopy: () -> Void = {}
    var onReplaceOriginal: (String) -> Bool = { _ in false }
    var onFollowUp: (String, [NSImage]) -> Void = { _, _ in }
    var onRegenerate: () -> Void = {}
    var onRegenerateWith: (String) -> Void = { _ in }
    var onChooseOption: (UUID, String) -> Void = { _, _ in }
    var regenerateOptions: () -> [(model: String, isCurrent: Bool)] = { [] }
    /// Enter in the composer face: the line and where it reads as going.
    var onCompose: (String, NotchModel.Panel) -> Void = { _, _ in }
    /// The composer's wanted height as its draft wraps — the window follows it.
    var onComposeHeight: (CGFloat) -> Void = { _ in }
    /// Enter in an empty-prompt shortcut's one-line composer — or a tap on one
    /// of the shortcut buttons standing over it, which carries that shortcut's
    /// own pinned backend with it.
    var onCompactPrompt: (String, ModelPin?) -> Void = { _, _ in }
    var onToggleForceTouchHistory: () -> Void = {}
    var onOpenForceTouchHistory: (UUID) -> Void = { _ in }
    /// Where the composer's caret laid out, in the window's own coordinates — the
    /// window is placed by it rather than by counted insets.
    var onCaretOffset: (CGPoint) -> Void = { _ in }
    /// Compact prompt-shortcut threads size to their answer instead of taking a
    /// fixed session-window frame.
    var compactShortcut = false
    var onThreadHeight: (CGFloat) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Has the pointer-side entrance played? False for exactly one frame per
    /// appearance — see `playEntrance`.
    @State private var entered = false
    /// Native-notification-style corner actions stay out of the composer's way
    /// until the pointer is actually over this compact surface.
    @State private var compactHovering = false

    /// The window's own silhouette — the glass draws it (the window is
    /// borderless), continuous-rounded like the island's bottom corners.
    ///
    /// Exactly the open island's bottom radius (`ContentView.bottomRadius`, 30),
    /// which is also what the prompt-shortcut card already wore
    /// (`CompactShortcutMetrics.corner`). ONE radius across every detached face:
    /// a torn-out session and a pointer-side answer are the same window at two
    /// sizes, so they cannot round differently. (It used to be 16 here, which
    /// read as a second, squarer species of window beside the 30 of the
    /// shortcut card.)
    static let cornerRadius: CGFloat = 30

    /// The empty-prompt shortcut face paints NO window slab: its context badge
    /// floats free above a capsule input, and those two pieces *are* the window
    /// (see `CompactShortcutPromptView`). Every other face — threads, composer,
    /// agent tasks — rides the smoked glass slab.
    private var isBareComposer: Bool {
        if case .shortcutComposer = state.session { return true }
        return false
    }

    /// History grows the composer downward without changing the curve it wore
    /// while collapsed. The answer remains the ordinary detached-window shape.
    private var compactCornerRadius: CGFloat {
        isBareComposer ? CompactShortcutPromptView.cardCornerRadius : Self.cornerRadius
    }

    var body: some View {
        Group {
            if compactShortcut {
                compactShortcutFace
            } else {
                slab(corner: Self.cornerRadius)
            }
        }
        .rotationEffect(.degrees(state.tilt), anchor: .top)
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.62), value: state.tilt)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: state.phase)
    }

    /// The prompt-shortcut window's two faces. The **composer** is a band, a
    /// capsule and a footnote badge floating free over the app underneath. The
    /// **answer** is not a special card any more — it is the ordinary detached
    /// session slab (`DetachedThreadView`: header, thread, follow-up), filling
    /// the window inside the same 8pt margin, so a pointer-side answer and a
    /// torn-out session are one window at two sizes rather than two styles.
    ///
    /// Both faces are the same card in the same place: the chips row on top, a
    /// capsule on the bottom, and between them either the user's shortcuts or
    /// the answer. Enter replaces the middle and lets the bottom edge travel —
    /// it does not move the card.
    private var compactShortcutFace: some View {
        ZStack(alignment: .top) {
            compactGlass
            compactFaceContent
        }
        // The reveal mask is on the card as of this update pass. Nothing about
        // the window's size may move before this fires (`animateCompactHeight`).
        .onChange(of: state.compactRevealHeight) { _, _ in state.onRevealArmed?() }
        // History and composer-to-result resizing reveal downward from the
        // existing top edge. The NSWindow itself is never resized per frame.
        //
        // The reveal edge carries the CARD's own bottom corners, not a straight
        // cut. A plain `Rectangle` mask sliced the sheet on a hard horizontal
        // line, so for the whole 0.28s disclosure the window wore square bottom
        // corners and only snapped round on the last frame — the disclosure read
        // as a box being unrolled rather than the card growing. So the mask is
        // the card's silhouette: inset by the window's own transparent margin
        // (nothing is ever drawn out there, so nothing is lost) and rounded at
        // the bottom on the same radius the slab wears. The top stays a square
        // full-bleed edge — the mask only ever cuts downward, and the band and
        // chips above the card must never be touched by it.
        .mask(alignment: .top) {
            UnevenRoundedRectangle(bottomLeadingRadius: compactCornerRadius,
                                   bottomTrailingRadius: compactCornerRadius,
                                   style: .continuous)
                .padding(.horizontal, CompactShortcutMetrics.inset)
                .padding(.bottom, CompactShortcutMetrics.inset)
                .frame(height: state.compactRevealHeight ?? 10_000,
                       alignment: .top)
        }
        // Added after the reveal mask so the notification-style composer
        // controls can genuinely cross the card edge instead of being clipped
        // back to its silhouette.
        .overlay(alignment: .top) { compactChrome }
        // ONE entrance for the sheet and whatever is drawn on it. Split across
        // the two faces (as it was) the glass and its content could be caught
        // mid-morph playing different transforms — the exact seam this whole
        // arrangement exists to remove.
        .modifier(CompactEntrance(bare: isBareComposer, entered: entered,
                                  grownIn: state.grownIn, exiting: state.exiting,
                                  anchor: state.entranceAnchor,
                                  reduceMotion: reduceMotion))
        // Enter in this window's OWN capsule is not an arrival: the card is the
        // box the user is already looking at, grown. Replaying the pointer
        // entrance there made it read as a second window popping over the line
        // just typed (see `submitCompactShortcutPrompt`).
        .onAppear {
            if !isBareComposer, state.openingFromComposer { entered = true }
            else { playEntrance() }
        }
        .onChange(of: state.entranceToken) { _, _ in playEntrance() }
        .onHover { compactHovering = $0 }
    }

    /// Close keeps the native-notification position on the card's upper-left
    /// corner. Settings now lives beside the History disclosure in the composer
    /// row, so the right corner deliberately stays empty.
    @ViewBuilder
    private var compactChrome: some View {
        if isBareComposer {
            HStack(spacing: 0) {
                CompactNotificationCloseButton(action: onClose)

                Spacer(minLength: 0)
            }
            // The card begins at this y/x inset. Pulling the 18pt control 4pt
            // across that boundary leaves a deliberate notification-style
            // overhang without clipping it against the NSWindow.
            .padding(.horizontal, 2)
            .padding(.top, CompactShortcutMetrics.inset
                     + CompactShortcutMetrics.band
                     + CompactShortcutMetrics.gap - 4)
            .opacity(compactHovering && state.pressDepth == nil ? 1 : 0)
            .allowsHitTesting(compactHovering && state.pressDepth == nil)
            .animation(
                reduceMotion ? nil : .easeOut(duration: compactHovering ? 0.22 : 0.12),
                value: compactHovering
            )
            .transition(Self.cornerMarkTransition(arriving: false))
        } else {
            compactAnswerChips
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(Self.cornerMarkTransition(arriving: true))
        }
    }

    /// The corner's two marks HAND OVER — they never share the corner.
    ///
    /// They are different objects in different places: the composer's close is an
    /// 18pt circle at (2, 44), deliberately overhanging the card's top edge by
    /// 4pt the way a notification's does; the card's is a ~62x32 segment cluster
    /// at (16, 56), sitting inside the card. Twelve points apart vertically,
    /// fourteen horizontally, and different sizes. Cross-fading them — which is
    /// what an undeclared `if/else` inside an animated transaction does — puts
    /// two rounded glass shapes over each other in one 40pt corner, on top of the
    /// composer's own input line still dissolving underneath. That is the pile-up
    /// at the top-left, and it only shows when the pointer is on the card, which
    /// a force click guarantees (the composer's close is hover-gated).
    ///
    /// So the outgoing mark is gone before the incoming one starts, on the same
    /// numbers the card's contents use (`compactFaceTransition`, morph case) —
    /// the corner is briefly empty, exactly like the glass in the middle of the
    /// move, and the hand-over reads as one thing becoming another.
    private static func cornerMarkTransition(arriving: Bool) -> AnyTransition {
        .asymmetric(
            insertion: .opacity.animation(
                .easeOut(duration: arriving ? 0.22 : 0.20)
                    .delay(arriving ? 0.10 : 0.08)),
            removal: .opacity.animation(.easeIn(duration: 0.10)))
    }

    private var compactAnswerChips: some View {
        let pinned = state.pinned
        // Close leads the cluster on the card's upper-LEFT corner, matching the
        // bare composer's notification-style close rather than sitting opposite
        // it.
        var segments: [GlassSegmentCluster.Segment] = [
            .init(id: "compact-close", tooltip: L("detached.close"), action: onClose) {
                Image(systemName: "xmark")
                    .font(.sf(11, weight: .semibold))
            }
        ]
        // A Force Touch card carries its own composer and ledger — the answer is
        // one face of THIS window, not a dead end. Back returns to it in place.
        if state.forceTouchInvocation {
            segments.append(.init(id: "compact-back",
                                  tooltip: L("recent.collapse"),
                                  action: onToggleForceTouchHistory) {
                Image(systemName: "chevron.left")
                    .font(.sf(11, weight: .semibold))
            })
        }
        // An unpinned answer stays quiet: the pin appears only after the keyboard
        // shortcut pins it, making the held state visible and clickable to undo.
        if pinned {
            segments.append(.init(id: "compact-primary",
                                  engaged: true,
                                  tooltip: shortcutHelp("result.unpin", action: .pin),
                                  action: onTogglePin) {
                PinStateGlyph(pinned: true, size: 12.5, weight: .semibold)
            })
        }
        return GlassSegmentCluster(segments: segments, showsTooltips: false)
        .padding(.top, CompactShortcutMetrics.inset + CompactShortcutMetrics.band
                 + CompactShortcutMetrics.gap + DetachedThreadView.compactCardPadding)
        .padding(.leading, CompactShortcutMetrics.inset
                 + DetachedThreadView.compactCardPadding)
        // While a force click is still being decided the window is drawn as a
        // bare cap — the same gate the card's own content is behind.
        .opacity(state.pressDepth == nil ? 1 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: pinned)
    }

    /// What is drawn ON the sheet: only the content crosses over, never the glass
    /// under it. How it crosses is `compactFaceTransition`.
    @ViewBuilder
    private var compactFaceContent: some View {
        if isBareComposer {
            compactComposerFace
                .transition(compactFaceTransition(composer: true))
        } else {
            slab(corner: Self.cornerRadius, glass: false)
                .padding(CompactShortcutMetrics.inset)
                // Sits on the sheet, which hangs below the band in both faces.
                .padding(.top, CompactShortcutMetrics.band + CompactShortcutMetrics.gap)
                .transition(compactFaceTransition(composer: false))
        }
    }

    /// How the card's two faces trade places — one of two verbs, chosen by
    /// whoever changed the session (`state.compactFaceDrills`).
    ///
    /// **Morph.** Enter in the capsule. Only the contents cross-fade, the
    /// composer's leaving quickly and the card's arriving a beat later, so the
    /// glass is visibly alone in the middle of the move. That beat is the whole
    /// point: it reads as one surface reshaping, not two slabs swapping.
    ///
    /// **Drill.** A saved conversation opened out of the ledger, and Back out of
    /// it. Nothing travels — a sideways page push was tried here first and is far
    /// too heavy a move for a 370pt card whose height is also landing in one set.
    ///
    /// A BATON PASS, not an overlap: the leaving page is gone before the arriving
    /// one starts (the insertion's delay is exactly the removal's duration).
    /// Running them together — which is what a literal cross-fade does — puts two
    /// full pages of text on the card at half strength each, and at these
    /// durations both are perfectly legible at once: six ledger rows and four
    /// lines of answer, interleaved. That double exposure is the mess; length
    /// only made it easier to read.
    ///
    /// Still deliberately slower than the morph's, so the dissolve is something
    /// you watch rather than a cut with a smear on it.
    private func compactFaceTransition(composer: Bool) -> AnyTransition {
        guard state.compactFaceDrills, !reduceMotion else {
            return .asymmetric(
                insertion: .opacity.animation(
                    .easeOut(duration: composer ? 0.20 : 0.22)
                        .delay(composer ? 0.08 : 0.10)),
                removal: .opacity.animation(.easeIn(duration: 0.10)))
        }
        return .asymmetric(
            insertion: .opacity.animation(.easeOut(duration: 0.30).delay(0.14)),
            removal: .opacity.animation(.easeIn(duration: 0.14)))
    }

    /// The one piece of glass both compact faces are drawn on.
    ///
    /// The composer and the answer are not two surfaces that trade places — they
    /// are ONE card whose contents are replaced. Three of its edges are the
    /// window's own 8pt margin and the fourth, the top, sits below the same
    /// transparent band in both states: on Enter nothing about this sheet moves
    /// except its bottom edge, which follows the window down as the answer
    /// arrives (`glideCompact`).
    ///
    /// The top edge used to RISE into the band as the card opened, taking the
    /// chips row and the card's whole top margin with it. That is a window
    /// changing shape, and it read as one — a second box appearing over the line
    /// just typed. The band stays.
    ///
    /// It is also the force-click cue: the press narrows this same sheet to the
    /// card's left cap and deepens its fill, and firing springs it back to full
    /// width (`openFromPressure`). One surface for the pointer thickening into an
    /// object, the composer it becomes, and the card that opens out of it.
    private var compactGlass: some View {
        let pressing = state.pressDepth != nil
        let depth = state.pressDepth ?? 1
        let shape = RoundedRectangle(cornerRadius: compactCornerRadius, style: .continuous)
        // The card's height while the disclosure is in flight — the reveal's own
        // value, minus the chrome this glass hangs below, so the veil's hem stays
        // on the card's bottom edge for every frame of the fold. `nil` at rest,
        // where the surface and the card are the same thing.
        let card = state.compactRevealHeight.map {
            max($0 - CompactShortcutMetrics.chrome, 0)
        }
        return CompactComposerGlass(shape: shape, cardHeight: card)
            // The fill deepens with the press and is fully there by the time the
            // stretch begins, so the shape stops changing character mid-flight.
            .overlay(shape.fill(Color.black.opacity(0.01 + 0.34 * (1 - depth))))
            // The slab's top sheen — the one thing the answer's glass carries
            // that the composer's does not. It fades in with the card rather
            // than arriving with a new surface behind it.
            .overlay {
                LinearGradient(colors: [.white.opacity(0.05), .white.opacity(0.0)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 90)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .blendMode(.plusLighter)
                    .clipShape(shape)
                    .opacity(isBareComposer ? 0 : 1)
            }
            // A rim while it is a cue — the pointer thickening into an object —
            // easing to the composer's own bare card as it opens, and coming
            // back as the window's hairline once it is a card.
            .overlay(shape.strokeBorder(
                Color.white.opacity(pressing ? 0.16 + 0.16 * depth : 0), lineWidth: 1))
            .overlay(shape.strokeBorder(Tokens.hairline, lineWidth: 1)
                        .opacity(isBareComposer ? 0 : 1))
            .frame(width: pressing ? CompactShortcutMetrics.capDiameter : nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The band this card hangs below — the same in both faces, so the
            // top edge is fixed and only the bottom one travels.
            .padding(.top, CompactShortcutMetrics.band + CompactShortcutMetrics.gap)
            .padding(CompactShortcutMetrics.inset)
    }

    /// The empty-prompt shortcut's composer: a band held clear on top, and the
    /// card.
    ///
    /// There is no "Using copied text" footnote under it any more. The window is
    /// only ever summoned ON a selection, so the badge said the one thing that
    /// was never in doubt — and it cost a whole band of height plus the beat of
    /// motion to bring it in. (Its × dropped the captured text, which went with
    /// it: an answer about nothing is not what anyone presses for.)
    private var compactComposerFace: some View {
        face
        // The space the caret reports its position in: this view fills the window's
        // content, so an offset measured here is an offset from the window's corner
        // (`CompactShortcutMetrics.caretOffset`).
        .coordinateSpace(.named(CompactShortcutMetrics.faceSpace))
    }

    /// The composer's drawn half — everything the entrance transform acts on.
    private var face: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Carries nothing — it holds the card's top edge where the answer
            // card's header will land, and the window is transparent, so an
            // empty band shows nothing at all. (The composer's own two chips
            // live INSIDE the card, on its first row: a control that acts on
            // the box has to sit on the box.)
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: CompactShortcutMetrics.band)
            compactBox
                .padding(.top, CompactShortcutMetrics.gap)
        }
        .padding(CompactShortcutMetrics.inset)
    }

    /// Straight to the page these buttons came from: Settings → Shortcuts, whose
    /// first group IS the prompt-shortcut list. The composer closes behind it —
    /// the settings panel opens at the notch, and leaving a floating box standing
    /// at the pointer over it is a second surface asking for the same attention.
    private func openShortcutSettings() {
        model.settingsSection = InlineSettingsView.Section.agent.rawValue
        NotificationCenter.default.post(name: .openSettingsRequested, object: nil)
        onClose()
    }

    /// Collapse the face to its seed and let it spring open. The collapsed state
    /// has to be drawn once before the spring, or a replay (same window, new
    /// pointer) would animate from the size it is already at — i.e. not at all.
    private func playEntrance() {
        guard !reduceMotion else { entered = true; return }
        entered = false
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                entered = true
            }
        }
    }

    /// The composer face's lower half: the instruction capsule. (The answer it
    /// becomes is no longer a box inside this frame — it is the window's own
    /// slab, see `compactShortcutFace`.)
    private var compactBox: some View { sessionBody }

    /// `glass: false` for the compact prompt-shortcut face, whose glass is the
    /// shared sheet underneath (`compactGlass`) — a slab of its own drawn here
    /// would be a second surface cross-fading over the one that is stretching.
    private func slab(corner: CGFloat, glass: Bool = true) -> some View {
        ZStack {
            if !isBareComposer {
                if glass { DetachedWindowGlass() }
            }
            // The full session from frame one — riding and settled look the
            // same; merging just dissolves on the way home.
            sessionBody
                .opacity(state.phase == .merging ? 0 : 1)
        }
        // An image opened out of this window's thread covers this window, not
        // the panel it was torn from — each surface hosts its own lightbox.
        .imageLightboxHost()
        // The glass carves the window's rounded form itself; the rim rides on
        // top of the clipped result so the edge highlight stays crisp.
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay {
            if !isBareComposer, glass {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(Tokens.hairline, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var sessionBody: some View {
        sessionContent
            // Same injection as the panel root (see `ContentView`): a detached
            // thread is the same answer in another window and must speak in the
            // same voice.
            //
            // Read from defaults rather than from `model.handwrittenAnswers`,
            // even though the model is right there: this view holds the model
            // *unobserved* on purpose (see the property above), so reading the
            // published value here would render the current setting once and then
            // never update — the toggle would appear to do nothing in an already
            // open window. `@AppStorage` invalidates on this one key only, which
            // keeps the "don't re-render a streaming thread on unrelated model
            // publishes" property that the plain reference exists to protect.
            .environment(\.handwritten, HandwritingFeature.isEnabled && handwrittenAnswers)
    }

    @ViewBuilder
    private var sessionContent: some View {
        if case .shortcutComposer = state.session {
            CompactShortcutPromptView(
                state: state,
                historyItems: model.forceTouchHistory,
                onSubmit: onCompactPrompt,
                onToggleHistory: onToggleForceTouchHistory,
                onOpenHistory: onOpenForceTouchHistory,
                onOpenSettings: openShortcutSettings,
                onDesiredHeight: liveHeight(from: state.session),
                onCaretOffset: onCaretOffset)
                .id(state.compactPromptGeneration)
        } else if state.session == .compose {
            DetachedComposeView(state: state, model: model, pinned: state.pinned,
                                onTogglePin: onTogglePin,
                                onClose: onClose, onSubmit: onCompose,
                                onDesiredHeight: onComposeHeight)
        } else if let taskID = state.session.taskID {
            DetachedAgentTaskView(taskID: taskID, pinned: state.pinned,
                                  onTogglePin: onTogglePin,
                                  onClose: onClose)
        } else if let threadStore = state.threadStore {
            DetachedThreadView(store: threadStore, pinned: state.pinned,
                               onTogglePin: onTogglePin,
                               onClose: onClose,
                               onInAppCopy: onInAppCopy,
                               onReplaceOriginal: onReplaceOriginal,
                               onFollowUp: onFollowUp,
                               onRegenerate: onRegenerate,
                               onRegenerateWith: onRegenerateWith,
                               onChooseOption: onChooseOption,
                               regenerateOptions: regenerateOptions,
                               compactShortcut: compactShortcut,
                               onDesiredHeight: liveHeight(from: state.session))
        }
    }

    /// A height report, honoured only while the face that sent it is still the
    /// one the window belongs to.
    ///
    /// Both compact faces report through the same channel, and the outgoing one
    /// stays in the tree for the whole cross-fade — by which time the window has
    /// ALREADY landed on the incoming face's height. So the leaving view re-lays
    /// itself out inside that new frame and dutifully reports what IT would like
    /// to be. Acted on, that hard-sets the window back to the height of the page
    /// being left, and the arriving page's own report then undoes it: the
    /// jump-and-return on the way out of a conversation, visible for exactly
    /// those entries whose card was a different height from the ledger.
    ///
    /// The session is captured when the branch builds its view, so it is the one
    /// that face belongs to for as long as that face exists.
    private func liveHeight(from session: DetachedSession) -> (CGFloat) -> Void {
        { [weak state] h in
            guard state?.session == session else { return }
            onThreadHeight(h)
        }
    }
}
