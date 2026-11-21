import SwiftUI
import AppKit

@MainActor
extension NotchBody {
    // MARK: - Load

    var loadView: some View {
        VStack(alignment: .leading, spacing: 0) {
            resultHeader
            // No drawn rule here — the gap alone separates the chevron from the
            // content below. Roughly the rhythm the old Divider held (its 9pt
            // top/bottom pad plus the hairline) so the spacing reads the same.
            Spacer().frame(height: 18)
            // Text-only wait line — no animated dots. Before any tool runs the
            // status is empty, so fall back to the rotating mood word — the same
            // opening a follow-up turn shows — instead of a static "Thinking…"
            // (the first question and a follow-up used to start differently for
            // no reason). The elapsed suffix is a sibling, not part of the
            // dissolving word, so the ticking seconds never ride the word swap.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                let label = model.thinkingStatus.isEmpty ? model.currentThinkingWord : model.thinkingStatus
                ThinkingOrb(state: model.thinkingOrbState)
                    .centeredOnTextGlyphs(fontSize: 15)
                // Word and timer share ONE baseline — centering text of two
                // different sizes floats the smaller suffix ~0.5pt high. Same
                // pairing as `AssistantTurnView.waitRow`, so the pre-answer wait
                // and the mid-answer one read identically.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    CrossfadeText(text: label, font: 15, color: Tokens.text2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    WaitElapsedSuffix(since: model.thinkingStartedAt, font: 15)
                        .fixedSize()
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 2)
        }
    }
    // MARK: - Result

    /// Height of the top frost band — kept 4pt SHORTER than the top runway, the
    /// same convention as `immersiveBlurReach` / `clippedBottomBlurReach`, so the
    /// band tapers fully to clear at the runway's lower edge. Text scrolling up
    /// behind the back/pin chrome frosts + fades on its way out instead of ending
    /// on a hard cut under the header.
    var clippedTopBlurReach: CGFloat { max(resultHeaderReach - 4, 0) }

    /// Height of the bottom blur band — kept 4pt SHORTER than the runway so the band
    /// tapers fully to clear before it touches the last resting row (mirrors the
    /// `immersiveBottomBlurReach = immersiveBottomReach - 4` convention). At idle the
    /// last row sits ~64pt above the viewport bottom and the band reaches 58pt up —
    /// 6pt of clearance, so nothing haloes at rest.
    var clippedBottomBlurReach: CGFloat { max(clippedBottomRunway - 4, 0) }

    /// True when the thread's intrinsic height exceeds `answerMaxHeight` and the
    /// clipped+scrolling layout is active. Derived from the same @State that
    /// `conversationScroll` already reads — promoted here so `resultView`, `body`,
    /// and `conversationScroll` all share the identical boolean without duplication.
    ///
    /// Unmeasured (0) means a whole thread just arrived while the panel was
    /// already mounted — reopening a record from Recent, where neither `init`'s
    /// parked seed nor a previous measurement applies. Falling through to a
    /// measurement that can only land a layout pass LATER meant a long record
    /// mounted in the growing layout at its full natural height (a 40-turn agent
    /// run unfurling top-to-bottom, panel and all) and then sprang back to the
    /// 407pt scroller — the crossover `.animation(value: clipped)` animating a
    /// two-thousand-point collapse right through the open. The estimate below
    /// costs no layout, so the first frame is already the final one.
    var isAnswerClipped: Bool {
        guard measuredAnswerHeight > 0 else {
            return Self.estimatedThreadExceeds(model.turns, answerMaxHeight)
        }
        return measuredAnswerHeight > answerMaxHeight
    }

    /// Whether a thread's natural height clears `ceiling`, estimated from its text
    /// alone — no view build, no text layout. Deliberately a *boolean* with an
    /// early-out rather than a height: it only ever feeds `isAnswerClipped`, and
    /// bailing the moment the running total crosses the ceiling means a long
    /// thread is settled after a dozen lines instead of walking a 50k-character
    /// transcript. Accuracy only matters near the boundary, where being wrong
    /// costs exactly what the old behaviour cost everywhere: one crossover.
    private static func estimatedThreadExceeds(_ turns: [NotchModel.Turn],
                                               _ ceiling: CGFloat) -> Bool {
        // The thread's text column: the result panel less its padding and the
        // turn stack's own trailing inset.
        let column = Tokens.openWidthResult - panelPadding * 2 - 8
        // Wrapped height of one run of text. A CJK glyph takes about a full em,
        // latin about half — precise enough to tell a two-line question from a
        // forty-line report.
        func height(_ text: String, _ em: CGFloat) -> CGFloat {
            var lines = 0
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                var advance: CGFloat = 0
                for ch in line { advance += ch.isASCII ? em * 0.5 : em }
                lines += max(1, Int(ceil(advance / column)))
            }
            return CGFloat(lines) * em * 1.45
        }

        var total: CGFloat = 0
        for turn in turns where !turn.hidesUserBubble {
            if turn.role == "user" {
                total += height(turn.text, 14.5) + 26        // bubble padding
                if !turn.imageFiles.isEmpty { total += 30 }  // the image strip
            } else {
                // An agent turn stacks its work trail above the report. Folded
                // (the default), each RUN of consecutive tool calls is a single
                // summary row; the narration between runs reads as prose.
                if turn.isAgent,
                   let trail = turn.agentLog?.droppingTrailingAnswer(turn.text) {
                    var inToolRun = false
                    for entry in trail {
                        if entry.mono {
                            if !inToolRun { total += 20 }
                            inToolRun = true
                        } else {
                            total += height(entry.title, 15) + 7
                            inToolRun = false
                        }
                        if total > ceiling { return true }
                    }
                }
                total += height(turn.text, 15) + 16
            }
            total += 16                                      // the stack's turn spacing
            if total > ceiling { return true }
        }
        return total > ceiling
    }

    /// True while the follow-up input is folded into a glyph on the header's glass
    /// pill — a thread the user landed on by hitting a prompt shortcut on a
    /// selection (translate this, explain this), where the answer is the whole
    /// point and a standing composer is just a row of empty height. One tap on the
    /// pill's speech-bubble unfolds the real field
    /// (`followUpExpanded`), and typing a line at all retires the fold for good
    /// (`NotchModel.submit` clears `fromPromptShortcut`).
    var followUpIsFolded: Bool {
        model.fromPromptShortcut && !followUpExpanded && !model.hasText
            && model.visibleAskError == nil && model.isConfigured
    }

    var resultView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Short layout only: the header sits as a sibling above the thread.
            // When clipped, it FLOATS over the scroll's top instead (the overlay on
            // the ZStack below), so the thread can travel up behind it and dissolve
            // — mirroring how the immersive recent list runs under the input header.
            if !isAnswerClipped {
                resultHeader
                // No drawn rule between the chevron and the thread — a quiet gap does
                // the separating instead. Matches the rhythm the old Divider held (its
                // 9pt top/bottom pad plus the hairline) so the layout doesn't shift.
                Spacer().frame(height: 18)
            }

            // When the answer is clipped (long, scrolling), the follow-up input
            // FLOATS over the scroll's bottom (ZStack child, alignment .bottom)
            // rather than sitting as a VStack sibling below — so content scrolls
            // down behind it and dissolves (fade + blur), mirroring the recent list
            // behind the manage bar. The scroll frame is `clippedAnswerMaxHeight`
            // (363 = 300 + the 24pt gap + the 39pt input that the sibling layout
            // used), so the resultView's total height is identical in both layouts
            // — the panel never resizes at the crossover, which also keeps the
            // source-popup y-offset (`rect.minY - geo.size.height`) correct.
            //
            // When short (not clipped), the ZStack just wraps `conversationScroll`
            // transparently (one child → passthrough size) and the input renders as
            // a sibling below, exactly as before. The AnswerHeightKey probe lives in
            // `conversationScroll`'s .background and is always mounted regardless.
            ZStack(alignment: .bottom) {
                conversationScroll

                // Floating follow-up: only the clipped + configured + no-error case.
                // Error / unconfigured states keep their rows as siblings below (an
                // actionable error must never be hidden behind the scroll). A folded
                // shortcut thread renders no composer at all here — its entry is the
                // glyph on the header's glass pill (see `resultHeader`).
                if isAnswerClipped && !followUpIsFolded
                    && model.visibleAskError == nil && model.isConfigured {
                    followUpRow
                        // No lift: the body's uniform inset is the only gap under
                        // the box, so the floating input rests exactly as far from
                        // the bottom edge as it does from the sides — same as the
                        // sibling layout.
                        .transition(.opacity)
                }
            }
            // Clipped layout: the header floats over the scroll's TOP as fixed
            // chrome (no background of its own — legibility of the text passing
            // behind comes from the thread's top fade + frost, exactly like the
            // immersive input header). The scroll frame absorbed the header block's
            // 44pt (see `resultHeaderReach`), so the panel height is unchanged and
            // the header renders at the same spot as the sibling it replaces.
            .overlay(alignment: .top) {
                if isAnswerClipped {
                    resultHeader
                        .transition(.opacity)
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 1.0), value: isAnswerClipped)

            // Row slot BELOW the ZStack. The error / "set up a model" rows always
            // live here as siblings (in both layouts) so they push the panel taller
            // when they appear — intentional, an actionable row must stay visible.
            // The normal follow-up input renders here ONLY in the short layout; when
            // clipped it floats inside the ZStack above and must NOT also render here
            // (two NSTextFields would fight for first-responder).
            //
            // An agent run the app died in the middle of gets its own actionable
            // capsule under the answer: one tap re-issues the cut-off round in the
            // CLI session it left behind. It sits ABOVE the follow-up input, which
            // still does its usual thing (ask the chat model about this thread).
            if let resume = model.openAgentResume {
                agentResumeRow(engine: resume.engine, resume: resume.resume)
                    .padding(.top, isAnswerClipped ? 8 : 24)
                    .transition(.opacity)
            }

            // A failed Ask gets an actionable capsule right under the answer (XII-85):
            // "Open Settings" when there's no key to retry with, "Try again" otherwise.
            // Scoped to the round that failed (`visibleAskError`) — a failure in one
            // conversation must not replace another conversation's follow-up input.
            if let askError = model.visibleAskError {
                errorActionRow(askError)
                    .padding(.top, isAnswerClipped ? 8 : 24)
                    .transition(.opacity)
            } else if !isAnswerClipped && !followUpIsFolded {
                // Short layout: follow-up input (or setup CTA) as a sibling, as before.
                // (Folded shortcut button excluded — it floats inside the ZStack so
                // it never pushes the panel taller.)
                Group {
                    if model.isConfigured {
                        followUpRow
                    } else {
                        setupModelRow
                    }
                }
                // The resume capsule already spends the 24pt gap under the answer;
                // the input just needs to clear the capsule, not repeat that gap.
                .padding(.top, model.openAgentResume == nil ? 24 : 10)
                .transition(.opacity)
            } else if !model.isConfigured {
                // Clipped + unconfigured: the setup CTA stays a sibling (it's a
                // one-time prompt, not the live input, so floating it makes no sense).
                setupModelRow
                    .padding(.top, 8)
                    .transition(.opacity)
            }
            // (Clipped + configured + no error: followUpRow is inside the ZStack;
            //  nothing renders here — the gap+row were absorbed into the scroll frame.)

            // Note/Reminder save feedback for lines filed FROM the result view (now
            // that the follow-up field routes by intent). The idle prompt shows this
            // same calm cue via `noteFeedbackContent`, but that path never renders in
            // `.result` — so mirror it here: "Saving…" in flight, then the model's
            // "Added to Reminders · Daily" / "Added to Notes" cue, which the model
            // auto-clears after ~1.7s. The error slot above owns the failure case.
            if model.noteSaving {
                feedbackLine(L("input.saving"))
                    .padding(.top, 6)
                    .transition(.opacity)
            } else if let cue = model.lastSavedNote {
                feedbackLine(cue)
                    .padding(.top, 6)
                    .transition(.opacity)
            }
        }
        // The short↔long crossover moves the follow-up between sibling and overlay;
        // animate the sibling-slot changes on the same spring the ZStack uses so the
        // whole transition reads as one motion.
        .animation(.spring(response: 0.3, dampingFraction: 1.0), value: isAnswerClipped)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: model.lastSavedNote)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: model.noteSaving)
        // Float the source popup here, at the result-view level — OUTSIDE the
        // conversation ScrollView — so it's never clipped by the scroll's height
        // (which was chopping the popup's top off, XII-118). Shared with every
        // other surface that shows a source badge (see `sourcePopoverOverlay`).
        .sourcePopoverOverlay(hoveredID: $hoveredSourceID, closeWork: $sourceCloseWork)
    }

    /// Stand-in for the follow-up field while on the offline stub: a full-width
    /// button that opens Settings (same path as the gear / ⌘,) so the user can
    /// paste an API key and get live answers. Styled like the follow-up box it
    /// replaces, so the result view's footprint doesn't jump.
    private var setupModelRow: some View {
        Button {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                model.openSettings()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                    .font(.sf(13, weight: .medium))
                Text(L("result.setUpModel"))
                    .font(.sf(14.5, weight: .medium))
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.sf(11, weight: .semibold))
                    .foregroundStyle(Tokens.text3)
            }
            .foregroundStyle(Tokens.text1)
            .padding(.leading, 13)
            .padding(.trailing, 12)
            .frame(height: 39)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(SetupModelButtonStyle())
    }

    /// The resume footer under an interrupted agent run's answer — the GUI half of
    /// `AgentEngine.resumeCommand`. One tap hands the round the app died in the
    /// middle of straight back to the CLI session it left behind; the run picks up
    /// as a live task and re-files this same Recent row when it settles. Styled as
    /// the same full-width capsule the failed-Ask footer uses.
    ///
    /// The engine can be gone by now (uninstalled since the run), and then there's
    /// nothing to press — so the row degrades to naming the terminal command, which
    /// is exactly what the answer text used to carry.
    @ViewBuilder
    private func agentResumeRow(engine: AgentEngine,
                                resume: NotchModel.HistoryItem.AgentResume) -> some View {
        if engine.isAvailable {
            Button {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                    model.resumeAgentThread()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                        .font(.sf(13, weight: .medium))
                    Text(L("agent.resume", engine.displayName))
                        .font(.sf(14.5, weight: .medium))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.sf(11, weight: .semibold))
                        .foregroundStyle(Tokens.text3)
                }
                .foregroundStyle(Tokens.text1)
                .padding(.leading, 13)
                .padding(.trailing, 12)
                .frame(height: 39)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(SetupModelButtonStyle())
        } else {
            Text(L("agent.interrupted.resume",
                   engine.resumeCommand(session: resume.session)))
                .font(.sf(11.5))
                .monospaced()
                .foregroundStyle(Tokens.text4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The actionable error footer for a failed Ask (XII-85): a full-width capsule —
    /// "Open Settings" when no key is configured (retrying can't help), else
    /// "Try again", which re-runs the same question. Styled like `setupModelRow` so
    /// the result view's footprint doesn't jump between the two.
    private func errorActionRow(_ askError: NotchModel.AskError) -> some View {
        Button {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                if askError.needsSetup {
                    model.openSettings()
                } else {
                    model.retryLastAsk()
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: askError.needsSetup ? "slider.horizontal.3" : "arrow.clockwise")
                    .font(.sf(13, weight: .medium))
                Text(askError.needsSetup ? L("error.openSettings") : L("error.retry"))
                    .font(.sf(14.5, weight: .medium))
                Spacer(minLength: 0)
                Image(systemName: askError.needsSetup ? "arrow.up.right" : "chevron.right")
                    .font(.sf(11, weight: .semibold))
                    .foregroundStyle(Tokens.text3)
            }
            .foregroundStyle(Tokens.text1)
            .padding(.leading, 13)
            .padding(.trailing, 12)
            .frame(height: 39)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(SetupModelButtonStyle())
    }
}
