import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Thread scroll edge

/// Shared geometry for a headed thread scroll's soft edges. The conversation
/// runs up behind the header into a `runway` of empty inset, fading
/// (`scrollEdgeFade`) and frosting (`progressiveTopBlur`) as it goes — the same
/// dissolve the panel's immersive list uses, so overflowing content melts into
/// the glass instead of ending on a hard cut. The frost `band` stays shorter
/// than the runway so no resting row sits inside it and haloes (see
/// `ProgressiveTopBlur`). The BOTTOM edge is the exact mirror — same runway,
/// same band, `progressiveBottomBlur` — so a thread scrolled to its end melts
/// into the follow-up line the way it melts into the header, instead of the
/// hard cut the tear-off used to show there. Internal on purpose: the panel's
/// agent-detail page (NotchBody) is the same species and shares these numbers,
/// so the tear-off keeps the exact dissolve the panel showed.
enum ThreadScroll {
    static let runway: CGFloat = 28
    static let band: CGFloat = 22
    static let blurRadius: CGFloat = 16
}

/// The compact answer's laid-out content height, reported up from the probe
/// inside the thread's ScrollView.
///
/// `max`, NOT `value = nextValue()`: the probe is one contributor among the
/// siblings SwiftUI reduces over, and the ones that set nothing hand back the
/// default. A last-writer-wins reduce therefore delivered a flat **0** for
/// every compact answer (measured), so the window's "authoritative" measurement
/// never reached it at all and its whole height fell to the AppKit estimate
/// below — which is how a short answer ended up in a window a third empty.
private struct DetachedThreadContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
// MARK: - Thread window body

/// A detached chat thread: the conversation, writing itself live while its
/// round streams (fed by `DetachedThreadStore`), with one exit — hand the
/// session back to the notch.
struct DetachedThreadView: View {
    @ObservedObject var store: DetachedThreadStore
    var pinned: Bool
    var onTogglePin: () -> Void
    var onClose: () -> Void
    var onInAppCopy: () -> Void
    var onReplaceOriginal: (String) -> Bool
    var onFollowUp: (String, [NSImage]) -> Void
    var onRegenerate: () -> Void
    var onRegenerateWith: (String) -> Void
    var onChooseOption: (UUID, String) -> Void
    var regenerateOptions: () -> [(model: String, isCurrent: Bool)]
    var compactShortcut = false
    var onDesiredHeight: (CGFloat) -> Void = { _ in }

    @State private var followUp = ""
    @State private var followUpImages: [NSImage] = []
    @State private var hoveredSourceID: UUID?
    @State private var sourceCloseWork: DispatchWorkItem?
    @State private var metadataMenuOpen = false
    /// The WHOLE thread's laid-out height, mirrored out of the content probe
    /// below. `compactAnswerIsCapped` reads it: whether the card has stopped
    /// growing and handed the tail to its ScrollView is a property of the
    /// thread, not of the newest answer's text (see there).
    @State private var measuredContentHeight: CGFloat = 0

    private static let bottomID = "detached-thread-bottom"

