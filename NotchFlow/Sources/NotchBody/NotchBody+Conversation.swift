import SwiftUI
import AppKit

@MainActor
extension NotchBody {
    /// The whole conversation, scrolling: every user/assistant turn stacked, the
    /// newest at the bottom. Sizes to its content up to `answerMaxHeight`, then
    /// clips + scrolls; a `ScrollViewReader` keeps the latest turn pinned in view
    /// as a follow-up streams in. The bottom fade is the "more below" cue.
    var conversationScroll: some View {
        let clipped = isAnswerClipped
        return Group {
            if clipped {
                clippedConversation
            } else {
                // Unclipped, the thread IS its intrinsic height — this layout has
                // no ceiling anywhere (see `growingConversation`) — so the visible
                // tree doubles as the measurement and the hidden probe below stays
                // unmounted. This is the common case (most answers fit under
                // `answerMaxHeight`), and it used to pay a second full text layout
                // of the whole thread on every streamed flush just to feed the
                // `clipped` switch a number the visible layout already knew.
                growingConversation
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: AnswerHeightKey.self, value: geo.size.height)
                        }
                    )
            }
        }
        // Measure the thread's INTRINSIC height — what it wants to be with no ceiling
        // — to drive ONLY the `clipped` switch above. Each layout reports it from
        // the tree that's already on screen: unclipped, that's the visible stack
        // (above); clipped, it's the turn stack *inside* the ScrollView, which a
        // ScrollView already lays out at its full unconstrained height (see
        // `clippedConversation`). Measuring the clipped view from the OUTSIDE would
        // report the pinned 300 and flip-flop the switch on the boundary — which is
        // why this used to mount a whole hidden, `fixedSize`d second copy of the
        // turn stack here. That copy re-ran the entire thread's view build and text
        // layout on every mount, doubling the cost of opening a long agent record
        // for a number the live scroll content already knew.
        .onPreferenceChange(AnswerHeightKey.self) {
            // 0 means "the probe is unmounted" (suspended above, or a transient
            // empty pass) — never "the content shrank to nothing". Keep the last
            // real measurement so the clipped layout holds while suspended.
            guard $0 > 0 else { return }
            measuredAnswerHeight = $0
            // Mirror to the model (a plain var — no invalidation) so `fullClose`
            // can park the measurement with the session; the next mount seeds its
            // layout decision from it (see `init`).
            model.lastMeasuredAnswerHeight = $0
        }
        // The ONE place a height change is animated: the cross-over between the two
        // layouts (a short answer growing past the 300pt ceiling into the clipped
        // scroller). Critically damped (1.0) so it settles without the overshoot that
        // produced the per-line bounce; short so it stays tight. Within a single
        // layout there's no `.frame(height:)` to animate, so day-to-day streaming
        // growth carries no animation here at all — it just reflows.
        .animation(.spring(response: 0.3, dampingFraction: 1.0), value: clipped)
    }

    /// Short-answer layout: the thread sizes to its own content, NO ScrollView, NO
    /// fixed frame height. New lines extend the stack in the same layout pass they
    /// land — the height *is* the content height, so there's nothing lagging behind
    /// to jump. This is the common case (most answers fit under `answerMaxHeight`).
    private var growingConversation: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(model.turns.filter { !$0.hidesUserBubble }) { turn in
                turnView(turn)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(turn.id)
            }
        }
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Long-answer layout: once the thread outgrows `answerMaxHeight` it pins to
    /// `clippedAnswerMaxHeight` (363pt) and scrolls, with the follow-up input floating
    /// over the bottom. The taller frame absorbs the 24pt gap + 39pt input the sibling
    /// layout used, so the panel's total height is unchanged at the crossover.
    ///
    /// **Tail-follow geometry (why the runway sits ABOVE the anchor):**
    /// `scrollTo(scrollBottomID, anchor: .bottom)` aligns the anchor's BOTTOM edge with
    /// the viewport's bottom. If the runway were `.padding(.bottom)` (below the anchor),
    /// the anchor would land at the viewport bottom and the last turn would sit right
    /// at the bottom — hidden behind the floating input. Instead the runway is a Spacer
    /// placed IN the VStack ABOVE the anchor:
    ///     [last turn] [Spacer 62pt] [Color.clear 2pt .id(scrollBottomID)]
    /// so `anchor:.bottom` puts the anchor at the viewport bottom, the 62pt runway sits
    /// just above it, and the last turn rests ~64pt above the viewport bottom — 13pt
    /// above the input's top edge, entirely in the dissolve zone.
    private var clippedConversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Keep the conversation's inter-turn rhythm separate from the tail
                // geometry. If the runway and anchor live in the 16pt-spaced stack,
                // SwiftUI inserts spacing on BOTH sides of the runway, turning the
                // intended 64pt tail into 96pt and leaving an oversized blank band
                // above the composer when the reader pins to the bottom.
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(model.turns.filter { !$0.hidesUserBubble }) { turn in
                            turnView(turn)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(turn.id)
                        }
                    }
                    // The thread's intrinsic height, read off the live scroll
                    // content — a ScrollView proposes an unbounded height to its
                    // content, so this stack is already laid out at its full size
                    // and the `clipped` switch can be fed straight from it (no
                    // hidden second copy; see `conversationScroll`).
                    //
                    // Mounted only once the stream settles, same discipline the
                    // hidden probe kept: within one round the content only grows,
                    // so past the ceiling it can't change the decision, and the
                    // per-flush preference churn would be pure waste. It returns
                    // for the next change that CAN shrink the thread (a regenerate
                    // replacing a long answer, opening a shorter history thread).
                    .background(alignment: .top) {
                        if !model.isStreaming {
                            GeometryReader { geo in
                                Color.clear.preference(key: AnswerHeightKey.self,
                                                       value: geo.size.height)
                            }
                        }
                    }
                    // The bottom runway: empty scroll space the last turn slides DOWN
                    // into behind the floating follow-up input. Positioned HERE — above
                    // the anchor — so `scrollTo(anchor:.bottom)` leaves the last turn
                    // ~64pt above the viewport bottom (see the doc comment's geometry).
                    Spacer(minLength: 0)
                        .frame(height: clippedBottomRunway)
                    // The anchor the reader scrolls to so new turns always land in view.
                    // Sits at the very end of the runway, so anchor:.bottom clears the
                    // runway above it for the dissolve.
                    Color.clear.frame(height: 2).id(scrollBottomID)
                }
                .padding(.trailing, 8)
                // Top runway: the inset the first line rests at when scrolled fully
                // up, sized to the floating header block (`resultHeaderReach`) so it
                // sits just clear of the back/pin chrome — and the space mid-thread
                // text travels up into, dissolving (fade + frost) behind the header
                // instead of hard-cutting below it. The bottom has its own runway
                // Spacer inside the VStack (above), so no .padding(.bottom) is needed.
                .padding(.top, resultHeaderReach)
            }
            // Taller than `answerMaxHeight` (300): absorbs the 24pt gap + 39pt
            // follow-up row that no longer sit as VStack siblings, PLUS the floating
            // header block (`resultHeaderReach`, 44pt) the clipped layout lifts out
            // of the VStack flow — keeping the panel the same total height. The
            // `isAnswerClipped` threshold stays at 300.
            .frame(height: clippedAnswerMaxHeight + resultHeaderReach)
            // Sticky affordances inside the thread (a code block's copy button)
            // park below the floating header block instead of at the bare viewport
            // top, where the header and its dissolve would swallow them.
            .environment(\.stickyScrollTopInset, resultHeaderReach)
            .scrollIndicators(.never)
            // Submitting a follow-up appends two turns and flips mode
            // result→load→result, which rebuilds the ScrollView and resets its
            // offset to the top. Snap straight back to the bottom (no animation) so
            // there's no visible jump up — the streaming tail-follow below is what
            // gets the smooth motion.
            //
            // TWICE, on purpose. `onChange` runs while SwiftUI is still updating:
            // the ScrollView's content at that instant is the OLD, shorter thread,
            // so this first `scrollTo` clamps at the old maximum offset and stops
            // short of the real bottom. Normally the streaming tail-follow below
            // covers for it — but between submitting a follow-up and the first
            // token there IS no text change to fire it, so the clamp is exactly
            // what the reader is left staring at: the new question and its wait
            // row sitting half below the fold, with the thread refusing to scroll
            // down. The deferred pass runs after the appended turns have been laid
            // out, when the anchor can actually be reached.
            .onChange(of: model.turns.count) { _, _ in
                proxy.scrollTo(scrollBottomID, anchor: .bottom)
                DispatchQueue.main.async {
                    proxy.scrollTo(scrollBottomID, anchor: .bottom)
                }
            }
            // Follow the tail smoothly as the answer streams in, so the freshest
            // text stays in view without the user scrolling by hand.
            .onChange(of: model.turns.last?.text) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(scrollBottomID, anchor: .bottom)
                }
            }
            // An agent turn grows its work trail with the answer text still empty,
            // so the text-keyed follow above never fires for it — the trail would
            // extend down behind the composer unseen. Same tail, keyed on the log.
            .onChange(of: model.turns.last?.agentLog?.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(scrollBottomID, anchor: .bottom)
                }
            }
            // Entering the clipped layout (just crossed the ceiling) lands at the top
            // by default; pin to the bottom so the newest text stays in view. Same
            // pre-layout caveat as the turn-count follow above — a ScrollView on its
            // first appearance has no content height yet, so the immediate call can
            // only clamp; the deferred one lands it on the anchor.
            .onAppear {
                proxy.scrollTo(scrollBottomID, anchor: .bottom)
                DispatchQueue.main.async {
                    proxy.scrollTo(scrollBottomID, anchor: .bottom)
                }
            }
        }
        // Per-edge fades: each taper tracks its own runway. The top matches the
        // floating header block (`resultHeaderReach`, 44pt) so text dissolves to
        // nothing across the back/pin zone; the bottom matches its runway (62pt)
        // so the taper falls entirely across the empty space above the input box.
        .scrollEdgeFade(top: true, bottom: true, topFade: resultHeaderReach, bottomFade: clippedBottomRunway)
        // Progressive blur on the top runway, mirroring the immersive input header:
        // text scrolling up behind the back/pin chrome frosts out as it goes, so the
        // header zone reads as one continuous surface, not a hard cut. Band kept 4pt
        // shorter than the runway (`clippedTopBlurReach` = 40pt); maxRadius 22
        // matches the bottom band (comparably thin chrome, unlike the deep 36 the
        // immersive input header needs).
        //
        // …and the mirrored band on the bottom runway, so rows scrolling down
        // behind the input frost out the same way. Kept 4pt shorter than each
        // runway (`clippedTopBlurReach` = 40, `clippedBottomBlurReach` = 58) so a
        // band clears the nearest resting row — no halo at rest. maxRadius 22
        // matches the manage bar's chrome.
        //
        // ONE merged modifier, not `ConditionalTopBlur` + `ConditionalBottomBlur`
        // stacked: a progressive blur overlays a rebuilt copy of its content, so
        // the stacked pair instantiated the entire thread FOUR times (the bottom
        // one's content already being original + top-blur copy). On a long agent
        // record that quadrupled view build + text layout on the tap that opens
        // it — the stall. Merged, it's one copy, drawn identically. See
        // `ProgressiveEdgeBlur`.
        //
        // Both bands rest while the answer is still STREAMING: the copy is
        // `drawingGroup`-flattened and re-rasterizes whenever its content changes
        // — and a streaming thread changes on every ~33ms flush AND every frame of
        // the tail-follow scroll. The `scrollEdgeFade` opacity taper above stays on
        // throughout, so text still dissolves at both runways; the frost simply
        // joins when the stream settles and the content goes static.
        .modifier(ConditionalEdgeBlur(active: !model.isStreaming,
                                      topHeight: clippedTopBlurReach,
                                      bottomHeight: clippedBottomBlurReach,
                                      topRadius: 22))
    }

    /// One bubble in the thread. A user turn reads as a quiet, dimmer line tagged
    /// "You"; an assistant turn renders full markdown at body weight. A streaming
    /// assistant turn with no text yet shows the thinking dots, so the wait reads
    /// the same in a follow-up as it does on the first question.
    @ViewBuilder
    private func turnView(_ turn: NotchModel.Turn) -> some View {
        if turn.role == "user" {
            VStack(alignment: .leading, spacing: 5) {
                // Permanent clipboard trace: when this question's message was enriched
                // with what the user copied, a quiet line says so — sitting right above
                // the question bubble and staying for the life of the answer (unlike the
                // load-only "Using clipboard" cue). Indented to line up with the bubble's
                // text inset so it reads as a caption on this turn. `paperclip`-free on
                // purpose: one small grey line, same whisper as the note-save cue.
                // An image the turn rode in with outranks that line: the picture IS
                // the trace, and says what "based on what you copied" only describes.
                // Persisted with the thread, so a row reopened from Recent shows the
                // same screenshot the question was asked about.
                if !turn.imageFiles.isEmpty {
                    SavedTurnImages(files: turn.imageFiles)
                        .padding(.leading, 12)   // matches the bubble's horizontal inset
                } else if turn.usedClipboard {
                    Text(L("result.basedOnCopied"))
                        .font(.sf(11))
                        .tracking(0.2)
                        .foregroundStyle(Tokens.text4)
                        .padding(.leading, 12)   // matches the bubble's horizontal inset
                }
                // The user's question rides in a quiet chat bubble — a barely-there
                // tint with a hairline border — instead of a "You" label. The bubble
                // itself says "this is what you asked", so no tag is needed and the
                // thread reads cleaner. It hugs its content (not full width) and
                // left-aligns with the answer below.
                UserQuestionBubble(text: turn.text)
            }
        } else {
            // Assistant turn — streaming AND settled share ONE view tree, so the
            // moment the stream ends there's no structural swap to a different
            // renderer (that swap is what hard-cut the answer ~2pt up-left at
            // completion. `AssistantTurnView` always lays the
            // answer out through the same `MarkdownBlocks`, and only fades a
            // thinking/activity overlay on top while the text is still empty; the
            // overlay never participates in the answer's layout, so it can't shift
            // it, and `textSelection` just toggles on the unchanged tree.
            // Footer actions that only make sense at the thread's tail: regenerate
            // re-runs THIS question (and would orphan any later turns), and the
            // ChatGPT/Claude handoff always copies the whole thread — so both ride
            // only the last turn's footer, never mid-thread ones.
            let isLastTurn = model.turns.last?.id == turn.id
            // An agent run's report never offers regenerate: the chat model can't
            // re-run the task in its folder, so "regenerating" it would only
            // hallucinate a fresh report over the real one. (Chat follow-ups on
            // the same reopened thread aren't agent turns, so they keep it.)
            let canRegenerate = isLastTurn && !turn.isAgent
            VStack(alignment: .leading, spacing: 14) {
                // An agent answer carries its round's work trail above the report —
                // the record's copy of the live detail page, so a reopened run
                // reads the way the run looked while it worked.
                if turn.isAgent,
                   let trail = turn.agentLog?.droppingTrailingAnswer(turn.text),
                   !trail.isEmpty {
                    AgentWorkTrailView(entries: trail)
                }
                AssistantTurnView(
                    text: turn.text,
                    streaming: turn.streaming,
                    activity: turn.streaming
                        ? (turn.toolActivity ?? model.currentActivity) : nil,
                    orbState: turn.streaming
                        ? (turn.thinkingOrbState ?? model.thinkingOrbState) : .composing,
                    thinkingWord: turn.thinkingWord ?? model.currentThinkingWord,
                    thinkingSince: turn.streaming
                        ? (turn.thinkingStartedAt ?? model.thinkingStartedAt) : nil,
                    sources: turn.sources,
                    hoveredSourceID: $hoveredSourceID,
                    sourceCloseWork: $sourceCloseWork,
                    isAgent: turn.isAgent,
                    // The record's completion time, shown as the report footer's
                    // stamp — only on the last agent turn, so the single stored
                    // timestamp maps to exactly one report (a follow-up chat turn,
                    // being non-agent, never carries it).
                    completedAt: (turn.isAgent && isLastTurn) ? model.currentThreadCompletedAt : nil,
                    // The agent report's model + completion time live in the
                    // command chip beside the follow-up composer now, not in a
                    // second metadata line under the report.
                    showsFooterMetadata: !turn.isAgent,
                    onInAppCopy: { model.rebaselineClipboardAfterInAppWrite() },
                    onRegenerate: canRegenerate ? { model.regenerateLastAnswer() } : nil,
                    // Right-click the regenerate button to re-run this answer with a
                    // different model, once (XII-135). Only on the last turn (same gate
                    // as plain regenerate).
                    regenerateModels: canRegenerate ? model.regenerateModelOptions : [],
                    onRegenerateWith: canRegenerate ? { model.regenerateLastAnswer(model: $0) } : nil,
                    regenModel: turn.regenModel,
                    answerModel: turn.answerModel,
                    // The `ask_user` question card, when the model has paused this
                    // still-streaming answer on a choice only the user can make.
                    pendingQuestion: turn.streaming
                        ? (turn.pendingQuestion ?? model.pendingQuestion(for: turn.id)) : nil,
                    onChooseOption: { questionID, option in
                        model.chooseUserOption(option, questionID: questionID)
                    }
                )
            }
        }
    }

    // Back chevron leads (the question itself is the "You" turn below, so no title
    // here); a pin button trails top-right. Pinning holds the panel open when the
    // pointer leaves, so the answer can be read without hovering it (see
    // `NotchModel.collapseOnLeave`).
    /// Whether the result header's trailing chips (follow-up / detach / pin) are
    /// showing: only under the pointer, or while the answer is pinned — see the
    /// note at their use site.
    private var headerChipsShown: Bool { model.pointerInside || model.isAnswerPinned }

    var resultHeader: some View {
        HStack(spacing: 10) {
            backButton
            Spacer(minLength: 0)
            // A folded shortcut thread's follow-up entry: its own module, set
            // apart from the detach/pin pair by the header's wider 10pt gap.
            // Same species (one-segment `GlassSegmentCluster`), separate group —
            // it's a composer, not a view action, so it doesn't join their pair.
            Group {
                if followUpIsFolded {
                    followUpChip
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
                ResultTrailingCluster(
                    pinned: model.isAnswerPinned,
                    togglePin: {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                            model.toggleAnswerPin()
                        }
                    },
                    detach: { model.openDetachedWindow() }
                )
            }
            // These are buttons sitting on the header's tear-off grip, which pushes
            // the open-hand cursor for the whole strip — take the plain arrow back
            // over the glyphs so they say "click" rather than "pull".
            .arrowCursor()
            // Hover-only chrome: at rest the header carries nothing but the back
            // chevron, so an answer read from across the desk is just the answer.
            // The chips fade in the moment the pointer is on the island and fade
            // back out when it leaves. They keep their slot either way (opacity,
            // not removal), so nothing shifts as they appear.
            // A PINNED answer is the exception — the tack is the only thing saying
            // "this is staying open", and it earns its place with the pointer away.
            .opacity(headerChipsShown ? 1 : 0)
            .allowsHitTesting(headerChipsShown)
            .animation(.easeOut(duration: Tokens.hoverFade), value: headerChipsShown)
        }
        // The header's free strip doubles as the tear-off grip: drag the thread
        // out of the notch and it splits into its own window (see
        // `NotchModel.detachDragChanged`). Buttons keep their taps — the drag
        // only arms past its minimum distance — so the hand cursor covers the
        // whole strip, which is exactly how far the drag reaches.
        .contentShape(Rectangle())
        .grabCursor()
        .gesture(detachDragGesture)
    }

    /// The folded follow-up's entry point (shortcut threads only): one speech
    /// bubble in the header, standing apart from the detach/pin pair. Tapping it unfolds the real composer below, with the
    /// caret already in it.
    private var followUpChip: some View {
        GlassSegmentCluster(segments: [
            .init(tooltip: L("result.followUp"), action: {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                    followUpExpanded = true
                }
                // The field mounts with this tap; give it the caret without a
                // second click (the same drop-then-raise the clipped crossover
                // uses).
                refocusInput()
            }) {
                Image(systemName: "bubble.left")
                    .font(.sf(10.5, weight: .medium))
            }
        ], glass: false)
    }

    /// The tear-off drag: raw translation goes to the model, which arms the
    /// ghost card, stretches the membrane, and fires the split at the
    /// threshold. The gesture keeps delivering after the hand-off — the model
    /// ignores those ticks (`detachHandedOff`).
    var detachDragGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                model.detachDragChanged(value.translation)
            }
            .onEnded { _ in
                model.detachDragEnded()
            }
    }

    /// Back to a fresh conversation: clears this Q&A off the screen and returns to
    /// the idle prompt (panel stays open). Safe mid-answer — an in-flight stream
    /// finishes detached and lands in Recent (see `NotchModel.newChat`). Also bound
    /// to the ← arrow key (see ContentView's key handler), so a glance-and-go feels
    /// keyboard-native.
    var backButton: some View {
        GlassBackButton {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                model.newChat()
            }
        }
    }
}
