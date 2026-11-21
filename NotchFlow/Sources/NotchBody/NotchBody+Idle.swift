import SwiftUI
import AppKit

@MainActor
extension NotchBody {
    // MARK: - Idle

    var idleView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.showWhatsNew {
                // What's New owns the whole body, like settings — the idle prompt is
                // hidden while the user reads the release notes. Its own back chevron
                // (and Esc) carries the way home.
                WhatsNewView(model: model)
                    .transition(moduleTransition)
            } else if useImmersiveHistory {
                // Immersive recent list: the input floats as a translucent header
                // over a tall scroll surface that reaches UP behind it. Rows scroll
                // under the input and frost + fade out — present but pushed back —
                // so the panel reads as one continuous surface, not a stack of
                // blocks. Only taken once the list overflows (`useImmersiveHistory`);
                // a short list keeps the calm compact layout below.
                immersiveHistoryView
            } else {
                // The workspace switcher belongs in the shoulders of the camera
                // housing. Keeping it as an overlay means the page content still
                // begins at its existing vertical position below the notch.
                Color.clear
                    .frame(height: 0)
                    .overlay(alignment: .top) {
                        workspaceTabBar
                            .offset(y: -NotchBody.panelPadding - metrics.restHeight + 2)
                    }

                if capabilities.workspaceTab == .activityMonitor {
                    ActivityMonitorView(monitor: SystemMonitorService.shared)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    Spacer().frame(height: 4)
                } else if capabilities.workspaceTab == .aiActivityMonitor {
                    AIActivityMonitorView(sessions: agentSessions, tasks: agentManager)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    Spacer().frame(height: 4)
                } else if capabilities.workspaceTab == .media {
                    NotchNowPlayingView(model: model, capabilities: capabilities)
                    Spacer().frame(height: 4)
                } else if capabilities.workspaceTab == .utilities {
                    VStack(spacing: 10) {
                        NotchQuickUtilitiesView(
                            selection: utilityOverlaySession.selection?.action
                        ) { action in
                            guard let overlay = UtilityOverlayKind(for: action) else { return }
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                                // Selecting the open chip again closes it — the same
                                // "tap the active tab to collapse it" shape as the
                                // top-level workspace tabs. `NotchUtilityOverlay`'s own
                                // appear/disappear keeps `setUtilityOverlayPresented` in
                                // sync with which branch below is mounted, so neither
                                // path needs to touch it directly.
                                if utilityOverlaySession.selection == overlay {
                                    utilityOverlaySession.dismiss()
                                } else {
                                    utilityOverlaySession.present(overlay)
                                }
                            }
                        }

                        if let utilityOverlay = utilityOverlaySession.selection {
                            NotchUtilityOverlay(selection: utilityOverlay,
                                                model: model,
                                                focusTimer: focusTimer,
                                                quickNote: quickNote,
                                                quickReminder: quickReminder,
                                                system: SystemUtilityService.shared) {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                                    utilityOverlaySession.dismiss()
                                }
                            }
                        } else {
                            EqualHeightUtilitiesLayout(spacing: 10) {
                                NotchShelfView(capabilities: capabilities)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                                NotchUtilitiesView(utilities: utilities)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        }
                    }
                    Spacer().frame(height: 4)
                } else if capabilities.workspaceTab == .agent {
                    // The agent workspace is a live roster: permissions, local
                    // runs, and externally observed sessions share the same dense
                    // row language so multiple agents remain legible at a glance.
                    agentApprovalWorkspace
                } else {
                // While ↑/↓ recall is walking the history, the slot above the input
                // shows a "which of how many" counter instead of the copied-image
                // preview — the preview is irrelevant to a recalled question, and the
                // counter tells you how far back you've stepped. An active agent
                // compose repurposes the slot: the ambient clipboard preview is
                // suppressed (its context chips live *below* the input), but an image
                // the user explicitly ⌘V-pasted into the task shows here — that's
                // part of the task being written, not noise over it.
                // The selection carried in from the app the user came from gets a
                // row of its own rather than a turn in the slot below: an image
                // pasted onto the same prompt must not hide the fact that a
                // selection is riding along too.
                if let selection = model.selectionContext {
                    selectionContextLine(selection)
                        .padding(.bottom, 8)
                        .transition(moduleTransition)
                } else if model.selectionContextHintShown {
                    selectionContextHintLine
                        .padding(.bottom, 8)
                        .transition(moduleTransition)
                }
                if model.usingPromptShortcutContext {
                    Text(L("shortcuts.promptAction.window.context"))
                        .font(.sf(12, weight: .medium))
                        .foregroundStyle(Tokens.text4)
                        .lineLimit(1)
                        .padding(.bottom, 8)
                        .transition(moduleTransition)
                } else if !model.agentComposeActive {
                    if let recall = model.recallPosition {
                        recallCounterLine(recall)
                            .transition(moduleTransition)
                    } else if !model.askComposeImages.isEmpty {
                        ComposeImagesAttachedLine(images: model.askComposeImages) {
                            model.removeAskComposeImage(at: $0)
                        }
                        .padding(.bottom, 8)
                        .transition(moduleTransition)
                    }
                } else if !model.agentComposeImages.isEmpty {
                    ComposeImagesAttachedLine(images: model.agentComposeImages) {
                        model.removeAgentComposeImage(at: $0)
                    }
                    .padding(.bottom, 8)
                    .transition(moduleTransition)
                }

                idleInputRow

                // (The `/` command menu is NOT in this stack — it lives in its own
                // borderless window, hung under the input by `SlashMenuHost`. It
                // takes no space here, moves nothing, and is free to overhang the
                // island's edge.)

                // The bucket row (XII: agent-to-Codex): the destination pill as
                // fixed chrome below the input, with the folder / model / effort
                // chips unfurling beside it while Agent is armed — same slot and
                // glass language as the one-tap presets. It rides the panel even
                // with no agent CLI installed: the pill is now where the routing
                // (Ask / Note / Remind) shows itself, so it can't be optional.
                // (Both the pill and the Recent chevron leave the row while
                // Recent is expanded — the chevron moves to the manage bar's
                // bottom-right — so the row itself drops out when nothing is left.)
                if bucketRowHasContent {
                    bucketRow
                        .transition(moduleTransition)
                }

                // Agent runs' presence (XII: agent-to-Codex): one status line per
                // task — the live activity while it works, the outcome once it
                // settles. These live ONLY inside the opened Recent list (they ride
                // the TOP of `historyList`), never as a standalone strip in this
                // resting compact view — tap the Recent chevron to see them. While a
                // run is live the chevron carries the "N running" count as the sole
                // resting cue; the rows themselves stay behind that disclosure.

                // The recent list expands below the prompt once the clock is tapped.
                // (The immersive variant above handles the overflowing case.)
                if !promptHidesRecent && recentHasContent && model.showHistory {
                    historySection
                        .padding(.top, 12)
                        .transition(moduleTransition)
                }

                // The note-save feedback line (Saving… / Added to Notes / error).
                // Only present when there's something to say — when there's nothing it
                // takes ZERO height, so the resting prompt is just the 48pt input. A
                // line classified as a note routes to Apple Notes without changing the
                // surface, and this quiet cue is the only sign it landed there.
                if let feedback = noteFeedbackContent {
                    feedback
                        .padding(.top, 8)
                        .transition(moduleTransition)
                }
                }
            }
        }
        // The note-save feedback unfurls/fades on the panel's standard module spring,
        // matching the recent list right above it.
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: model.noteSaving)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: model.lastSavedNote)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: model.noteError)
        // Typing folds the recent list from `text.didSet` (showHistory = false) —
        // a model-side write with NO withAnimation around it, so without these keys
        // the fold (and the immersive⇄flat layout swap that rides on hasText /
        // showHistory) was a hard pop instead of the module spring every *other*
        // open/close path plays. Same spring as those withAnimation call sites.
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: model.showHistory)
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: model.hasText)
    }

    private var workspaceTabBar: some View {
        Group {
            if capabilities.agenticModeEnabled {
                workspaceShoulders {
                    workspaceTabGroup([.chat, .agent])
                        .overlay(alignment: .leading) {
                            aiActivityMonitorToggle
                                .offset(x: -30)
                        }
                } right: {
                    workspaceTabGroup([.media, .utilities])
                        .overlay(alignment: .trailing) {
                            activityMonitorToggle
                                .offset(x: 30)
                        }
                }
            } else {
                // Companion mode. Chat and Agent are gone, which frees the whole
                // left shoulder — and with the agentic surfaces away there is no
                // reason for Activity Monitor to stay a cramped edge toggle, so it
                // is promoted to the third peer tab. Media and Utilities take the
                // left shoulder and Activity the right, which keeps them in
                // reading order across the camera housing and puts all three
                // clear of it.
                workspaceShoulders {
                    workspaceTabGroup([.media, .utilities])
                } right: {
                    workspaceTabGroup([.activityMonitor])
                }
            }
        }
    }

    /// The two shoulders either side of the camera housing, with the housing's own
    /// gap between them.
    ///
    /// Both shoulders are pinned to the SAME width, and that is load-bearing
    /// rather than tidiness. The assembly is centred in the panel, so the middle
    /// gap only lands on the real notch while the two sides balance. Chat|Agent
    /// against Media|Utilities balanced by accident — two chips each. Companion
    /// mode has three tabs and no even split, and letting self-sizing groups
    /// stand in for shoulders pushed the gap far enough off-centre to slide a chip
    /// under the housing: with only Media|Utilities there, Utilities disappeared
    /// behind it and the bar read as a single Media tab.
    ///
    /// Each shoulder's content hugs the housing (trailing on the left, leading on
    /// the right), so a shoulder that is narrower than the box does not drift out
    /// towards the panel edge.
    private func workspaceShoulders<Left: View, Right: View>(
        @ViewBuilder _ left: () -> Left,
        @ViewBuilder right: () -> Right
    ) -> some View {
        HStack(spacing: 0) {
            left()
                .frame(width: Self.tabShoulderWidth, alignment: .trailing)
            Color.clear.frame(width: metrics.notchWidth)
            right()
                .frame(width: Self.tabShoulderWidth, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// Wide enough for the widest shoulder either mode asks for — a two-chip group
    /// (81pt) plus the monitor circle hanging 30pt off its outer edge. The panel is
    /// far wider than two of these plus the notch, so there is no risk of the pair
    /// being squeezed.
    private static let tabShoulderWidth: CGFloat = 120

    private func workspaceTabGroup(_ tabs: [NotchWorkspaceTab]) -> some View {
        HStack(spacing: 3) {
            ForEach(tabs) { tab in
                Button {
                    // The highlight always gets the same transaction, regardless
                    // of destination. Agent's separate workspace bookkeeping must
                    // not join this animation and make its selected state feel
                    // different from the other three tabs.
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                        capabilities.workspaceTab = tab
                        // Activity Monitor replaces the whole Utilities workspace,
                        // so a utility overlay left open underneath it has nothing
                        // to sit in — the same fold the edge toggle did before this
                        // became a peer tab.
                        if tab == .activityMonitor { utilityOverlaySession.dismiss() }
                    }
                    // Agent is a peer workspace now, rather than a secondary mode
                    // hidden in Chat. Its task manager and compose path remain the
                    // same; this tab decides where they live.
                    model.setAgentBucket(tab == .agent)
                } label: {
                    Image(systemName: tab.symbolName)
                    .font(.sf(13, weight: .semibold))
                    .foregroundStyle(capabilities.workspaceTab == tab ? Tokens.text1 : Tokens.text3)
                    .frame(width: 36, height: 32)
                    .background {
                        if capabilities.workspaceTab == tab {
                            Capsule().fill(Color.white.opacity(0.14))
                                .matchedGeometryEffect(id: "workspace-tab", in: workspaceTabNamespace)
                        }
                    }
                    // The whole pill is the target. Without this a plain-styled
                    // button only takes clicks on the glyphs themselves, so the
                    // padding around the word — most of the chip — was dead.
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.rawValue)
            }
        }
        .padding(3)
        .background(Color.white.opacity(0.08), in: Capsule())
    }

    /// The idle prompt field, with the live note-error reset wired in. Shared by
    /// the flat idle layout and the immersive history header so the field — and
    /// all its focus/IME plumbing — exists exactly once, never duplicated.
    /// An armed agent folder swaps the placeholder: the same field is now
    /// composing Codex's task, and the ghost text should say so. A mode pinned by
    /// `/` swaps it the same way ("Write a note…"), since an empty field has no
    /// glyphs for the inline ghost to trail — see `idlePlaceholderKey`.
    var idleInputRow: some View {
        inputRow(
            placeholder: L(model.usingPromptShortcutContext
                           ? "shortcuts.promptAction.window.placeholder"
                           : model.idlePlaceholderKey),
            followUp: false)
            .onChange(of: model.text) { _, _ in
                // Editing the field clears a stale note-save error so the cue
                // doesn't linger over a line the user is actively rewriting.
                if model.noteError != nil { model.noteError = nil }
            }
            // The idle page has no header, so the input row's free strip is its
            // tear-off grip — see `detachGrip`.
            .background(detachGrip)
    }

    /// The idle page's tear-off grip: a transparent sheet laid BEHIND the row,
    /// so dragging its free strip pulls the prompt out into its own composer
    /// window (`DetachedSession.compose`) while everything drawn on top keeps
    /// its own mouse. That layering is the point — a grip wrapped *around* the
    /// row would be an ancestor of the prompt field, and dragging to select text
    /// would tear the panel off the bezel. Behind it, the field (and every chip)
    /// hit-tests first and the grip only ever sees the empty space beside them.
    ///
    /// That invisibility is also why it carries `grabCursor()`: the hand is the
    /// only thing telling you the strip is grabbable at all.
    var detachGrip: some View {
        Color.clear
            .contentShape(Rectangle())
            .grabCursor()
            .gesture(detachDragGesture)
    }

    /// Take the immersive (input-floats-over-scroll) layout only when the recent
    /// list is both open and long enough to scroll. A short list that fits has
    /// nothing to flow under the input, so it keeps the calm compact layout —
    /// matching the same `> 6` overflow calibration the list itself uses.
    ///
    /// A pending copied-image preview doesn't force the compact fallback: it rides
    /// inside the immersive floating header above the input, and the runway grows to
    /// clear that taller header — so the frosted immersive surface stays consistent
    /// whether or not a preview is present.
    private var useImmersiveHistory: Bool {
        !promptHidesRecent
            && model.showHistory
            && noteFeedbackContent == nil
            && recentBucketsNeedImmersiveLayout
    }

    /// Chat Recent is the left page and Agent Recent is the right page. Keep both
    /// pages on the same compact/immersive rail for the lifetime of an open Recent
    /// view, otherwise a bucket switch with (say) 20 Chat rows and 3 Agent rows also
    /// swaps the entire vertical layout and makes the pages appear to fly up/down.
    private var recentBucketsNeedImmersiveLayout: Bool {
        let chatOverflows = model.history.lazy
            .filter { $0.source != .agent }
            .prefix(7).count > 6
        let agentOverflows = model.history.lazy
            .filter { $0.source == .agent }
            .prefix(7).count + agentManager.tasks.prefix(7).count > 6
        return chatOverflows || agentOverflows
    }

    /// Whether the active bucket has anything to disclose. Agent tasks belong only
    /// to Agent's Recent surface; Chat is Ask / Notes / Reminders history alone.
    var recentHasContent: Bool {
        model.recentScopeHistoryCount > 0
            || (model.agentComposeActive && !agentManager.tasks.isEmpty)
    }

    /// True while the Recent list is on screen (flat `historySection` or its
    /// immersive variant). The Ask|Agent bucket pill hides in this state — an
    /// expanded Recent view shouldn't also carry the compose-family switch.
    var recentListShown: Bool {
        !promptHidesRecent && recentHasContent && model.showHistory
    }

    /// Does the current prompt context displace the Recent list? Only the
    /// Shortcuts-run prompt does: that window is one action's box, with no recall
    /// surface behind it.
    ///
    /// Typed text used to displace it too — the list folded the moment a character
    /// landed. That coupling died with the always-on Recent chevron (see
    /// `bucketRow`): a disclosure that stays on the row while you type has to still
    /// open, or it's a dead control. Recent is now the chevron's state alone, in
    /// both an empty and a filled box. (`text.didSet` matches — it clears the
    /// keyboard highlight on a keystroke but no longer closes the list.)
    private var promptHidesRecent: Bool {
        model.usingPromptShortcutContext
    }
}