    private var streaming: Bool { store.turns.contains { $0.streaming } }
    private var renderedTurns: [NotchModel.Turn] {
        store.turns.filter { !$0.hidesUserBubble }
    }
    private var latestAssistantTurn: NotchModel.Turn? {
        renderedTurns.last(where: { $0.role == "assistant" })
    }
    private var agentReport: NotchModel.Turn? {
        renderedTurns.last(where: { $0.role == "assistant" && $0.isAgent })
    }
    private var agentRunCaption: String? {
        guard let report = agentReport else { return nil }
        return AssistantTurnView.footerModelCaption(
            answerModel: report.answerModel, regenModel: report.regenModel)
    }
    private var hasAgentMetadata: Bool {
        agentRunCaption != nil || store.agentFolderPath != nil || store.completedAt != nil
    }
    /// ONE rhythm for every detached thread — a pointer-side prompt-shortcut
    /// answer and a torn-out session are the same view at two sizes, so they get
    /// the same runways, the same card padding, the same header and the same
    /// follow-up line. (The compact face used to run a second, tighter set of
    /// numbers — 0 card padding, 15/14 runways, no header, no follow-up — which
    /// is precisely what made it read as a different kind of window.)
    ///
    /// The top runway must clear the complete frost band; otherwise the first
    /// answer line rests inside the blur and looks clipped.
    ///
    /// **A runway is only worth its height on a window that has height to
    /// spare.** A torn-out session is a fixed 460pt frame the user resizes at
    /// will, so its threads scroll and the 28pt bands are free — they live in
    /// space the window already has. A pointer-side card is the opposite: it
    /// sizes ITSELF to its answer, so every point of runway is a point the
    /// window grows by. At 28+28 a two-line reply opened a card carrying 36pt of
    /// nothing between its action row and the follow-up capsule against 23 under
    /// the capsule — the bottom margin reading as a sag.
    ///
    /// So the compact card rests on the panel's own short-answer rhythm instead
    /// (`NotchBody.resultView`: header, an 18pt quiet gap, the thread, 24pt, the
    /// input). It is ONE rhythm, not a switch on whether the answer happens to
    /// fit: swapping the insets mid-answer relaid the card out underneath a
    /// window that was still gliding open, and AppKit tears the window down for
    /// exceeding its constraint passes when those two argue. A long answer
    /// scrolls under an 18pt taper instead of a 28pt one — the bands are sized
    /// to these gaps below, so nothing is ever frosted while at rest.
    private var scrollTopInset: CGFloat {
        compactShortcut ? Self.restingTopGap : ThreadScroll.runway
    }
    private var scrollBottomInset: CGFloat {
        compactShortcut ? Self.restingBottomGap : ThreadScroll.runway
    }
    /// The compact card keeps the panel's 18pt quiet gap above the thread and
    /// the detached window's short 8pt gap above the follow-up line. In the
    /// waiting state that separation keeps the lone thinking row from crowding
    /// the disabled composer; ordinary detached windows additionally carry the
    /// full `ThreadScroll.runway` below their content.
    static let restingTopGap: CGFloat = 18
    static let restingBottomGap: CGFloat = 0
    /// The panel's own rhythm — `NotchBody.panelPadding`, the SAME on all four
    /// sides, so the follow-up capsule sits as far from the bottom edge as it
    /// does from the sides and 15 reads concentric against the window's 30pt
    /// corner (`DetachedSessionRootView.cornerRadius`, the island's own radius).
    ///
    /// It used to run horizontal 20 / top 15 / bottom 14 here — three different
    /// numbers, none of them the panel's — which is exactly what made a detached
    /// window's margins read as a different species from the notch's: the
    /// follow-up line hung 20 from the sides but only 14 off the rounded bottom,
    /// so the corner curve ate the side gap and the row looked to sag.
    static let cardHorizontalPadding: CGFloat = NotchBody.panelPadding
    static let cardTopPadding: CGFloat = NotchBody.panelPadding
    static let cardBottomPadding: CGFloat = NotchBody.panelPadding
    /// The answer keeps its established reading inset; the tighter nested
    /// padding is local to the composer input treatment.
    static let compactCardPadding: CGFloat = 8
    /// The header pill's height (`GlassSegmentCluster` — a 26pt chip in 3pt of
    /// glass) and the follow-up row's, so the compact window can budget for the
    /// chrome it now carries (`CompactShortcutMetrics.answerChrome`).
    static let headerHeight: CGFloat = 32
    static let compactFollowUpGap: CGFloat = 8
    static let followUpGap: CGFloat = 8
    static let followUpHeight: CGFloat = 39
    /// The fade and frost bands are exactly the gaps the thread rests between —
    /// never deeper — so a card at rest is crisp edge to edge and only content
    /// that has actually travelled into a gap gets dissolved.
    /// The card's own insets for this face — the composer's on the compact one
    /// (see `compactCardPadding`), the panel's uniform inset everywhere else.
    private var cardHorizontal: CGFloat { Self.cardHorizontalPadding }
    /// The header row alone rides the compact card's tighter inset — those two
    /// marks are the composer's chips, in the composer's exact spot, and they
    /// may not move when Enter replaces what is under them. Prose does not
    /// inherit that: text at 8 from the rim reads as a card with no margins
    /// (which is what it looked like), so the reading column below keeps the
    /// panel's own `cardHorizontalPadding` in both faces.
    private var headerHorizontal: CGFloat {
        compactShortcut ? Self.compactCardPadding : Self.cardHorizontalPadding
    }
    /// The follow-up capsule rides the tighter inset too — it IS the composer's
    /// own input capsule, in the composer's own spot, so it stands as close to
    /// the card's sides as that one does. Only the prose between them is held at
    /// the reading margin.
    private var followUpHorizontal: CGFloat { headerHorizontal }
    private var cardTop: CGFloat {
        compactShortcut ? Self.compactCardPadding : Self.cardTopPadding
    }
    private var cardBottom: CGFloat {
        compactShortcut ? Self.compactCardPadding : Self.cardBottomPadding
    }
    private var topFade: CGFloat { scrollTopInset }
    private var bottomFade: CGFloat { scrollBottomInset }
    private var topBand: CGFloat { min(ThreadScroll.band, scrollTopInset) }
    private var bottomBand: CGFloat { min(ThreadScroll.band, scrollBottomInset) }

