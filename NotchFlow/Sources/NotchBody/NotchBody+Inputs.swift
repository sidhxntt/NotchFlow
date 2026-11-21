import SwiftUI
import AppKit

@MainActor
extension NotchBody {
    // MARK: - Inputs

    /// The prompt's type size, and the follow-up field's — shared by the field, its
    /// inline hint and the row metrics, so a one-line box and its row agree.
    static let idleFontSize: CGFloat = 16.5
    static let followUpFontSize: CGFloat = 14.5
    /// How far a prompt grows before it stops growing and scrolls inside itself. A
    /// pasted paragraph unfolds the box downward — five lines of it — rather than
    /// scrolling off to the right where all but the tail is invisible.
    static let promptMaxLines = 5
    /// The idle row at rest: a one-line prompt in a 48pt row. As the box grows the
    /// row keeps exactly that breathing room above and below.
    static let idleRowHeight: CGFloat = 48
    /// The one curve a prompt wrap moves on — box, the chrome below it, and the
    /// island's shell/glass/clip, all from the single `withAnimation` in
    /// `onHeightChange`. Noticeably quicker than the panel's module spring (0.42):
    /// a wrap fires mid-keystroke and more characters are already landing, so a
    /// long, soft settle reads as the panel breathing a beat behind your typing.
    /// High damping because this must never overshoot — an undershoot would clip a
    /// line of text that is already on screen.
    static let promptGrowth: Animation = .spring(response: 0.22, dampingFraction: 0.9)
    /// A follow-up box at rest: one 27pt line in 6pt of padding.
    static let followUpRowHeight: CGFloat = 39
    /// A composer box's silhouette at a given height — a true pill on its resting
    /// line, and *the same corner* once the draft wraps.
    ///
    /// It cannot stay a `Capsule`. A capsule's radius is half its height, so a
    /// five-line box rounds at ~53pt while its text sits 15pt off the leading
    /// edge — the corner curve then bites through the first and last lines and
    /// `clipShape` cuts their opening glyphs away. Freezing the radius at the
    /// resting half-height leaves the one-line box pixel-identical and keeps
    /// every wrapped line clear of the curve.
    static func composerShape(height: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: min(height, followUpRowHeight) / 2,
                         style: .continuous)
    }
    private var idleRowVerticalPadding: CGFloat {
        NotchBody.idleRowHeight - PromptField.lineHeight(for: NotchBody.idleFontSize)
    }

    /// What trails the caret in the idle prompt — one slot, two tenants.
    ///
    /// A capture line names its leaf as you type: the same date read that decides
    /// whether Enter files this into Notes or Reminders (`captureLeaf`), spelled
    /// out beside the text, so typing a time into a line visibly turns it into a
    /// reminder instead of that split happening in silence. Before there is a line
    /// to read, a hand-typed `:` still explains the mode it pinned. Ask carries
    /// nothing — the pill on the row below already says Ask.
    private var trailingModeHint: (text: String, tint: Color)? {
        if let leaf = model.captureLeaf, let word = model.captureLeafLabel {
            return (word, leaf == .reminder ? Tokens.reminderInk : Tokens.noteInk)
        }
        if model.typedNoteModeActive {
            return ("You are using Note mode", Tokens.noteInk)
        }
        return nil
    }

    func inputRow(placeholder: String, followUp: Bool) -> some View {
        let fontSize: CGFloat = followUp ? NotchBody.followUpFontSize : NotchBody.idleFontSize
        let trailingHint = followUp ? nil : trailingModeHint
        return HStack(spacing: 12) {
            // The field and its fading placeholder. Where Enter sends the line is
            // spelled out by the destination pill on the row below, not by anything
            // trailing the caret.
            ZStack(alignment: .leading) {
                PromptField(
                    text: $model.text,
                    // Idle prompt: the native NSTextField placeholder HARD-SWAPS
                    // (zero animation) — deleting the last character popped
                    // "Type anything…" in on a cut. Keep it empty and draw the
                    // placeholder as the SwiftUI label below, which fades — the
                    // same ownership trick `followUpRow` uses. The defensive
                    // followUp branch keeps the native one (that path is unused).
                    placeholder: followUp ? placeholder : "",
                    fontSize: fontSize,
                    focusTrigger: focused,
                    maxVisibleLines: NotchBody.promptMaxLines,
                    // Enter routes by intent (ask / note / remind) from the idle
                    // prompt. The real mid-thread field is `followUpRow`, which now
                    // also routes by intent; this `followUp` branch is only the
                    // defensive path if `inputRow` is ever reused with `followUp: true`,
                    // and it keeps the plain-ask behaviour for that unused case.
                    onSubmit: { followUp ? model.submit() : model.submitCurrent() },
                    // Idle prompt only: ↑/↓ are shared between shell-style recall
                    // (fill the box with a past question) and the recent list, with
                    // a fixed precedence — an open, highlighted list owns the keys;
                    // recall gets them otherwise. ↓ first steps a live recall back
                    // toward the newest (clearing past the newest), and only when no
                    // recall is in flight does it open/step the recent list. Enter
                    // opens a keyboard-highlighted row instead of submitting. The
                    // follow-up field leaves these at their no-op defaults.
                    onDown: followUp ? { false } : {
                        // An open `/` menu owns the arrows before anything else —
                        // they walk its rows.
                        if model.slashMenuStep(1) { return true }
                        if model.recallNextQuestion() { return true }
                        return withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                            model.historyNavigateDown()
                        }
                    },
                    // ↑ mirrors ↓'s split, list side first: while a recent row is
                    // keyboard-highlighted, ↑ steps the highlight up (and past the
                    // top row folds the list back to the input — the exact inverse
                    // of the ↓ that opened it). Only with no highlight to walk does
                    // ↑ fall through to shell-style recall.
                    onUp: followUp ? { false } : {
                        if model.slashMenuStep(-1) { return true }
                        let steppedList = withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                            model.historyNavigateUp()
                        }
                        if steppedList { return true }
                        return model.recallPreviousQuestion()
                    },
                    // Keep ↑/↓ routed to recall even after the box fills with a
                    // recalled question, so pressing ↑ again steps further back
                    // instead of moving the caret.
                    // While `/` has the menu up, ↑/↓ belong to its rows even
                    // though the field holds text.
                    isMenuOpen: followUp ? { false } : { model.slashMenuOpen },
                    isRecalling: followUp ? { false } : { model.isRecallingHistory },
                    onSubmitNav: followUp ? { false } : {
                        // Enter lands the highlighted `/` command — the word in the
                        // box IS the command, never a question to send.
                        if withAnimation(.spring(response: 0.34, dampingFraction: 0.82), {
                            model.confirmSlashCommand()
                        }) { return true }
                        // Otherwise Enter confirms a keyboard-highlighted Recent row,
                        // which short-circuits the empty submit.
                        return model.historyConfirmHighlighted()
                    },
                    // Tab steps where Enter sends this line (Ask → Note →
                    // Remind →…) when the classifier guessed wrong — the pill
                    // below steps with it. Agent is NOT a stop (the pill's other
                    // half owns that switch). It works on the EMPTY prompt too: the
                    // mode is picked before the line is typed, exactly like a `/`
                    // command, and the placeholder ("Write a note…") says which
                    // one is armed. Always consumed either way, so focus never
                    // wanders out of the prompt.
                    onTab: followUp ? { false } : {
                        guard let event = NSApp.currentEvent,
                              ReservedAppShortcut.cycleIntent.matches(event) else {
                            return false
                        }
                        // Tab picks the highlighted `/` row too — the completion
                        // key doing the completing, before the cycle gets a turn.
                        if withAnimation(.spring(response: 0.34, dampingFraction: 0.82), {
                            model.confirmSlashCommand()
                        }) { return true }
                        model.toggleSubmitPanel()
                        return true
                    },
                    // Agent is selected only from its dedicated workspace tab,
                    // never as a hidden alternate mode inside Chat.
                    onBackTab: nil,
                    // ⌘V explicitly attaches a clipboard image to the current Ask
                    // or Agent compose. Ordinary text keeps the native paste path.
                    onPasteImage: followUp ? { false } : {
                        model.handleComposePasteImage()
                    },
                    // A directly typed colon / double-quote in the first
                    // position pins Note while leaving the glyph in the line.
                    // Paste / restored text never reaches this callback.
                    onInitialNoteTrigger: followUp ? { _ in } : { trigger in
                        guard model.turns.isEmpty else { return }
                        model.activateTypedNoteMode(trigger: trigger)
                    },
                    // Live width of the last line's committed text + any composing
                    // pinyin — what the overlay placeholder watches so it clears the
                    // instant the editor shows anything. Only the idle prompt feeds
                    // this; `followUpRow` owns its own tracking.
                    onCaretWidth: followUp ? { _ in } : { caretWidth = $0 },
                    onCaretY: followUp ? { _ in } : { caretY = $0 },
                    // The box's own height — one line, or as many as the text has
                    // wrapped to (capped). The row is built around it.
                    //
                    // The write is wrapped in an explicit transaction, and that is
                    // load-bearing: it arrives from an AppKit callback (the field's
                    // layout report), which carries no transaction of its own, so
                    // SwiftUI treats the resulting layout as un-animated and every
                    // view that MOVES because the row got taller — the bucket row
                    // under it, the island's frame, its glass background and its
                    // clip shape — hard-cuts a full line's height in a single frame.
                    // (Measured off a screen recording: 37pt in one frame, zero
                    // intermediate frames, while the text inside the box eased —
                    // the two halves of one growth on two different clocks, which is
                    // exactly what read as the panel jumping mid-typing.) Scoped
                    // `.animation(…, value:)` modifiers can't rescue that, on the row
                    // or on the island: they pick the curve for a change SwiftUI has
                    // already decided to animate, they don't turn a snap into one.
                    // Owning the transaction here does, for the whole tree at once.
                    onHeightChange: followUp ? { _ in } : { h in
                        guard h != inputHeight else { return }
                        withAnimation(NotchBody.promptGrowth) { inputHeight = h }
                    }
                )
                .frame(height: followUp ? nil : inputHeight)
                // The one trailing slot beside the caret — the position the old
                // routing hint occupied. In Capture it reads the leaf live; on a
                // bare typed `:` it explains the mode that glyph just pinned.
                .padding(.trailing, trailingHint.map {
                    InlineModeHint.reservedTrailingWidth(text: $0.text, fontSize: fontSize)
                } ?? 0)
                .background {
                    if let trailingHint {
                        GeometryReader { geo in
                            InlineModeHint(
                                text: trailingHint.text,
                                fontSize: fontSize,
                                caretWidth: caretWidth,
                                caretY: caretY,
                                availableWidth: geo.size.width,
                                tint: trailingHint.tint)
                            .frame(height: geo.size.height, alignment: .center)
                        }
                        .allowsHitTesting(false)
                    }
                }
                .animation(.smooth(duration: 0.25), value: trailingHint?.text)

                // The placeholder, drawn as a SwiftUI label over the (natively
                // placeholder-less) field so its appearance can FADE — on emptying
                // the field the native swap was an instant pop. Gated on the caret
                // width, not just emptiness, so in-progress pinyin hides it too.
                // Emptiness is the RAW string, not `hasText` (which trims): a
                // ⇧⏎/⌥⏎ line break leaves text = "\n", which trims back to empty
                // and used to keep the ghost sitting on line 1 of a now-two-line
                // box. Anything at all in the editor takes the placeholder away.
                if !followUp && model.text.isEmpty && caretWidth == 0 {
                    Text(placeholder)
                        .font(.sf(fontSize))
                        .foregroundStyle(Tokens.placeholder)
                        .lineLimit(1)
                        // Sit on the box's own ~2pt left inset so the label lands
                        // exactly where the typed glyphs will.
                        .padding(.leading, PromptField.textInset)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                } else if !followUp && model.slashMenuOpen && model.text == "/" {
                    // The bare "/" gets its own hint, parked right after the slash:
                    // the menu below already lists every command, so the one thing
                    // left to say is that typing narrows it. Gone the moment a
                    // letter lands — the filtering has begun; saying so is noise.
                    Text(L("slash.filter"))
                        .font(.sf(fontSize))
                        .foregroundStyle(Tokens.placeholder)
                        .lineLimit(1)
                        .padding(.leading, PromptField.textInset + caretWidth + 1)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            // Drives the placeholder fade in BOTH directions (first character in,
            // last character out — including pinyin pre-composition, which flips
            // `caretWidth` while `hasText` is still false). The second key covers
            // a bare line break, which moves neither `caretWidth` nor `hasText`.
            .animation(.easeOut(duration: 0.16), value: caretWidth == 0)
            .animation(.easeOut(duration: 0.16), value: model.text.isEmpty)
            // ↑/↓ history recall: as each recalled question swaps in, slide the text
            // in from the step's direction (↑ from above, ↓ from below) and fade it
            // up. Idle prompt only. We snap `recallSlide` to the start offset the
            // instant the pulse ticks (no animation on that set), then spring it home
            // — so the eye reads the swap as a small physical push, not a hard cut.
            // `caretWidth`-driven hint rides along because it's inside this ZStack.
            .modifier(RecallSlide(offset: recallSlide, active: !followUp))
            .onChange(of: model.recallPulse.n) { _ in
                guard !followUp else { return }
                recallSlide = model.recallPulse.dir == .older ? -7 : 7
                withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) {
                    recallSlide = 0
                }
            }

            // With the destination spelled out in the pill below, the trailing send
            // pill would just repeat it — so this slot stays empty. The "what's new"
            // cue moved down to the bucket row's trailing edge, beside the Recent
            // chevron, where the panel's other glass chips live.
        }
        // Grows with the box: the prompt keeps its resting breathing room and the row
        // gains a line's height for every line the text wraps to, so the panel unfolds
        // downward instead of the text scrolling away sideways.
        .frame(height: followUp ? 30 : max(NotchBody.idleRowHeight, inputHeight + idleRowVerticalPadding))
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: model.hasText)
        // No `.animation(…, value: inputHeight)` here on purpose. It only ever
        // sprang THIS row while its siblings and the glass shell around it snapped,
        // which is the desync itself. `onHeightChange` now owns the whole growth in
        // one `withAnimation` — see `promptGrowth`.
        // The `/` menu's anchor: a zero-cost probe that reports THIS row's screen
        // rect and hangs the menu's own window under it. Nothing about the row (or
        // anything else in the panel) changes when the menu is up — see
        // `MenuCardWindow`.
        .modifier(MenuCardWindow(
            open: !followUp && model.slashMenuOpen,
            // Clicking away is Esc's exit — the command word goes with the menu.
            // A click in another app also re-arms the ordinary leave-fold
            // (`collapseOnLeave` sits out while the menu is up), the same
            // re-check un-pinning an answer runs.
            onDismiss: { insideApp in
                _ = model.dismissSlashMenu()
                if !insideApp { model.collapseOnLeave(from: model.activeDisplay) }
            },
            card: { AnyView(SlashCommandMenu(model: model).menuCardBackground()) }))
    }

    /// The first-launch-after-update cue: normally "What's New" on the bucket row's
    /// trailing edge, immediately left of the Recent chevron. Same glass language as
    /// the chevron cluster's "N running" capsule (`glassCapsule` + `GlassPressStyle`),
    /// so the two sit on that edge as one family. Tapping it opens the release-notes
    /// panel, and `openWhatsNew` marks this version seen, so the cue shows once.
    var whatsNewCue: some View {
        Button {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                model.openWhatsNew(on: nil)
            }
        } label: {
            Text(L("whatsnew.cue"))
                .font(.sf(11.5, weight: .semibold))
                .lineLimit(1)
            .foregroundStyle(whatsNewHovered ? Tokens.text1 : Tokens.text2)
            .padding(.horizontal, 10)
            // The cluster's chip height — the cue lines up with the chevron
            // beside it instead of sitting a hair short.
            .frame(height: 30)
            .glassCapsule(in: Capsule(), brighter: whatsNewHovered)
            .contentShape(Capsule())
        }
        .buttonStyle(GlassPressStyle())
        .onHover { whatsNewHovered = $0 }
        .animation(.easeOut(duration: 0.18), value: whatsNewHovered)
    }

    /// The waiting-update chip: the action promoted OUT of the ⋯
    /// menu onto the surfaces themselves — the idle prompt's bucket row and the
    /// recent list's manage bar. A new build is the one thing worth surfacing,
    /// and a 5pt dot on the ⋯ chip asked the user to go looking for it. Same
    /// glass capsule as the "what's new" cue beside it, plus the arrow-up mark
    /// the About row uses, so the chip reads as the update family wherever it
    /// lands. Tapping installs and relaunches.
    ///
    /// `height` matches whichever row hosts it — 30 on the bucket row, 34 on the
    /// manage bar — so the chip lines up with the chevron / ⋯ beside it.
    func updateCue(version: String, height: CGFloat,
                           hovered: Binding<Bool>) -> some View {
        Button {
            updater.update()
        } label: {
            HStack(spacing: 5) {
                LucideIcon(mark: LucideIcons.circleFadingArrowUp, size: 12)
                Text(L("about.update.to", version))
                    .font(.sf(11.5, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(hovered.wrappedValue ? Tokens.text1 : Tokens.text2)
            .padding(.horizontal, 10)
            .frame(height: height)
            .glassCapsule(in: Capsule(), brighter: hovered.wrappedValue)
            .contentShape(Capsule())
        }
        .buttonStyle(GlassPressStyle())
        .onHover { hovered.wrappedValue = $0 }
        .animation(.easeOut(duration: 0.18), value: hovered.wrappedValue)
    }

    var followUpRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.askComposeImages.isEmpty {
                ComposeImagesAttachedLine(images: model.askComposeImages) {
                    model.removeAskComposeImage(at: $0)
                }
            }
            HStack(alignment: .bottom, spacing: 6) {
                followUpComposer
                    .frame(maxWidth: .infinity)

                if let metadata = agentFollowUpMetadata {
                    GlassIconButton(systemName: "command",
                                    help: L("agent.detail"),
                                    size: 39,
                                    glyphSize: 13,
                                    showsTooltip: false) {
                        model.isResultMetadataMenuOpen.toggle()
                    }
                    .modifier(MenuCardWindow(
                        open: model.isResultMetadataMenuOpen,
                        upperLeading: true,
                        onDismiss: { _ in model.isResultMetadataMenuOpen = false },
                        card: {
                            AnyView(AgentRunMetadataMenu(
                                engine: agentFollowUpRunCaption?
                                    .components(separatedBy: " · ").first,
                                folderPath: model.currentThreadAgentFolder,
                                completedAt: model.currentThreadCompletedAt,
                                onOpenFolder: {
                                    model.isResultMetadataMenuOpen = false
                                    model.openThreadAgentFolder()
                                })
                                .manageMenuCardBackground())
                        }))
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.78),
                   value: agentFollowUpMetadata)
    }

    /// The agent report's old footer metadata, consolidated into the command chip
    /// beside the follow-up field. The model comes from the persisted agent answer;
    /// the timestamp is the saved run's completion time, rendered in full in the
    /// hover card instead of taking a second line under the report.
    private var agentFollowUpMetadata: String? {
        guard model.threadIsAgentRun else { return nil }

        var parts: [String] = []
        if let caption = agentFollowUpRunCaption {
            parts.append(caption)
        }
        if let completedAt = model.currentThreadCompletedAt {
            parts.append(L("result.completedAt",
                           completedAt.formatted(date: .abbreviated,
                                                 time: .shortened)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The persisted agent footer is "Engine · folder". The menu renders those
    /// as separate rows, so keep the original caption available as structured
    /// input instead of trying to peel it back out of the localized completion
    /// string appended by `agentFollowUpMetadata`.
    private var agentFollowUpRunCaption: String? {
        guard let report = model.turns.last(where: {
            $0.role == "assistant" && $0.isAgent
        }) else { return nil }
        return AssistantTurnView.footerModelCaption(
            answerModel: report.answerModel,
            regenModel: report.regenModel)
    }

    private var followUpComposer: some View {
        // The shared box (`ComposerBox`) — one implementation for the panel's
        // chat line, the panel's agent page, and the torn-off windows of both.
        // The two things only this surface has ride in as parameters: the
        // destination's colour washed over the box while it holds text, and the
        // rim pulse when that destination flips.
        ComposerBox(
            text: $model.text,
            focusTrigger: focused,
            focused: focused,
            // A whisper of the destination's colour, the quiet twin of the
            // tinted destination pill, so the field leans toward where Enter
            // will send the line.
            tint: model.submitTint,
            // Keyed on the intent *category* so a recurrence-suffix edit
            // doesn't pulse.
            pulse: AnyHashable(model.effectiveSubmitPanel),
            pulseTint: model.submitInk,
            // Route by intent, same as the idle prompt — a follow-up line like
            // "remind me to ping Alex tomorrow at 9am" files to Reminders
            // instead of being asked to the AI. A plain question still resolves
            // to `.chat` → `submit()`, which continues the existing thread
            // (firstTurn = turns.isEmpty), so the common path is unchanged.
            onSubmit: { model.submitCurrent() },
            onPasteImage: { model.handleComposePasteImage() },
            onBack: {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                    model.newChat()
                }
            },
            // Tab cycles where Enter sends this line (Ask → Note → Remind →…)
            // when the classifier guessed wrong — the correction escape hatch,
            // matching the idle prompt. Empty-field Tab is still swallowed so
            // focus never wanders out of the field.
            onTab: {
                guard let event = NSApp.currentEvent,
                      ReservedAppShortcut.cycleIntent.matches(event) else {
                    return false
                }
                if model.hasText { model.toggleSubmitPanel() }
                return true
            },
            placeholder: { followUpPlaceholderLabel },
            // The send button appears the moment the user starts typing a
            // follow-up. (The "continue in ChatGPT/Claude" handoff used to rest
            // here while the field was empty; it now lives in the answer footer
            // with the other per-answer actions — see `AssistantTurnView`.)
            trailing: {
                if model.hasText || !model.askComposeImages.isEmpty {
                    SendButton(compact: true) { model.submitCurrent() }
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            })
    }

    /// The follow-up field's placeholder, drawn as a SwiftUI label in the slot the
    /// native placeholder would occupy (same font, colour and inset). SwiftUI
    /// ownership (rather than the box's own placeholder) is what lets it hide the
    /// instant the field shows anything — including still-composing pinyin, which a
    /// native placeholder wouldn't yield to.
    private var followUpPlaceholderLabel: some View {
        // On an agent thread the placeholder says who actually answers. With the
        // run's CLI session still on record (and its engine installed), Enter
        // resumes THAT session — the agent continues the work (`submit()` routes
        // it via `continueAgentThread`); while a round is still in flight the
        // line queues for the next one, and the placeholder says so. Only when
        // the session is gone does the question fall through to the chat model,
        // with the report as context.
        Group {
            if let engine = model.agentThreadContinuation {
                Text(model.agentThreadTaskRunning
                    ? L("result.followUp.agentQueue", engine.displayName)
                    : L("result.followUp.agentContinue", engine.displayName))
            } else {
                Text(L(model.threadIsAgentRun ? "result.followUp.agent" : "result.followUp"))
            }
        }
    }

    /// The always-available peer workspace beside Utilities. Its overlay placement
    /// retains Media and Utilities' original tab positions.
    var activityMonitorToggle: some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                if capabilities.workspaceTab == .activityMonitor {
                    capabilities.workspaceTab = .utilities
                } else {
                    capabilities.workspaceTab = .activityMonitor
                    model.setAgentBucket(false)
                    utilityOverlaySession.dismiss()
                }
            }
        } label: {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 21, height: 21)
                .background(capabilities.workspaceTab == .activityMonitor ? Tokens.accent.opacity(0.16) : Color.white.opacity(0.08), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(capabilities.workspaceTab == .activityMonitor ? Tokens.accent : Tokens.text3)
        .accessibilityLabel(capabilities.workspaceTab == .activityMonitor ? "Show File tray and Calendar" : "Show Activity Monitor")
    }

    /// The AI-side peer of the system Activity Monitor. It is intentionally a
    /// separate workspace, not a Chat or Agent sub-tab, so it can compare the
    /// model currently selected for Chat with every live CLI session.
    var aiActivityMonitorToggle: some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                if capabilities.workspaceTab == .aiActivityMonitor {
                    capabilities.workspaceTab = .chat
                } else {
                    capabilities.workspaceTab = .aiActivityMonitor
                    model.setAgentBucket(false)
                    utilityOverlaySession.dismiss()
                }
            }
        } label: {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 21, height: 21)
                .background(capabilities.workspaceTab == .aiActivityMonitor ? Tokens.accent.opacity(0.16) : Color.white.opacity(0.08), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(capabilities.workspaceTab == .aiActivityMonitor ? Tokens.accent : Tokens.text3)
        .accessibilityLabel(capabilities.workspaceTab == .aiActivityMonitor ? "Show Chat" : "Show AI Activity Monitor")
    }
}