    /// The window height a compact card wants for a turn stack this tall — the
    /// one place that arithmetic lives, so the height the window is set to and
    /// the layout inside it can never disagree.
    private func compactWindowHeight(forContentHeight bare: CGFloat) -> CGFloat {
        Self.compactWindowHeight(forContentHeight: bare)
    }

    /// The same arithmetic without a mounted view, so the controller can open a
    /// REOPENED thread straight at the height its answer needs instead of
    /// collapsing to the waiting floor and growing back out of it. Only ever
    /// asked about the compact face, whose runways are exactly these gaps.
    static func compactWindowHeight(forContentHeight bare: CGFloat) -> CGFloat {
        bare + restingTopGap + restingBottomGap
            + compactCardPadding * 2
            + CompactShortcutMetrics.answerChrome
    }
    /// What the answer footer adds under the prose: 6pt of stack spacing, the
    /// row's 2pt top inset, and a 22pt icon frame. Only the AppKit text estimate
    /// needs this — the SwiftUI probe measures the footer along with everything
    /// else in the turn stack — and the estimate is a floor, so the badge-led
    /// row's slightly taller lead-in is safe to round down to.
    private static let compactFooterHeight: CGFloat = 30
    private var latestAnswerText: String {
        latestAssistantTurn?.text
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    /// Has this thread ever written anything? The FIRST round's wait is the one
    /// case where the card must not move — it opens once, to its floor, and the
    /// orb sits in it. Every round after that is a follow-up: the question
    /// bubble and the wait row under it are real content arriving in a card
    /// that is already open, and the card has to make room for them AS THEY
    /// ARRIVE. Gating the height report on the LATEST answer instead meant a
    /// follow-up reported nothing at all while it thought (the new assistant
    /// turn is empty until the first token), so the box stayed exactly as tall
    /// as it was and the new question pushed the follow-up capsule out through
    /// its own bottom edge.
    private var hasAnswered: Bool {
        renderedTurns.contains {
            $0.role == "assistant"
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
    private var hasPendingQuestion: Bool {
        store.turns.contains { $0.streaming && $0.pendingQuestion != nil }
    }
    // The panel body's exact rhythm (NotchBody: a uniform 15pt inset, header then
    // an 18pt quiet gap, turns at 14pt spacing) — so the first frame after the
    // tear lays out where the panel's last frame did, and the question bubble is
    // the title; the header carries no text of its own.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, headerHorizontal)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(renderedTurns) { turn in
                            turnView(turn)
                        }
                        Color.clear.frame(height: 1).id(Self.bottomID)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // A ScrollView otherwise accepts the viewport's finite height
                    // proposal and the probe below only reports that clipped box.
                    // Ask for the stack's ideal vertical size so the probe sees the
                    // complete laid-out answer, including lines below the fold.
                    .fixedSize(horizontal: false, vertical: true)
                    // Measured BARE — inside the gaps, not around them — so the
                    // window's height is built from the turn stack plus whichever
                    // gaps this face rests it between (`compactWindowHeight`),
                    // rather than from a number that already has one pair baked in.
                    .background(GeometryReader { geo in
                        Color.clear.preference(
                            key: DetachedThreadContentHeightKey.self,
                            value: geo.size.height)
                    })
                    // The gaps rows rest between and then scroll away into — up
                    // behind the header, down behind the input — fading and
                    // frosting out on both edges. A session window can afford
                    // the full 28pt runways; the compact card pays for them in
                    // its own height, so it rests on the panel's short rhythm
                    // (see `scrollTopInset`).
                    .padding(.top, scrollTopInset)
                    .padding(.bottom, scrollBottomInset)
                }
                .scrollIndicators(.automatic)
                // Sticky affordances inside the thread (a code block's copy
                // button) park below the top fade band, not in it.
                .environment(\.stickyScrollTopInset, topFade)
                .scrollEdgeFade(top: true, bottom: true,
                                topFade: topFade, bottomFade: bottomFade)
                // ONE merged pass, not the two stacked modifiers — see
                // `ProgressiveEdgeBlur`: stacking them rebuilds the whole thread
                // four times over on mount.
                .progressiveEdgeBlur(top: topBand, bottom: bottomBand,
                                     topRadius: ThreadScroll.blurRadius)
                // The fade/blur modifiers render copies of the scroll surface.
                // Clip the composed result at the viewport itself so those
                // layers cannot follow a live scroll into the transparent bands
                // around the compact card.
                .clipped()
                // A follow-up appends two turns at once — the question bubble
                // and the empty assistant turn waiting under it. Neither carries
                // any text, so the tail-follow below (keyed on the answer's
                // characters) cannot fire for them: a capped card left the new
                // question below the fold, behind the composer, until the first
                // token finally landed. Follow the tail on the append itself.
                //
                // TWICE, on purpose: `onChange` runs while SwiftUI is still
                // updating, so the ScrollView's content at that instant is the
                // OLD, shorter thread and this first `scrollTo` can only clamp at
                // the old maximum offset. The deferred pass runs once the
                // appended turns have been laid out, when the anchor can actually
                // be reached. (Same shape as the panel's own result view.)
                .onChange(of: store.turns.count) { _, _ in
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                    DispatchQueue.main.async {
                        proxy.scrollTo(Self.bottomID, anchor: .bottom)
                    }
                }
                .onChange(of: store.turns.last?.text.count ?? 0) { _, _ in
                    guard streaming else { return }
                    // The compact window opens to fit its answer, so there is
                    // nothing to follow until the answer outgrows the cap —
                    // and following the few points the waiting orb overflows a
                    // still-closed box would nudge the first line up exactly as
                    // it lands.
                    if compactShortcut, !compactAnswerIsCapped { return }
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
                // Regular detached threads append their footer on settle. At the
                // ceiling it lands below the fold, so follow their tail once more
                // after layout. A compact answer carries its footer from the first
                // token (`stabilizesFooterWhileStreaming`), so settling adds no
                // height there and the tail is already where the reader left it.
                .onChange(of: streaming) { _, nowStreaming in
                    guard !nowStreaming else { return }
                    guard !compactShortcut else { return }
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(Self.bottomID, anchor: .bottom)
                        }
                    }
                }
            }
            .padding(.horizontal, cardHorizontal)
            // Every detached thread can be continued where it stands — a
            // pointer-side answer no longer dead-ends at "copy it or close it".
            followUpRow
                .padding(.horizontal, followUpHorizontal)
                .padding(.top, compactShortcut ? Self.compactFollowUpGap
                                               : Self.followUpGap)
        }
        .padding(.top, cardTop)
        .padding(.bottom, cardBottom)
        .onPreferenceChange(DetachedThreadContentHeightKey.self) { measured in
            guard compactShortcut, measured > 0 else { return }
            // Recorded BEFORE the wait gate below: `compactAnswerIsCapped` must
            // know how tall the thread stands even in the rounds this view
            // deliberately declines to resize the window for.
            measuredContentHeight = measured
            // A wait is not a reason to move a window: the waiting card opens
            // once, to its own floor (`compactInitialHeight`), and only the
            // answer grows it past that (`compactFloorHeight`). That holds for
            // the FIRST round only — see `hasAnswered`.
            guard hasAnswered || hasPendingQuestion else { return }
            // The turn stack — footer included, it is part of the answer — plus
            // the gaps it rests between, the card's own padding, and the window
            // chrome an answered shortcut carries: the margins, the header and
            // the follow-up row.
            onDesiredHeight(max(compactWindowHeight(forContentHeight: measured),
                                estimatedCompactWindowHeight(for: latestAnswerText)))
        }
        .onChange(of: latestAnswerText) { _, answer in
            guard compactShortcut, !answer.isEmpty else { return }
            // The AppKit estimate is an independent backstop for streaming
            // Markdown. It changes at the exact character edge, so the window can
            // grow even if SwiftUI coalesces or constrains a geometry preference.
            onDesiredHeight(estimatedCompactWindowHeight(for: answer))
        }
        .onAppear {
            guard compactShortcut, !latestAnswerText.isEmpty else { return }
            onDesiredHeight(estimatedCompactWindowHeight(for: latestAnswerText))
        }
        // The hovered source badge's popup, floated at the window level — outside
        // the thread's ScrollView, which would otherwise clip it. Without this the
        // badge in a detached window published its anchor to nobody: the pill sat
        // there and hovering it did nothing at all. Same modifier the panel uses.
        .sourcePopoverOverlay(hoveredID: $hoveredSourceID, closeWork: $sourceCloseWork)
    }

    /// The thread has outgrown the window's ceiling — past here the window stops
    /// opening and the ScrollView takes over, which is the only point at which a
    /// compact answer needs its tail followed.
    ///
    /// Measured off the THREAD, not the newest answer. The AppKit estimate alone
    /// asks "would this one answer's prose fill a whole 520pt window?", which in
    /// a follow-up round is answered by an assistant turn that is still empty —
    /// so a second question landing in an already-capped card followed nothing at
    /// all, and the new bubble plus its wait row sat below the fold behind the
    /// composer. The content probe reports the complete stack (every turn, both
    /// bubbles of every round), so it knows what the estimate cannot. The
    /// estimate stays as the streaming backstop it was, for the beat before a
    /// geometry pass lands.
    private var compactAnswerIsCapped: Bool {
        max(compactWindowHeight(forContentHeight: measuredContentHeight),
            estimatedCompactWindowHeight(for: latestAnswerText))
            > DetachedSessionWindowController.compactMaxHeight
    }

    /// Estimate the rendered prose at the compact window's real text width. The
    /// SwiftUI content probe above is authoritative; this is only a floor for the
    /// streamed case, where a geometry report can be coalesced or arrive a beat
    /// late — so it must never come out ABOVE the real layout, or the window
    /// wears the difference as dead space (growth here is one-way within a round,
    /// see `resizeCompactThread`).
    ///
    /// It measures the answer ONE LINE PER BLOCK. `MarkdownParser.plainText` is
    /// the clipboard serialization: it joins every block — each bullet of a list
    /// included — with a BLANK line, which the renderer never draws (blocks sit
    /// 8pt apart, see `MarkdownBlocks`). Measuring that text charged a phantom
    /// line per bullet: a six-bullet answer measured 480pt against a real 367pt.
    private func estimatedCompactWindowHeight(for answer: String) -> CGFloat {
        guard compactShortcut else { return 0 }
        return Self.estimatedCompactWindowHeight(for: answer)
    }

    /// The view-free form of that estimate — what a saved answer will need once
    /// it is laid out in this window (see `openForceTouchHistoryThread`).
    static func estimatedCompactWindowHeight(for answer: String) -> CGFloat {
        let plain = MarkdownParser.plainText(answer)
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        // Nothing written yet: the waiting card's own floor governs (see
        // `compactInitialHeight`) — this estimate has nothing to say yet.
        guard !plain.isEmpty else { return 0 }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 15 * 0.45
        let bounds = (plain as NSString).boundingRect(
            with: NSSize(width: Self.compactAnswerTextWidth,
                         height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [
                .font: NSFont.systemFont(ofSize: 15),
                .paragraphStyle: paragraph,
            ])
        // Same arithmetic the real measurement goes through (chrome, card
        // padding, and whichever pair of gaps the stack rests between) — the two
        // must agree on the rhythm, or the backstop would ask for a scrolling
        // card's height while the layout is resting and the window would wear
        // the difference as dead space.
        return compactWindowHeight(
            forContentHeight: ceil(bounds.height) + compactFooterHeight
        )
    }

    /// The width the answer's prose actually wraps at: the compact window, less
    /// the face's margins and the card's own horizontal padding. Measured at the
    /// widest a compact window gets (a shortcut that opens straight into an
    /// answer). A card that grew out of the composer is narrower, so the same
    /// text wraps to MORE lines there than this predicts — which is the safe
    /// direction: this number is only ever a floor (see above).
    private static let compactAnswerTextWidth: CGFloat =
        DetachedSessionWindowController.compactWidth
            - CompactShortcutMetrics.inset * 2 - cardHorizontalPadding * 2

    /// The same follow-up line the panel's result view carries — a submit here
    /// runs the round through the panel pipeline, headless (see
    /// `NotchModel.submitDetachedFollowUp`), and streams back into this window.
    /// Disabled while a round streams: the tear-off dropped the round's task
    /// handle, so a mid-stream line couldn't supersede it.
    private var followUpRow: some View {
        // THE panel's composer, not a copy of it: `ComposerBox` is the same box
        // the notch's own follow-up line is, down to the growing silhouette, the
        // focus-lit recess and the glass `SendButton` — a torn-off session is
        // the same conversation in a bigger frame, so its input can't be a
        // different control. (It used to be a single-line SwiftUI `TextField` on
        // a flat, never-lit `Capsule`: it couldn't grow with a wrapped line and
        // its placeholder sat under composing pinyin.)
        VStack(alignment: .leading, spacing: 8) {
            if !followUpImages.isEmpty {
                ComposeImagesAttachedLine(images: followUpImages) { index in
                    guard followUpImages.indices.contains(index) else { return }
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                        followUpImages.remove(at: index)
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 6) {
                ComposerBox(
                    text: $followUp,
                    onSubmit: sendFollowUp,
                    onPasteImage: pasteFollowUpImage,
                    placeholder: { Text(L("result.followUp")) },
                    trailing: {
                        if hasFollowUpInput {
                            SendButton(compact: true, action: sendFollowUp)
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
                        }
                    })
                    .opacity(streaming ? 0.45 : 1)
                    .disabled(streaming)

                if hasAgentMetadata {
                    GlassIconButton(systemName: "command", help: L("agent.detail"),
                                    size: 39, glyphSize: 13,
                                    showsTooltip: false) {
                        metadataMenuOpen.toggle()
                    }
                    .modifier(MenuCardWindow(
                        open: metadataMenuOpen,
                        upperLeading: true,
                        onDismiss: { _ in metadataMenuOpen = false },
                        card: {
                            AnyView(AgentRunMetadataMenu(
                                engine: agentRunCaption,
                                folderPath: store.agentFolderPath,
                                completedAt: store.completedAt,
                                onOpenFolder: {
                                    metadataMenuOpen = false
                                    if let path = store.agentFolderPath {
                                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                                    }
                                })
                                .manageMenuCardBackground())
                        }))
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.78),
                   value: hasAgentMetadata)
    }

    private func sendFollowUp() {
        var line = followUp.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = followUpImages
        guard !streaming else { return }
        if line.isEmpty {
            guard !images.isEmpty else { return }
            line = NotchModel.agentImageOnlyPrompt(count: images.count)
        }
        followUp = ""
        followUpImages = []
        onFollowUp(line, images)
    }

    private var hasFollowUpInput: Bool {
        !followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !followUpImages.isEmpty
    }

    private func pasteFollowUpImage() -> Bool {
        guard store.followUpSupportsImages,
              let image = NotchModel.pasteboardImage() else { return false }
        guard followUpImages.count < NotchModel.composeImageLimit else { return true }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            followUpImages.append(image)
        }
        return true
    }

    /// One header for every detached thread, pointer-side shortcut answers
    /// included: the window's own actions — pin, close — as two bare glyphs on
    /// the trailing edge, and nothing else. Content
    /// actions — copy, plain copy, regenerate, ⓘ — never live here; they belong
    /// to the answer and ride its footer (`AssistantTurnView`). The compact face
    /// used to float a copy+pin pill outside the card instead, which put the
    /// same copy button in two different places in two windows.
    private var header: some View {
        HStack(spacing: 10) {
            // Width only. A `maxHeight: .infinity` here makes the header row
            // itself greedy, and in a VStack against a ScrollView the two split
            // the window between them — the card opened with a band of nothing
            // above the answer and the pin/close marks floating in its middle.
            // The row is exactly `headerHeight`, which is also what the window's
            // height arithmetic budgets for it (`CompactShortcutMetrics
            // .answerChrome`), so the two can't disagree.
            Color.clear
                .frame(maxWidth: .infinity)
            // On the compact face this row is empty on purpose: its two marks
            // are the composer's, still standing where the composer left them
            // (`DetachedSessionRootView.compactChips`).
            if !compactShortcut {
                WindowTrailingCluster(pinned: pinned, togglePin: onTogglePin,
                                      close: onClose)
            }
        }
        .frame(height: Self.headerHeight)
    }

    private func replaceLatestAnswer() -> Bool {
        let answer = latestAnswerText
        guard !answer.isEmpty else { return false }
        return onReplaceOriginal(answer)
    }

    @ViewBuilder
    private func turnView(_ turn: NotchModel.Turn) -> some View {
        if turn.role == "user" {
            VStack(alignment: .leading, spacing: 5) {
                if !turn.imageFiles.isEmpty {
                    SavedTurnImages(files: turn.imageFiles)
                        .padding(.leading, 12)
                } else if turn.usedClipboard {
                    Text(L("result.basedOnCopied"))
                        .font(.sf(11))
                        .tracking(0.2)
                        .foregroundStyle(Tokens.text4)
                        .padding(.leading, 12)
                }
                UserQuestionBubble(text: turn.text)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if let log = turn.agentLog?.droppingTrailingAnswer(turn.text), !log.isEmpty {
                    AgentWorkTrailView(entries: log)
                }
                assistantTurn(turn)
            }
        }
    }

    /// The panel's full answer view — wait line, sources badge, and the settled
    /// footer (copy · plain copy · regenerate · model ⓘ) — so the torn-out
    /// thread keeps every action the panel offers. Regenerate belongs only to the
    /// last answer and stays disabled while that answer is still streaming.
    private func assistantTurn(_ turn: NotchModel.Turn) -> some View {
        let isLastTurn = store.turns.last?.id == turn.id
        let canRegenerate = isLastTurn && !turn.isAgent
        return AssistantTurnView(
            text: turn.text,
            streaming: turn.streaming,
            activity: turn.toolActivity,
            orbState: turn.thinkingOrbState ?? .composing,
            thinkingWord: turn.thinkingWord ?? "",
            thinkingSince: turn.streaming ? turn.thinkingStartedAt : nil,
            sources: turn.sources,
            hoveredSourceID: $hoveredSourceID,
            sourceCloseWork: $sourceCloseWork,
            isAgent: turn.isAgent,
            completedAt: (turn.isAgent && isLastTurn) ? store.completedAt : nil,
            // Compact shortcut answers carry the footer too now — copy lives
            // with the answer in every window, not on a pill beside one of them.
            // It rides UNDER the answer, in the scroll, in every face; the compact
            // card only shows it earlier (see `stabilizesFooterWhileStreaming`).
            showsFooter: true,
            stabilizesFooterWhileStreaming: compactShortcut,
            showsFooterMetadata: !turn.isAgent,
            onInAppCopy: onInAppCopy,
            onRegenerate: canRegenerate ? onRegenerate : nil,
            regenerateModels: canRegenerate ? regenerateOptions() : [],
            onRegenerateWith: canRegenerate ? onRegenerateWith : nil,
            regenModel: turn.regenModel,
            answerModel: turn.answerModel,
            pendingQuestion: turn.streaming ? turn.pendingQuestion : nil,
            onChooseOption: onChooseOption
        )
    }
}
