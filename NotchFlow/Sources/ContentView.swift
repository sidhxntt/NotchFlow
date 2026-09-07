import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The full transparent canvas. The notch island is pinned to the top-center;
/// everything else is empty space that lets clicks fall through to apps below.
struct ContentView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var capabilities: NotchCapabilityStore
    @ObservedObject var utilities: UtilityCapabilityService
    /// A drag carrying a file URL is hovering the island. Drives open-on-drag:
    /// hover-to-open never fires during a drag (the tracking area sees no
    /// mouseEntered), so the drop target itself unfurls the panel.
    @State private var agentDropTargeted = false
    @Environment(\.notchMetrics) private var metrics
    /// Reduce-motion skips the close dissolve (the content fade beat), collapsing in
    /// one step — mirrors how the open spring already degrades to a plain settle.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            // No click-outside scrim anymore: leaving the island already folds the
            // panel (see `collapseOnLeave` — leave = fold, restored on re-hover),
            // so by the time the pointer reaches anything outside, the panel is
            // gone. Removing the scrim also stops it swallowing the first click
            // on whatever sits under the canvas.
            NotchIsland(model: model, capabilities: capabilities, utilities: utilities)
                // The answer's voice, injected once at the root so every mounted
                // copy of a turn agrees — the visible thread, the hidden height
                // probe, the progressive-blur overlays. Injecting it lower would
                // let the probe measure a typeset answer while the thread renders
                // a handwritten one, and the panel would settle to the wrong
                // height. Only `MarkdownBlocks` reads it, and that view renders
                // nothing but assistant output, so the reach is exactly the prose.
                .environment(\.handwritten, HandwritingFeature.isEnabled && model.handwrittenAnswers)
                // Drop a project folder on the island to start composing a
                // agent task in it (XII: agent-to-Codex) — the folder is
                // exactly the argument the mode needs, so one drop enters the
                // compose with it in place. Dragging over the resting notch
                // unfurls the panel (via `agentDropTargeted` below); the drop
                // itself routes through the model, which validates it's really a
                // directory and an agent CLI is signed in.
                .onDrop(of: ShelfDropService.acceptedTypes, isTargeted: $agentDropTargeted) { providers in
                    Task {
                        let items = await ShelfDropService.items(from: providers)
                        Task { @MainActor in
                            model.openPanel(on: metrics.displayID)
                            var shelfItems: [NotchShelfItem] = []
                            for item in items {
                                if let url = item.url,
                                   url.isFileURL,
                                   !capabilities.shouldAddToShelf(url: url, target: .chatNotch) {
                                    model.handleAgentFolderDrop(url)
                                } else {
                                    shelfItems.append(item)
                                }
                            }
                            capabilities.ingest(shelfItems)
                            if !shelfItems.isEmpty {
                                withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                                    // A saved file must foreground the File tray,
                                    // even when a result or a live agent-detail
                                    // page currently owns the body. `newChat()`
                                    // detaches in-flight work rather than cancelling
                                    // it, so the background process keeps running.
                                    model.newChat()
                                    capabilities.revealFileTray()
                                }
                            }
                        }
                    }
                    return true
                }
                .onChange(of: agentDropTargeted) { _, targeted in
                    // The drag reaching the island is the open gesture: unfurl so
                    // the drop lands on the (visible) idle prompt, exactly like a
                    // hover would have.
                    if targeted, !model.isOpen(on: metrics.displayID) {
                        model.openPanel(on: metrics.displayID)
                    }
                    if targeted {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                            capabilities.prepareForIncomingFileDrop()
                        }
                    }
                }
        }
        .frame(width: metrics.canvasWidth, alignment: .top)
        .ignoresSafeArea()
        // Round start/end drives the fly-into-notch exit — a snappy spring so the
        // tuck reads as one quick, intentional motion (not a slow drift). Panel
        // fold/expand keeps the gentle in-place fade (the dots and the panel are
        // handing off, not animating "into" anything).
        .animation(.spring(response: 0.34, dampingFraction: 0.78), value: model.thinking)
        .animation(.easeInOut(duration: 0.2), value: model.isOpen(on: metrics.displayID))
        .background(KeyEventCatcher { event in
            // This catcher is installed when the panel is built, so it runs ahead
            // of the Shortcuts recorder's monitor and any chord it consumes never
            // reaches the recorder. While a chord is being recorded the panel
            // ignores the keyboard entirely — including Esc, which the recorder
            // uses to cancel.
            if ShortcutRecording.isActive { return false }
            // In Agent, ⌘↵ starts this task and opens its live detail page.
            // Outside Agent it keeps its original meaning: submit the current line
            // to the *other family* — Ask ⇄ Capture (Note/Remind) — as the
            // one-key correction for a misread intent. Fresh prompt only; intent
            // routing never applies to follow-ups. keyCode 36 is Return.
            if ReservedAppShortcut.sendOther.matches(event),
               model.mode == .idle,
               !model.showWhatsNew, !model.showHistory,
               model.agentDetailTaskID == nil {
                if model.agentComposeActive {
                    return model.submitAgentAndOpenDetail()
                }
                if model.hasText {
                    model.submitOtherFamily()
                    return true
                }
            }
            // The prompt's two destination switches are customizable too. They
            // stay scoped to the live composer so the same chord remains free in
            // settings, history search, and detached task detail fields.
            if ReservedAppShortcut.cycleIntent.matches(event),
               !model.showWhatsNew,
               !model.showHistory, model.agentDetailTaskID == nil,
               fieldEditorIsFirstResponder() {
                if model.mode == .idle {
                    if withAnimation(.spring(response: 0.34, dampingFraction: 0.82), {
                        model.confirmSlashCommand()
                    }) { return true }
                    model.toggleSubmitPanel()
                    return true
                }
                if model.mode == .result {
                    if model.hasText { model.toggleSubmitPanel() }
                    return true
                }
            }
            // Companion mode has no Chat or Agent tab to switch to (see
            // `workspaceTabBar`), so the chord that arms the agent folder must not
            // be able to select one from the keyboard either.
            if ReservedAppShortcut.bucket.matches(event),
               capabilities.agenticModeEnabled,
               model.mode == .idle, !model.showWhatsNew,
               !model.showHistory, model.agentDetailTaskID == nil,
               fieldEditorIsFirstResponder() {
                model.toggleAgentBucket()
                capabilities.workspaceTab = model.agentComposeActive ? .agent : .chat
                return true
            }
            // ⌘F summons the recent-list filter. The chip is gone — this is the only
            // way in. Only meaningful when there's a list worth filtering (matches the
            // field's own > 6 render gate). If the list is collapsed, open it first so
            // the field has somewhere to land; if the filter's already up, ⌘F is a
            // no-op rather than a toggle (Esc clears/closes it — see below).
            if AppShortcutStore.matches(.filter, event: event),
               model.recentScopeHistoryCount > 6 {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                    if !model.showHistory { model.showHistory = true }
                    model.showHistoryFilter = true
                }
                return true
            }
            // ⌘⇧I summons the agent's quick picker — model + reasoning effort, the
            // compose chip's menu unfolded into a card. It is *not* the model-config
            // card: this chord is the fast dial for the two knobs you actually turn
            // between runs, wherever you are (idle prompt, a settled answer, bucket
            // armed or not). In-app only: a global chord would take ⌘⇧I from every
            // other app. Suppressed over onboarding / what's new / settings — the
            // first two own the body, and settings already carries the chip.
            // keyCode 34 is I.
            //
            // With no agent CLI installed there are no dials to show, so the chord
            // falls back to the cross-provider chat picker rather than opening an
            // empty card.
            if AppShortcutStore.matches(.picker, event: event),
               !model.showWhatsNew {
                if model.agentAvailable {
                    model.showAgentPicker = true
                } else {
                    model.showModelPicker = true
                }
                return true
            }
            // ⌃⇧= splits whatever the panel is showing into its own window —
            // the keyboard twin of the tear-off drag and of the header's
            // `macwindow.on.rectangle` chip. It works on all three detachable
            // faces (a draft prompt, a settled thread, an agent run) because
            // `detachableSession` is the single gate for every route out; when
            // it says nil (settings, what's new, an open recent list) the chord
            // falls through to the system rather than fizzling.
            //
            // Deliberately NOT ⌘-based: the panel's ⌘ chords are all in-place
            // actions on the current answer, and every ⌘⇧ letter is spoken for
            // by the frontmost app underneath. ⌃⇧ is free, and it never
            // collides with text editing in the prompt field — which matters,
            // because pulling out a half-typed draft is this chord's main use.
            // keyCode 24 is `=`.
            if AppShortcutStore.matches(.detach, event: event),
               model.detachableSession != nil {
                model.openDetachedWindow()
                return true
            }
            // ⌘N starts a fresh conversation from anywhere in a thread — the
            // keyboard twin of the ← back chevron, but it fires even mid-typing
            // a follow-up (the ⌘ modifier means it never collides with caret
            // movement or text entry, so unlike bare ← it needn't gate on an
            // empty field). No-op on the idle prompt — already a fresh chat.
            // keyCode 45 is N.
            if AppShortcutStore.matches(.newChat, event: event),
               model.mode != .idle, !model.showWhatsNew {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                    model.newChat()
                }
                return true
            }
            // Answer-state action keys (XII-131): the hover toolbar's actions, put
            // on the keyboard so the whole flow stays hands-on-keys. Only in a
            // settled result (not idle/settings/what's-new, not mid-stream) — the
            // toolbar they mirror only exists there. Guarded so a follow-up being
            // typed keeps normal editing: when the prompt field editor is first
            // responder, ⌘C/⌘S/⌘R fall through to the system (⌘C copies the
            // selection/line, etc.). ⌘P/⌘D handle their own state below.
            //   ⌘C (8)  = copy the whole answer     ⌘R (15) = regenerate
            if model.mode == .result, !model.showWhatsNew,
               !model.isStreaming, !fieldEditorIsFirstResponder() {
                if AppShortcutStore.matches(.copyAnswer, event: event),
                   let answer = model.lastAnswerText {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(answer, forType: .string)
                    model.rebaselineClipboardAfterInAppWrite()
                    return true
                }
                if AppShortcutStore.matches(.regenerate, event: event) {
                    model.regenerateLastAnswer()
                    return true
                }
            }
            // ⌘P (and ⌘D) pins/unpins the panel — the keyboard twin of the pin
            // button, which the result header and the idle prompt both carry. Pinned
            // → the panel stays open when the pointer leaves (see
            // NotchModel.collapseOnLeave). Not over settings / what's new (those own
            // no pin), so both fall through to the system there. keyCode 35 is P, 2 is D.
            if AppShortcutStore.matches(.pin, event: event),
               model.mode != .load, !model.showWhatsNew {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                    model.toggleAnswerPin()
                }
                return true
            }
            // ← / → walk an opened image's pile (see `ImageLightbox`). Consumed
            // only while one is open, so the arrows stay the field editor's
            // everywhere else.
            if event.keyCode == 123, ImageLightboxCenter.shared.step(-1) { return true }
            if event.keyCode == 124, ImageLightboxCenter.shared.step(1) { return true }
            // Esc: if the recent list is open, fold just that back to the input
            // first (one step "out"); only a second Esc closes the whole panel.
            // Works mid-request too — closing detaches the in-flight answer, which
            // finishes in the background and lands in Recent (see NotchModel).
            if event.keyCode == 53 {
                // An opened image is the topmost thing on the glass → first Esc
                // just puts it back down, before any panel-level step-out.
                if ImageLightboxCenter.shared.dismiss() { return true }
                // Clear confirmation armed → first Esc dismisses just the dialog,
                // before any panel-level step-out / close.
                if model.confirmingClear {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                        model.confirmingClear = false
                    }
                    return true
                }
                // `/` menu up → first Esc drops the command word and the menu with
                // it, landing back on the blank prompt. One step out, like folding
                // the recent list, not a panel close.
                if withAnimation(.spring(response: 0.34, dampingFraction: 0.82), {
                    model.dismissSlashMenu()
                }) { return true }
                // What's New open → same step-out: first Esc returns to the prompt.
                if model.showWhatsNew {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                        model.closeWhatsNew()
                    }
                    return true
                }
                if model.showHistory {
                    // Stepped Esc while filtering, unwinding the ⌘F summon in reverse:
                    //   1. non-empty query  → clear the query (keep the field open)
                    //   2. empty query, field up → close just the filter field
                    //   3. field down        → fold the list back to the prompt
                    // Must run before collapseHistory() — this catcher fires ahead of
                    // SwiftUI's own exit handling.
                    if !model.historySearchQuery.isEmpty {
                        model.historySearchQuery = ""
                        return true
                    }
                    if model.showHistoryFilter {
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                            model.showHistoryFilter = false
                        }
                        return true
                    }
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                        model.collapseHistory()
                    }
                    return true
                }
                // Agent detail page with a live run → first Esc STOPS that run,
                // keeping the whole trail on screen; a second Esc (now settled)
                // closes the panel. The page carries no cancel control of its own
                // — the tray row's two-step ✕ is behind the back chevron — so this
                // is the only stop verb while you're watching the run, and it
                // reads the way a terminal's Esc does. Not destructive in the
                // one-way sense: the session id survives, so a follow-up resumes
                // right where the run stopped.
                if let id = model.agentDetailTaskID,
                   AgentTaskManager.shared.cancel(taskID: id) {
                    return true
                }
                // Streaming → first Esc STOPS generation (XII-122), keeping the
                // partial answer on screen; a second Esc (now settled) closes the
                // panel as before. Stepping out one level at a time, same as the
                // history/settings unwinds above.
                if model.isStreaming {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                        model.stopStreaming()
                    }
                    return true
                }
                model.beginClose(sequenced: !reduceMotion)
                return true
            }
            // ← goes "back" to a fresh conversation from the thread view — also
            // while the answer is still loading/streaming (the back chevron is
            // visible then, and the round finishes detached into Recent). Only
            // when the follow-up field is empty, so a left-arrow while editing
            // still just moves the caret instead of leaving the thread. The
            // agent-detail page renders in `.idle` mode, so admit it explicitly
            // (via agentDetailTaskID) — otherwise ← is dead there and only the
            // header chevron backs out.
            // A *bare* ← only: ⌥←/⌃← are ordinary editing (and recordable) chords,
            // and the settings / what's new pages own no thread to back out of.
            if event.keyCode == 123,
               SummonHotKey.carbonModifiers(from: event.modifierFlags) == 0,
               !model.showWhatsNew,
               model.mode != .idle || model.agentDetailTaskID != nil,
               !model.hasText {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                    model.newChat()
                }
                return true
            }
            return false
        })
    }

    /// True when the key window's first responder is a text field editor — i.e. the
    /// user is typing in the prompt / follow-up / history-filter field. The
    /// answer-state action keys (XII-131) defer to it so ⌘C/⌘S/⌘R keep their normal
    /// editing meaning while a field is focused; only when nothing is being edited
    /// do they act on the answer. An `NSText` field editor is what AppKit installs
    /// as first responder for a focused `NSTextField`/`TextEditor`.
    private func fieldEditorIsFirstResponder() -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSText
    }
}

/// The measured natural widths of the copy-sense EARS — the content on each
/// side of the hardware notch. Reported up to `NotchIsland`, which adds the ear
/// insets and sizes/slides the island so each shoulder hugs its own content
/// (a different length in every language and stage) while the black center
/// stays fused to the physical camera housing.
struct SenseEarWidths: Equatable {
    var left: CGFloat = 0
    var right: CGFloat = 0
}

private struct SenseEarWidthsKey: PreferenceKey {
    static let defaultValue = SenseEarWidths()
    static func reduce(value: inout SenseEarWidths, nextValue: () -> SenseEarWidths) {
        let next = nextValue()
        value = SenseEarWidths(left: max(value.left, next.left),
                               right: max(value.right, next.right))
    }
}

/// The copy-sense rest content, in the two-eared compact idiom (the Dynamic
/// Island's): nothing can sit ON the camera housing — on a notched Mac those
/// pixels physically don't exist — so the hint splits across the shoulders the
/// flex opens on each side of it. Left ear: what will happen ("Set Reminder"),
/// then the write's dots, then the one-word verdict — the same slot
/// the busy dots use, so "working" always lives left of the notch. Right ear:
/// the key to press ("⌘C"), following the macOS menu convention of label left,
/// shortcut right; it folds shut the moment the offer is consumed. Each ear is
/// a pinned slot — content can never slide under the camera by construction.
private struct ClipboardSenseEars: View {
    let sense: NotchModel.ClipboardSense
    /// The drawn hardware-notch width the ears flank (content-free gap).
    let notchWidth: CGFloat
    /// The island's current ear slots (content + insets, animated by the
    /// island's own settle) — the ears lay out inside exactly these.
    let earLeft: CGFloat
    let earRight: CGFloat

    private var isHinting: Bool {
        if case .hinting = sense { return true }
        return false
    }

    /// A stable identity per visual stage, so SwiftUI transitions between stages
    /// (and not between, say, a note hint and a reminder hint's shared text).
    private var stageKey: String {
        switch sense {
        case .idle: return "idle"
        case .hinting(let p): return "hint-\(p.rawValue)"
        case .saving: return "saving"
        case .saved: return "saved"
        case .failed: return "failed"
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left ear — the outcome phrase, then the dots, then the verdict.
            ZStack {
                leftStage
                    .id(stageKey)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
            .animation(.easeInOut(duration: 0.22), value: stageKey)
            .frame(width: earLeft)

            // The camera gap — content-free by construction.
            Color.clear.frame(width: notchWidth)

            // Right ear — the key to press, only while the offer stands.
            ZStack {
                if isHinting {
                    earText("⌘C", color: Tokens.text3)
                        .background(GeometryReader { proxy in
                            Color.clear.preference(
                                key: SenseEarWidthsKey.self,
                                value: SenseEarWidths(right: proxy.size.width))
                        })
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.22), value: isHinting)
            .frame(width: earRight)
        }
        .frame(minHeight: 22)
    }

    @ViewBuilder
    private var leftStage: some View {
        Group {
            switch sense {
            case .hinting(let panel):
                earText(panel == .reminder ? L("sense.reminder") : L("sense.note"),
                        color: Tokens.text3)
            case .saving:
                ThinkingDots(dot: 4, spacing: 5)
                    .fixedSize()
            case .saved:
                earText(L("sense.saved"), color: Tokens.text4)
            case .failed:
                earText(L("sense.failed"), color: Tokens.text4)
            case .idle:
                EmptyView()
            }
        }
        .background(GeometryReader { proxy in
            Color.clear.preference(key: SenseEarWidthsKey.self,
                                   value: SenseEarWidths(left: proxy.size.width))
        })
    }

    /// Deliberately faint — a hint, not an announcement. `fixedSize` so the
    /// text NEVER truncates: while its slot is still settling it overflows
    /// (hidden by the island's clip) instead of drawing half a line.
    private func earText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.sf(11.5, weight: .regular))
            .tracking(0.3)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
    }
}

/// Same two-shoulder measurement as `SenseEarWidthsKey`, on its own key so the
/// background-work readout and the copy-sense hint can't smear widths into each
/// other while one crossfades out and the other in.
private struct WorkEarWidthsKey: PreferenceKey {
    static let defaultValue = SenseEarWidths()
    static func reduce(value: inout SenseEarWidths, nextValue: () -> SenseEarWidths) {
        let next = nextValue()
        value = SenseEarWidths(left: max(value.left, next.left),
                               right: max(value.right, next.right))
    }
}

/// A compact folded-state signal for the Agent workspace. The session's full
/// context meter and sub-agent tree live in the expanded tab; the resting notch
/// only identifies the highest-priority session state without obscuring the
/// physical camera area.
private struct CollapsedAgentStatusEars: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: AgentSessionState
    let announcement: AgentSessionPreviewAnnouncement?
    let notchWidth: CGFloat
    let earLeft: CGFloat
    let earRight: CGFloat

    private var icon: String {
        session.status.symbolName
    }

    private var label: String {
        announcement?.label ?? session.status.previewLabel
    }

    private var color: Color {
        (announcement?.tone ?? session.status.previewTone).color
    }

    var body: some View {
        HStack(spacing: 0) {
            // Label only. The sub-agent count is a detail of the session, not an
            // announcement about it, so it belongs to the expanded Agent tab's
            // card beside the context meter — the resting shoulder is too narrow
            // to carry both without truncating the state itself.
            Text(label)
                .font(.sf(9, weight: .medium))
                .foregroundStyle(Tokens.text2)
                .lineLimit(1)
                .fixedSize()
                .padding(.leading, 8)
                .frame(width: earLeft, alignment: .leading)

            Color.clear.frame(width: notchWidth)

            // The pulse re-rasterises the notch layer for as long as it runs, and
            // this ear now stays up for a whole session rather than a few
            // seconds, so it is honoured only when the user has not asked for
            // less motion — the expanded status icon already makes the same
            // concession.
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: earRight)
                .symbolEffect(.pulse, options: .repeating,
                              isActive: !reduceMotion
                                  && (session.status == .working || session.status == .planning))
        }
        .frame(minHeight: 22)
    }
}

/// The resting notch's media presence: the two shoulders deliberately leave the
/// physical camera housing clear while keeping the current track visible after
/// the main media workspace folds away.
private struct CollapsedNowPlayingEars: View {
    let media: MediaState
    let notchWidth: CGFloat
    let earLeft: CGFloat
    let earRight: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            artwork
                .frame(width: earLeft)
                // Nudged off centre, toward the island's edge — but only half as
                // far as the old wide shoulder allowed, or the glyph would sit on
                // the rim.
                .offset(x: -3)

            Color.clear.frame(width: notchWidth)

            PlaybackPulse()
                .frame(width: earRight)
        }
        .frame(minHeight: 22)
    }

    @ViewBuilder
    private var artwork: some View {
        if let data = media.artworkData, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            Image(systemName: media.source == .nowPlaying ? "globe" : "music.note")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 18, height: 18)
                .background(Color.indigo.opacity(0.66), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
    }
}

/// A tiny moving equalizer is clearer than static text in the resting notch:
/// it says audio is actively playing without competing with the physical notch.
private struct PlaybackPulse: View {
    @State private var pulsing = false

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            bar(restingHeight: 7, activeHeight: 15, delay: 0)
            bar(restingHeight: 13, activeHeight: 6, delay: 0.12)
            bar(restingHeight: 9, activeHeight: 17, delay: 0.24)
        }
        .frame(height: 20)
        .onAppear { pulsing = true }
        .onDisappear { pulsing = false }
    }

    private func bar(restingHeight: CGFloat, activeHeight: CGFloat, delay: Double) -> some View {
        Capsule()
            .fill(Color.green.opacity(0.92))
            .frame(width: 2.5, height: pulsing ? activeHeight : restingHeight)
            .animation(
                .easeInOut(duration: 0.46)
                    .repeatForever(autoreverses: true)
                    .delay(delay),
                value: pulsing)
    }
}

/// Mirrors the compact media treatment for AirPods as an active audio-output
/// device, but uses a stable check rather than playback motion.
private struct CollapsedAccessoryEars: View {
    let event: AccessoryConnectionEvent
    let notchWidth: CGFloat
    let earLeft: CGFloat
    let earRight: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "airpodspro")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Tokens.text2)
                .frame(width: earLeft)
                // Nudged off centre, toward the island's edge — but only half as
                // far as the old wide shoulder allowed, or the glyph would sit on
                // the rim.
                .offset(x: -3)

            Color.clear.frame(width: notchWidth)

            Image(systemName: event.isConnected ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle((event.isConnected ? Color.green : Color.red).opacity(0.92))
                .frame(width: earRight)
        }
        .frame(minHeight: 22)
    }
}

/// Same two-shoulder measurement, on its own key so the focus-timer
/// announcement can't smear widths into the copy-sense or busy ears.
private struct FocusEarWidthsKey: PreferenceKey {
    static let defaultValue = SenseEarWidths()
    static func reduce(value: inout SenseEarWidths, nextValue: () -> SenseEarWidths) {
        let next = nextValue()
        value = SenseEarWidths(left: max(value.left, next.left),
                               right: max(value.right, next.right))
    }
}

/// A focus-timer phase boundary, in the two-eared idiom the media and accessory
/// previews already use: what just ENDED on the left shoulder, what that started
/// on the right. It is the only notice the user gets while the panel is folded,
/// so it holds for `FocusTimerStore.transitionWindow` and then folds flat.
private struct CollapsedFocusTimerEars: View {
    let transition: FocusTimerTransition
    let notchWidth: CGFloat
    let earLeft: CGFloat
    let earRight: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            ear(symbol: leftSymbol, text: leftText, tint: Tokens.text2)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: FocusEarWidthsKey.self,
                                           value: SenseEarWidths(left: proxy.size.width))
                })
                .frame(width: earLeft)

            Color.clear.frame(width: notchWidth)

            ear(symbol: rightSymbol, text: rightText, tint: rightTint)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: FocusEarWidthsKey.self,
                                           value: SenseEarWidths(right: proxy.size.width))
                })
                .frame(width: earRight)
        }
        .frame(minHeight: 22)
    }

    /// `fixedSize` so the phrase NEVER truncates: while its slot settles it
    /// overflows (hidden by the island's clip) instead of drawing half a word.
    private func ear(symbol: String, text: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            Text(text).font(.sf(11.5, weight: .medium)).tracking(0.2).lineLimit(1)
        }
        .foregroundStyle(tint)
        .fixedSize()
    }

    private var leftSymbol: String {
        transition == .focusEnded ? "timer" : "cup.and.saucer"
    }

    private var rightSymbol: String {
        transition == .focusEnded ? "cup.and.saucer.fill" : "flame.fill"
    }

    private var leftText: String {
        L(transition == .focusEnded ? "focus.ear.focusOver" : "focus.ear.breakOver")
    }

    private var rightText: String {
        L(transition == .focusEnded ? "focus.ear.breakStarted" : "focus.ear.streakMarked")
    }

    private var rightTint: Color {
        transition == .focusEnded ? Tokens.accent : Color.orange.opacity(0.95)
    }
}

/// Same two-shoulder measurement again, on its own key so a notification burst
/// can't smear widths into the focus, work or copy ears.
private struct AlertEarWidthsKey: PreferenceKey {
    static let defaultValue = SenseEarWidths()
    static func reduce(value: inout SenseEarWidths, nextValue: () -> SenseEarWidths) {
        let next = nextValue()
        value = SenseEarWidths(left: max(value.left, next.left),
                               right: max(value.right, next.right))
    }
}

/// Bundle-ID → app icon, memoised. `NSWorkspace.icon(forFile:)` reads the app
/// bundle off disk, and a burst can re-render the ear several times a second, so
/// the lookup happens once per app per launch.
private enum AlertAppIcon {
    @MainActor private static var cache: [String: NSImage?] = [:]

    @MainActor static func image(forBundleID bundleID: String?) -> NSImage? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        if let hit = cache[bundleID] { return hit }
        let resolved = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[bundleID] = resolved
        return resolved
    }
}

/// A burst of notifications from one app: WHO on the left shoulder (its own
/// icon — no app can be named in twelve points of ear, but every one of them is
/// recognisable by its icon), HOW MANY on the right. Deliberately mute about
/// content: the banner itself already said what was in the message, and the
/// notch's job at rest is to say that something is waiting, not to repeat it.
private struct CollapsedNotificationEars: View {
    let burst: AlertNotificationBurst
    let notchWidth: CGFloat
    let earLeft: CGFloat
    let earRight: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            icon
                .frame(width: earLeft)
                // Nudged toward the island's edge, matching the AirPods glyph.
                .offset(x: -3)

            Color.clear.frame(width: notchWidth)

            Text(countLabel)
                .font(.sf(12.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(Tokens.text1)
                .fixedSize()
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: AlertEarWidthsKey.self,
                                           value: SenseEarWidths(right: proxy.size.width))
                })
                .frame(width: earRight)
        }
        .frame(minHeight: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("alert.notifications.a11y", burst.count, burst.appName))
    }

    /// The real app icon when we could resolve the bundle, a neutral bell when we
    /// could not — an ear that shows nothing is worse than an ear that shows
    /// "something arrived".
    @ViewBuilder private var icon: some View {
        if let image = AlertAppIcon.image(forBundleID: burst.bundleID) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)
        } else {
            Image(systemName: "bell.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Tokens.text2)
        }
    }

    /// Three digits is wider than the shoulder can carry without pushing the
    /// island past the point where it still reads as a notch.
    private var countLabel: String {
        burst.count > 99 ? "99+" : "\(burst.count)"
    }
}

/// The resting notch's background-work readout, in the same two-eared compact
/// idiom as `ClipboardSenseEars`. Running: the live doing-word on the left
/// shoulder — the chat round's actual tool line ("Searching the web…",
/// "Reading github.com…"), or a per-action verb for an agent Codex run —
/// and a once-a-second elapsed clock on the right, the collapsed twin of the
/// agent card's clock, replacing the old three-dot wave (the ticking time
/// is the "it's alive" signal; dots on top were dead weight).
/// When the work settles the ears fold flat — the notification banner already
/// said what finished; the resting notch keeps no tally.
private struct BackgroundWorkEars: View {
    enum Stage: Equatable {
        case running(verb: String, since: Date)
    }
    let stage: Stage
    /// The drawn hardware-notch width the ears flank (content-free gap).
    let notchWidth: CGFloat
    /// The island's current ear slots (content + insets, animated by the
    /// island's own settle) — the ears lay out inside exactly these.
    let earLeft: CGFloat
    let earRight: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A stable identity per verb, so SwiftUI crossfades one doing-word into the
    /// next instead of morphing the text in place.
    private var stageKey: String {
        switch stage {
        case .running(let verb, _): return "run-\(verb)"
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left ear — the verb while running.
            ZStack {
                leftStage
                    .id(stageKey)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
            .animation(.easeInOut(duration: 0.22), value: stageKey)
            .frame(width: earLeft)

            // The camera gap — content-free by construction.
            Color.clear.frame(width: notchWidth)

            // Right ear — the elapsed clock, only while running.
            ZStack {
                if case .running(_, let since) = stage {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        // Each tick rolls the changed digits with the system's
                        // numeric-text transition (the blurred flip Apple uses
                        // for its own clocks) instead of hard-cutting: only the
                        // digits that actually changed move.
                        let seconds = max(0, Int(context.date.timeIntervalSince(since)))
                        Text(NotchModel.formatAgentElapsed(TimeInterval(seconds)))
                            .font(.sf(11))
                            .monospacedDigit()
                            .contentTransition(.numericText(value: Double(seconds)))
                            .animation(reduceMotion ? nil : .snappy(duration: 0.3),
                                       value: seconds)
                            .foregroundStyle(Tokens.text4)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .background(GeometryReader { proxy in
                        Color.clear.preference(
                            key: WorkEarWidthsKey.self,
                            value: SenseEarWidths(right: proxy.size.width))
                    })
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.22), value: stageKey)
            .frame(width: earRight)
        }
        .frame(minHeight: 22)
    }

    @ViewBuilder
    private var leftStage: some View {
        Group {
            switch stage {
            case .running(let verb, _):
                // Deliberately faint, matching the copy-sense ears — a status,
                // not an announcement. `fixedSize` so the text never truncates:
                // while its slot is still settling it overflows (hidden by the
                // island's clip) instead of drawing half a line.
                Text(verb)
                    .font(.sf(11.5, weight: .regular))
                    .tracking(0.3)
                    .foregroundStyle(Tokens.text3)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .background(GeometryReader { proxy in
            Color.clear.preference(key: WorkEarWidthsKey.self,
                                   value: SenseEarWidths(left: proxy.size.width))
        })
    }
}

/// The continuous black→glass island that grows out of the notch.
struct NotchIsland: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var capabilities: NotchCapabilityStore
    @ObservedObject var utilities: UtilityCapabilityService
    /// The agent-Codex run — a minutes-long background task the collapsed
    /// notch reports right alongside detached Ask rounds (same busy ears, same
    /// finished-count badge).
    @ObservedObject private var agentManager = AgentTaskManager.shared
    /// Publishing the bridge here is what makes an incoming app-server callback
    /// immediately open the red-rimmed Agent surface rather than waiting for an
    /// unrelated model update to redraw the shell.
    @ObservedObject private var codexApprovals = CodexAppServerBridge.shared
    /// Same job for Claude Code, whose approvals arrive over the app's own
    /// `PreToolUse` hook socket rather than an app-server connection.
    @ObservedObject private var claudeApprovals = ClaudeHookBridge.shared
    @ObservedObject private var terminalCodexApprovals = CodexTerminalHookBridge.shared
    /// Status from every recent Codex/Claude session. This is separate from the
    /// permission transports: a session can be working, asking, plan-ready or
    /// completed even while it has no approval card to display.
    @ObservedObject private var agentSessions = AgentSessionActivityStore.shared
    /// The focus timer keeps running with the panel folded, and announces each
    /// phase boundary on these shoulders — the only notice the user gets.
    @ObservedObject private var focusTimer = FocusTimerStore.shared
    /// Notification bursts, read off the system's own banners. They preempt
    /// background work while the collapsed notch is visible.
    @ObservedObject private var alerts = AlertFeedStore.shared
    @Environment(\.notchMetrics) private var metrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How far the black bleeds above the screen's top edge, guaranteeing no gap.
    private let topBleed: CGFloat = 6

    /// Fallback width for the busy left ear on the first frame, before the
    /// verb's measured width lands (via `WorkEarWidthsKey`) — roughly what a
    /// short verb needs, so the ear doesn't blink open from zero.
    private let busyExtension: CGFloat = 48

    /// The glyph shoulders — album art / AirPods on the left, the pulse or the
    /// connection check on the right. Sized to the artwork (18pt) and the three
    /// pulse bars (~12pt) plus breathing room, NOT to a text ear: these carry no
    /// words, and the wider slots left the resting island stretched far past its
    /// content.
    private static let glyphEarLeft: CGFloat = 33
    private static let glyphEarRight: CGFloat = 27

    /// The copy-sense ears' measured content widths (via `SenseEarWidthsKey`),
    /// so each shoulder of the flex fits its own content — the phrase/dots/
    /// verdict on the left, the ⌘C key on the right — in whatever language and
    /// stage is showing.
    @State private var senseEarContent = SenseEarWidths()

    /// The background-work ears' measured content widths (via
    /// `WorkEarWidthsKey`) — the verb / count badge on the left, the elapsed
    /// clock on the right — kept apart from the copy-sense measurements so the
    /// two occupants can't smear widths into each other mid-crossfade.
    @State private var workEarContent = SenseEarWidths()

    /// The focus-timer announcement's measured content widths (via
    /// `FocusEarWidthsKey`) — the phase that ended on the left, what it started
    /// on the right — on their own key for the same reason.
    @State private var focusEarContent = SenseEarWidths()

    /// The notification ears' measured content widths (via `AlertEarWidthsKey`).
    @State private var alertEarContent = SenseEarWidths()

    /// Drives the running border's lap. The store publishes only on phase
    /// changes, so the sweep needs its own second hand.
    @State private var focusTick = Date()
    private let focusBorderTick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Breathing room on each side of an ear's content.
    private let senseEarPad: CGFloat = 11

    /// The transient "entry kick" — the cursor's momentum, absorbed by the
    /// glass. Set to a small displacement in the direction of approach the
    /// instant the island opens, then released to zero on an underdamped
    /// spring, so the form gets gently shoved and settles back. Deliberately
    /// subtle: the island is hinged to the bezel, so this reads as the material
    /// giving, never as the island flying around.
    @State private var kick = EntryKick.zero

    /// THIS screen's open state — gated on `activeDisplay` so hovering one
    /// screen's notch never unfurls the islands on the others. Every read that
    /// used to consult `model.open` goes through here (including the animation
    /// `value:`s — a display *switch* flips this while `model.open` stays true,
    /// and the fold/unfurl must still animate).
    private var isOpen: Bool {
        model.isOpen(on: metrics.displayID)
    }

    /// True when the panel is fully closed (on every display) but background
    /// work is still running — a detached Ask round streaming, or an agent
    /// Codex run working in its folder. The resting notch flexes into the busy
    /// ears: verb left, elapsed clock right. Gated on the GLOBAL `open`, not
    /// this display's `isOpen`: while the panel is open anywhere the work is on
    /// screen there, and the other displays' resting notches shouldn't claim it.
    /// Which single occupant the resting notch's shoulders are showing.
    ///
    /// One resolver, in priority order (order.md), rather than a flag per ear
    /// that has to negate every ear above it. That web was already four deep
    /// before notifications arrived and would have been five after —
    /// and every one of those negations is a chance for two ears to be on screen
    /// at once, which is exactly what the crossfade below would make obvious.
    ///
    /// It is also what makes the animation possible: a single `Equatable` value
    /// to key the transition on, so a swap between ANY two occupants animates,
    /// including the swaps nobody thought to enumerate.
    /// The ladder itself lives in `RestingNotchPriority`, as a value type over
    /// plain booleans, so the order in `order.md` can be pinned by unit tests
    /// instead of only being readable here. A wrong rank shows up in the app as
    /// one ear occasionally missing — which nobody reports as a bug — so this is
    /// exactly the kind of logic that must not be trapped inside a `View`.
    ///
    /// This property is only the adapter: it says what each condition *is*, and
    /// the resolver says which one wins.
    private typealias RestingEarSlot = RestingNotchSlot

    private var restingInputs: RestingNotchInputs {
        RestingNotchInputs(
            panelOpen: model.open,
            liveActivityEnabled: model.liveActivityEnabled,
            notifications: isNotificationAnnouncement,
            agentQuestion: agentQuestionSession != nil,
            agentAnnouncement: agentAnnouncementSession != nil,
            backgroundWork: model.roundsInFlight > 0 || agentRunning,
            accessoryEvent: capabilities.accessoryConnectionEvent != nil,
            focusTransition: focusTimer.transition != nil,
            agentSteady: agentSteadySession != nil,
            nowPlaying: NotchCapabilityPresentation.supportsCollapsedPreview(capabilities.media),
            clipboardSense: model.clipboardSense != .idle)
    }

    private var restingSlot: RestingNotchSlot {
        RestingNotchPriority.slot(for: restingInputs)
    }

    private var isNotificationAnnouncement: Bool {
        if case .notifications = alerts.announcement { return true }
        return false
    }

    private var busy: Bool { restingSlot == .work }

    /// A burst of notifications from one app — above background work.
    private var notificationBurst: AlertNotificationBurst? {
        guard restingSlot == .notifications,
              case .notifications(let burst) = alerts.announcement else { return nil }
        return burst
    }

    private var showingNotificationBurst: Bool { restingSlot == .notifications }

    /// An agent run the resting notch reports. Whether it shows AT ALL is
    /// `busy`'s call — Settings → Appearance ("Live activity") mutes every
    /// background flex globally; the run keeps going, the card and the finish
    /// notification are untouched, the collapsed notch just doesn't flex.
    private var agentRunning: Bool {
        capabilities.agenticModeEnabled && agentManager.isRunning
    }

    /// A permission request is a stronger state than ordinary background work:
    /// it needs the user's attention, so the island becomes the red-edged
    /// NotchFlow alert and opens directly on the dedicated Agent surface.
    private var agentPermissionPending: Bool {
        guard capabilities.agenticModeEnabled else { return false }
        return codexApprovals.hasPendingApprovals
            || claudeApprovals.hasPendingApprovals
            || terminalCodexApprovals.hasPendingApprovals
    }

    /// A session that has stopped and cannot go on until the user answers it.
    /// This outranks the work slot: everything ranked below is progressing on
    /// its own, and this is the one agent state that is not.
    ///
    /// A pending *permission* is excluded here and in both accessors below,
    /// because it does not use the shoulders at all — it opens the panel on the
    /// Agent tab outright (rank 0 in `order.md`).
    private var agentQuestionSession: AgentSessionState? {
        guard capabilities.agenticModeEnabled, !agentPermissionPending else { return nil }
        return agentSessions.sessions.first { $0.status == .question }
    }

    /// The five-second announcement of a state change — started, plan ready,
    /// done, session closed. Ephemeral, so it preempts the steady states below
    /// it and then releases them.
    ///
    /// Relying only on this window is what the steady accessor exists to fix: an
    /// externally discovered Planning or Working session can be correct in the
    /// roster yet never produce an announcement to ride in on.
    private var agentAnnouncementSession: AgentSessionState? {
        guard capabilities.agenticModeEnabled, !agentPermissionPending,
              let preview = agentSessions.preview, preview.isVisible()
        else { return nil }
        // A question holds its own, higher slot for as long as it stands, so
        // announcing it here too would only make it drop a rank when the five
        // seconds run out while the question itself is still unanswered.
        return preview.session.status == .question ? nil : preview.session
    }

    /// Work still under way. Only states that are still *happening* qualify:
    /// done, a finished plan and a closed session each get the announcement
    /// above and then let go, because a settled session that keeps claiming the
    /// resting notch is the same lie as one stuck on "Working".
    private var agentSteadySession: AgentSessionState? {
        guard capabilities.agenticModeEnabled, !agentPermissionPending else { return nil }
        return agentSessions.sessions.first {
            $0.status == .working || $0.status == .planning
        }
    }

    /// Whichever agent session currently owns the shoulders. Reading it back off
    /// the resolved slot means the three ranks are not re-tested in the view
    /// body — the ladder has already decided which one won.
    private var collapsedAgentSession: AgentSessionState? {
        switch restingSlot {
        case .agentQuestion:     return agentQuestionSession
        case .agentAnnouncement: return agentAnnouncementSession
        case .agentSteady:       return agentSteadySession
        default:                 return nil
        }
    }

    private var collapsedAgentAnnouncement: AgentSessionPreviewAnnouncement? {
        guard restingSlot == .agentAnnouncement else { return nil }
        return agentSessions.preview?.announcement
    }

    private var showingAgentStatus: Bool {
        switch restingSlot {
        case .agentQuestion, .agentAnnouncement, .agentSteady: return true
        default: return false
        }
    }

    /// The busy left ear's label — what the work is ACTUALLY doing right now,
    /// not a frozen verb. An agent Codex run outranks the chat line (the
    /// longer, heavier task defines the notch's mood): its activity stream
    /// maps to a verb per action kind. A chat round shows the same live
    /// tool-activity line the panel's detail row would ("Searching the web…",
    /// "Reading github.com…"), falling back to "Thinking" only between tools.
    private var busyVerb: String {
        if agentRunning {
            // With parallel runs, the ear voices the freshest activity any of
            // them reported — one verb for the whole fleet.
            let running = agentManager.runningTasks
            if let task = running.last(where: { $0.activity != nil }) ?? running.first {
                return Self.agentVerb(for: task.activity)
            }
        }
        if let activity = model.backgroundActivity, !activity.isEmpty {
            return activity
        }
        return L(model.backgroundWriting ? "busy.writing" : "busy.thinking")
    }

    /// Map the agent's activity line to an ear-sized verb: the raw lines
    /// ("$ npm test", "Editing Foo.swift") run long and jitter the ear's width,
    /// so the ear names the *kind* of action and leaves the detail to the card.
    private static func agentVerb(for activity: String?) -> String {
        guard let activity, !activity.isEmpty else { return L("busy.working") }
        if activity.hasPrefix("$ ")         { return L("busy.running") }
        if activity.hasPrefix("Editing ")   { return L("busy.editing") }
        if activity.hasPrefix("Searching ") { return L("busy.searching") }
        if activity.hasPrefix("Reading ")   { return L("busy.searching") }
        if activity == L("agent.thinking") { return L("busy.thinking") }
        return L("busy.working")
    }

    /// When the oldest still-running background task started — the busy right
    /// ear's clock counts from here, so it reads as total time under way (not
    /// time since the panel folded).
    private var busySince: Date {
        var start = model.busySince ?? Date()
        if agentRunning,
           let earliest = agentManager.runningTasks.map(\.startedAt).min() {
            start = min(start, earliest)
        }
        return start
    }

    /// True when the resting notch is offering (or narrating) a clipboard
    /// capture. Gated on the GLOBAL `open` like `busy`, and yields to the busy
    /// dots — an in-flight answer outranks a copy hint for the one strip.
    private var sensing: Bool { restingSlot == .clipboardSense }

    /// A focus phase just ended: the five-second hand-off between phases. Ranks
    /// above the music (an ambient state) and below the AirPods check (a physical
    /// action the user just took, and the shorter-lived of the two). Yields to
    /// in-flight work and honours the global Live activity switch.
    private var showingFocusTransition: Bool { restingSlot == .focusTransition }

    /// The running lap. Independent of every ear above — it is the island's edge,
    /// not its shoulders, so an AirPods check or a track can sit inside a session
    /// that is still being traced. Resting only, and mute when Live activity is
    /// switched off.
    private var showingFocusBorder: Bool {
        !model.open && model.liveActivityEnabled && focusTimer.phase != .ready
    }

    /// Music gets a persistent, quiet presence in the resting notch. It yields
    /// to agent work (which needs the progress space) and never coexists with
    /// the clipboard offer, so the hardware gap remains uncluttered.
    private var showingNowPlayingPreview: Bool { restingSlot == .nowPlaying }

    /// Top of the resting stack, under in-flight work: it takes the shoulders
    /// from the music AND from a focus hand-off. The connection is a
    /// three-second announcement (the capability store expires it) tied to
    /// something the user physically just did; the track and the session are both
    /// standing states that come straight back.
    private var showingAccessoryPreview: Bool { restingSlot == .accessory }

    /// The resting notch's LEFT flex — the busy verb, or the copy-sense left ear
    /// (phrase → dots → verdict), sized to its measured content. The occupants
    /// never coexist (`sensing` yields to `busy`).
    private var earLeft: CGFloat {
        // Same order as the layers below: a notification burst, then work,
        // then the rest.
        if showingNotificationBurst { return Self.glyphEarLeft }
        if busy {
            return workEarContent.left > 0
                ? workEarContent.left + senseEarPad * 2 : busyExtension
        }
        if showingAgentStatus { return 64 }
        // Same order as the layers above: AirPods, then a focus hand-off, then
        // the music.
        if showingAccessoryPreview { return Self.glyphEarLeft }
        if showingFocusTransition {
            return focusEarContent.left > 0 ? focusEarContent.left + senseEarPad * 2 : busyExtension
        }
        if showingNowPlayingPreview { return Self.glyphEarLeft }
        if sensing, senseEarContent.left > 0 {
            return senseEarContent.left + senseEarPad * 2
        }
        return 0
    }

    /// The resting notch's RIGHT flex — the busy elapsed clock while work runs,
    /// or the copy-sense ⌘C ear while the offer stands (it folds shut on
    /// confirm).
    private var earRight: CGFloat {
        if showingNotificationBurst {
            return alertEarContent.right > 0
                ? alertEarContent.right + senseEarPad * 2 : Self.glyphEarRight
        }
        if busy {
            return workEarContent.right > 0
                ? workEarContent.right + senseEarPad * 2 : 0
        }
        if showingAgentStatus { return Self.glyphEarRight }
        if showingAccessoryPreview { return Self.glyphEarRight }
        if showingFocusTransition {
            return focusEarContent.right > 0 ? focusEarContent.right + senseEarPad * 2 : busyExtension
        }
        if showingNowPlayingPreview { return Self.glyphEarRight }
        guard sensing, senseEarContent.right > 0 else { return 0 }
        return senseEarContent.right + senseEarPad * 2
    }

    /// The click level's hover acknowledgement is live on THIS island: the notch
    /// is flexed a few points out under the pointer, with the panel still folded.
    /// Scoped to this display so the pointer on one screen doesn't nudge the
    /// resting notch on every other one.
    /// Whether the click level's flex is raised for THIS island. Deliberately
    /// free of `isOpen`: it is the key the peek animation is scoped to, and if it
    /// flipped on the open edge the peek's own spring would fire on that
    /// transaction and take the unfurl with it. The rendered swell is what
    /// collapses on the open (`peekScaleX`/`peekScaleY` read `isOpen`), so it
    /// merges into the expansion on the open spring; the flag itself is retired a
    /// tick later by the peek watch, with nothing left on screen to move.
    private var peeking: Bool {
        model.isPeeking(on: metrics.displayID)
    }

    /// The click level's acknowledgement, as a scale on the composited island —
    /// deliberately NOT a layout change. Growing the frame and the corner radius
    /// re-laid out the island and rebuilt the whole glass stack (native glass
    /// region, the blurred shadow's cached texture, the rim stroke, the
    /// compositing group) on every frame — for a move of a few points, which
    /// layout then quantizes to whole pixels, so the flex crept across three or
    /// four pixel steps instead of gliding. A scale is a GPU transform:
    /// sub-pixel, no relayout, nothing re-rendered.
    ///
    /// The two axes are scaled SEPARATELY, and neither is `hoverPeekOut / width`.
    /// A single uniform scale grows a wide, flat shape almost entirely sideways —
    /// 10pt across, 4pt down — which reads as the notch stretching into its busy
    /// ears, not as it leaning out toward you. These two put the same `hoverPeekOut`
    /// on every exposed edge instead: the island dilates, so the gesture has no
    /// direction of its own beyond "out".
    private var peekScaleX: CGFloat {
        guard peeking, !isOpen else { return 1 }
        return (width + NotchModel.hoverPeekOut * 2) / max(width, 1)
    }

    private var peekScaleY: CGFloat {
        guard peeking, !isOpen else { return 1 }
        let h = max(metrics.restHeight, 1)
        return (h + NotchModel.hoverPeekOut) / h
    }

    /// Where the island's top-center scale anchor falls inside the resting zone's
    /// own box — the zone is `topBleed` taller than the island it sits in, and its
    /// top hangs that far above the screen edge the outer scale hinges on. The
    /// camera dot and the ears counter-scale about THIS point, which is what keeps
    /// the drawn lens on the physical camera while the shell dilates around it.
    private var peekContentAnchor: UnitPoint {
        UnitPoint(x: 0.5, y: topBleed / max(metrics.restHeight + topBleed, 1))
    }

    /// True when a click on the resting island is the open gesture. Only then is
    /// the tap target armed: mounting it unconditionally would make the resting
    /// notch swallow clicks on every level, and on a virtual notch (drawn over an
    /// external screen's menu bar) those clicks belong to the menu bar.
    private var clickToOpenArmed: Bool {
        !isOpen && model.hoverSensitivity.opensOnClickOnly
    }

    private var width: CGFloat {
        if isOpen { return model.openWidth }
        let shoulderWidth = metrics.notchWidth + earLeft + earRight
        return shoulderWidth
    }

    private var bottomRadius: CGFloat {
        isOpen ? 30 : Tokens.notchRestRadius
    }

    /// An overlay is not part of a view's intrinsic height, so the force-click
    /// hand-off explicitly reserves the space its instructional card needs.
    private var forceClickDialogMinimumHeight: CGFloat? {
        guard isOpen, model.forceClickLookupConflict != nil else { return nil }
        return ForceClickLookupDialog.minimumIslandHeight
    }

    private func handleIslandHover(_ inside: Bool) {
        // Hover-only chrome (the result header's trailing chips) reads this.
        model.pointerInside = inside
        if inside {
            model.hoverEntered(on: metrics.displayID,
                               velocity: MouseVelocityTracker.shared.entryVelocity())
        } else {
            model.collapseOnLeave(from: metrics.displayID, sequenced: !reduceMotion)
        }
    }

    private func handleFocusBorderTick(_ date: Date) {
        // The focus border is the only consumer of this timer.
        if showingFocusBorder { focusTick = date }
    }

    private func handleAgentPermissionPendingChange(_ pending: Bool) {
        model.setDirectApprovalPending(pending)
        // Companion mode intentionally leaves Codex and Claude to their native
        // terminal approval prompts. Never turn Agentic mode back on merely
        // because an external session is waiting.
        guard pending, capabilities.agenticModeEnabled else { return }
        capabilities.workspaceTab = .agent
        model.openPanel(on: metrics.displayID)
    }

    @ViewBuilder
    private var focusProgressOverlay: some View {
        if showingFocusBorder {
            FocusProgressBorder(shape: NotchProgressTrace(bottomRadius: bottomRadius),
                                progress: focusTimer.progress(at: focusTick),
                                tint: focusTimer.phase == .break ? Tokens.success : Tokens.accent)
                // One step per tick, glided over the second it covers, so the
                // border creeps instead of stepping.
                .animation(.linear(duration: 1), value: focusTick)
                .transition(.opacity)
        }
    }

    var body: some View {
        // The island sizes its HEIGHT to its content (the constant black zone +,
        // when open, the glass body). We deliberately do NOT pin height to a
        // measured value — that creates a clip↔measure deadlock. Width is the
        // only explicit dimension; height follows the VStack intrinsically, and
        // the layout `.animation` springs the grow/shrink.
        // Erase after the structural shell. The island intentionally has a long
        // interaction modifier chain below; keeping its chrome in a separate
        // type boundary avoids SwiftUI's compiler type-checking the entire
        // surface as one expression.
        AnyView(VStack(spacing: 0) {
            // Constant black "hardware" zone with the camera dot. It overshoots
            // the screen's top edge by `topBleed` so the black always reaches the
            // very top — no sliver of wallpaper between the bezel and the form.
            ZStack {
                // No camera dot on screens without a real camera housing — a
                // fake lens on an external monitor reads as a smudge, not charm.
                if !isOpen, metrics.hasHardwareNotch {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color(white: 0.17), Color(white: 0.02)],
                                center: UnitPoint(x: 0.35, y: 0.30),
                                startRadius: 0, endRadius: 5
                            )
                        )
                        .frame(width: 7, height: 7)
                        // Uneven ears shift the island's center off the notch
                        // zone's center by (L−R)/2 — push the lens dot back by
                        // exactly that so it never drifts off the physical
                        // camera, whatever mix of ears is out.
                        .offset(x: (earLeft - earRight) / 2, y: topBleed / 2)
                }

                // The background-work readout, in the two-eared idiom: while
                // work runs, the verb on the left shoulder and a once-a-second
                // elapsed clock on the right (the collapsed twin of the
                // agent card's clock — no dots; ticking time IS the "it's
                // alive" signal). When the last task settles the ears fold
                // flat again. It all lives inside the island's own black
                // zone — one material, one form — which is what makes the flex
                // read as the notch working, not as a badge stuck beside it.
                // A burst of notifications from one app: its icon left, its
                // count right, for three seconds per app.
                if let burst = notificationBurst {
                    CollapsedNotificationEars(
                        burst: burst,
                        notchWidth: metrics.notchWidth,
                        earLeft: earLeft,
                        earRight: earRight)
                        .offset(y: topBleed / 2)
                        .transition(earTransition)
                }

                if busy {
                    BackgroundWorkEars(
                        stage: .running(verb: busyVerb, since: busySince),
                        notchWidth: metrics.notchWidth,
                        earLeft: earLeft,
                        earRight: earRight)
                        .offset(y: topBleed / 2)
                        .transition(earTransition)
                }

                if showingAgentStatus, let session = collapsedAgentSession {
                    CollapsedAgentStatusEars(
                        session: session,
                        announcement: collapsedAgentAnnouncement,
                        notchWidth: metrics.notchWidth,
                        earLeft: earLeft,
                        earRight: earRight)
                        .offset(y: topBleed / 2)
                        .transition(earTransition)
                }

                // A focus block (or its break) just ran out: what ended on the
                // left shoulder, what it started on the right, for five seconds.
                if showingFocusTransition, let transition = focusTimer.transition {
                    CollapsedFocusTimerEars(
                        transition: transition,
                        notchWidth: metrics.notchWidth,
                        earLeft: earLeft,
                        earRight: earRight)
                        .offset(y: topBleed / 2)
                        .transition(earTransition)
                }

                if showingNowPlayingPreview {
                    CollapsedNowPlayingEars(
                        media: capabilities.media,
                        notchWidth: metrics.notchWidth,
                        earLeft: earLeft,
                        earRight: earRight)
                        .offset(y: topBleed / 2)
                        .transition(earTransition)
                }

                if showingAccessoryPreview, let accessoryEvent = capabilities.accessoryConnectionEvent {
                    CollapsedAccessoryEars(
                        event: accessoryEvent,
                        notchWidth: metrics.notchWidth,
                        earLeft: earLeft,
                        earRight: earRight)
                        .offset(y: topBleed / 2)
                        .transition(earTransition)
                }

                // The copy-sense ears: the copied text read as a note/reminder,
                // and the notch is offering to file it. Both shoulders extend at
                // once — the outcome phrase on the left, the ⌘C key on the right
                // (menu convention: label left, shortcut right) — and the camera
                // gap between them is content-free by construction, so text can
                // never slide under the housing and render half-hidden.
                if sensing {
                    ClipboardSenseEars(sense: model.clipboardSense,
                                       notchWidth: metrics.notchWidth,
                                       earLeft: earLeft,
                                       earRight: earRight)
                        .offset(y: topBleed / 2)
                        .transition(earTransition)
                }
            }
            .frame(height: metrics.restHeight + topBleed)
            // THE transaction the ear transitions ride. Every occupant is chosen
            // by `restingSlot`, so keying here animates every possible swap —
            // including the ones nobody enumerated (a call landing on top of a
            // Pomodoro hand-off, music returning after an agent run finishes).
            //
            // Without this the ears popped: the store's `@Published` change
            // arrives in no animation transaction of its own, so the `if` swapped
            // its content instantly while only the shoulder width sprang. That
            // mismatch — instant content, moving frame — is exactly what read as
            // abrupt.
            .animation(earSwap, value: restingSlot)
            // Undo the click level's dilation for the zone's *contents*: the shell
            // grows, the camera lens and the ears hold still. Exact inverse about
            // the same point in space, on the same transaction as the outer scale.
            .scaleEffect(x: 1 / peekScaleX, y: 1 / peekScaleY, anchor: peekContentAnchor)

            // The glass body unfurls below the notch zone when open. On the way out
            // it fades FIRST (driven by `model.closing`), while the shell holds its
            // expanded size — then `beginClose` drops `open`, this view leaves, and
            // the shell retracts. So content dissolves, then the form collapses,
            // instead of both clamping shut on one transaction. The `.opacity`
            // transition still carries the open fade-in (and the final unmount).
            if isOpen {
                NotchBody(model: model, capabilities: capabilities, utilities: utilities)
                    .opacity(model.closing ? 0 : 1)
                    // Ease the dissolve over the model's content-fade window so it
                    // completes just as `beginClose` fires the shell retract.
                    .animation(.easeOut(duration: NotchModel.closeContentFade), value: model.closing)
                    // The pre-tear feel: the body gives a few points toward the
                    // pull (tanh-saturated), so the glass reads as grabbed
                    // before the window tears free. Release springs it home on
                    // `detachDragEnded`'s transaction.
                    .offset(detachLean)
                    .opacity(model.detachDrag == nil ? 1 : 0.94)
                    .transition(.opacity)
            }
        })
        // `ForceClickLookupDialog` lives in an overlay, which cannot enlarge the
        // island by itself. Give its visual hand-off enough vertical runway so
        // its screenshot stays visible and the card keeps an intentional rhythm.
        .frame(width: width)
        .frame(minHeight: forceClickDialogMinimumHeight, alignment: .top)
        // The box every hover tooltip clamps itself inside. It belongs HERE, on
        // the island's own width — the `NotchShape` clip below follows this exact
        // frame, so this is the wall a capsule actually gets chopped against. (It
        // used to be published on the screen-wide hosting canvas in
        // `AppDelegate.makePanel`, which never clamped anything.)
        .notchTooltipClipBox()
        .padding(.top, -topBleed)   // pull the form up so it bleeds off the top
        .background(GlassMaterial(bottomRadius: bottomRadius,
                                  expanded: isOpen,
                                  cameraZone: metrics.restHeight))
        // The destructive "Clear recent history?" confirmation floats centered over
        // the whole island (scrim + card), instead of a popover anchored under the
        // Clear pill that landed it near the bottom of the panel. Mounted here so it
        // centers in the full glass body; clipped to the island shape below.
        //
        // Gated on THIS display's `isOpen`: `confirmingClear` is one flag on the
        // shared model, but every screen in `.all` mode hosts its own panel — so
        // without the gate the card also rendered inside the *resting* notch on the
        // other screens, where the shape clipped it down to one stray button peeking
        // out of the black zone.
        .overlay {
            if model.confirmingClear, isOpen {
                ClearHistoryConfirm(
                    lastDayCount: model.historyCountWithinLastDay,
                    totalCount: model.historyClearTotalCount,
                    agentOnly: model.agentComposeActive,
                    onCancel: {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                            model.confirmingClear = false
                        }
                    },
                    onConfirm: { scope in
                        // Two beats, not one: the card leaves first while the
                        // island holds its height, THEN the emptied recent list
                        // collapses on the panel's standard module spring. Clearing
                        // immediately (and outside the transaction) yanked the
                        // island short mid-dismiss, re-centering and clipping the
                        // still-fading card — a visible jump.
                        //
                        // The confirm exit is a short ease-out, NOT the spring the
                        // Cancel path uses, and beat two is chained off a matching
                        // delay rather than the spring's completion: waiting for a
                        // 0.34-response spring to settle put ~half a second of dead
                        // air between the click and anything moving, so the list
                        // looked like it cleared on a delayed hard cut. You clicked;
                        // the card should be gone and the rows already going.
                        model.bulkClearing = true      // arms the rows' dissolve —
                        // recorded a full render BEFORE the removal below, because a
                        // removal transition comes from the view's last render.
                        withAnimation(.easeOut(duration: 0.16)) {
                            model.confirmingClear = false
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                                model.clearHistory(scope: scope)
                            } completion: {
                                model.bulkClearing = false
                            }
                        }
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .erasingNotchViewType()
        // The Force Click gate, mounted on the island for the same reason as the
        // Clear card above: its scrim has to reach the glass edges. Inside
        // Settings it only covered the settings body, leaving the panel's padding
        // showing as pale strips down both sides and along the bottom.
        .modifier(ForceClickLookupGate(model: model, isOpen: isOpen))
        // An opened image (see `ImageLightbox`) covers the panel it came from:
        // hosted here, above the body but inside the island's own clip, so the
        // backdrop blur stops at the glass edge like every other overlay.
        .imageLightboxHost(topInset: metrics.restHeight)
        .clipShape(NotchShape(bottomRadius: bottomRadius))
        // The "slab of glass" look (per the reference): the dark body holds and
        // stays readable, the top reads near-solid and the lower body eases more
        // translucent (that vertical gradient lives in GlassMaterial's veil), and
        // the EDGES are defined by a lit beveled rim — bright along the bottom and
        // sides, brightest at the rounded corners. Stamped on top of the composited
        // island so the highlight traces the edge crisply instead of being clipped.
        .overlay(IslandRim(shape: NotchShape(bottomRadius: bottomRadius),
                           attention: agentPermissionPending))
        // A focus session running behind the folded panel, drawn as one lap of
        // the island's own edge: blue while focusing, green through the break,
        // arriving back at the top exactly when the phase ends. Resting only —
        // the open panel has the countdown itself, and a border creeping around
        // a panel being read would be noise.
        .overlay { focusProgressOverlay }
        // A settled detached window dragged over the notch: the island swells a
        // touch to say it'll take the session back on release.
        .scaleEffect(model.detachMergeHint ? 1.02 : 1, anchor: .top)
        .animation(.spring(response: 0.32, dampingFraction: 0.7), value: model.detachMergeHint)
        // The click level's hover acknowledgement — the resting notch dilating a
        // few points under the pointer. Top-anchored so it hinges off the bezel
        // and the black stays fused to the housing. This one `.animation` carries
        // the counter-scale inside the resting zone too (same subtree, same
        // transaction), which is why the lens never wobbles against the shell.
        .scaleEffect(x: peekScaleX, y: peekScaleY, anchor: .top)
        .animation(peekSettle, value: peeking)
        // The entry kick deforms the whole composited island — anchored at the
        // top edge so it hinges off the bezel. The system glass backdrop does
        // NOT ride along with SwiftUI render transforms, so the deform briefly
        // desyncs the veil/rim from the glass region — but with the panel's
        // base darkening baked into the glass material itself (see
        // `nativeGlass(in:)`), the slivers that escape on either side read as
        // the same smoked glass / dark veil, not a bright band. That's what
        // makes the whole-island lean safe; on the content alone the kick was
        // imperceptible (it plays out while the body is still fading in).
        // `ignoredByLayout()` keeps the deform render-only: nothing reads the
        // island's transformed frame, and letting layout see it would force
        // anchor/geometry recomputation on every frame of the kick — right on
        // top of the open spring's own per-frame layout work.
        .modifier(EntryKickEffect(tx: kick.tx, shear: kick.shear, squash: kick.squash).ignoredByLayout())
        .contentShape(NotchShape(bottomRadius: bottomRadius))
        // The click level's target: at rest, on that level only, the island IS a
        // button. Masked rather than conditionally mounted so the shape stops
        // claiming clicks the moment the level changes back.
        //
        // A zero-distance drag, NOT a tap: `TapGesture` resolves on mouse-UP, so
        // the panel sat still for however long the press lasted and then unfurled
        // — the click read as laggy against a hover-open, which fires the instant
        // the pointer arrives. This opens on the press itself. (`notchClicked`
        // ignores the rest of the drag's ticks.)
        .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in model.notchClicked(on: metrics.displayID) },
                 including: clickToOpenArmed ? .gesture : .none)
        .erasingNotchViewType()

        // Tear-off lives on the header strip only (the grips in NotchBody's
        // resultHeader / agentDetailHeader) — dragging the body or free glass
        // must never split the session by accident.
        // Slide the whole form so its black CENTER (not its geometric center)
        // stays fused to the hardware notch: the island is centered in the
        // canvas, so uneven ears would otherwise drag the camera zone off the
        // physical housing. (R−L)/2 is exactly that correction — for busy
        // (L=48, R=0) it reduces to the familiar −24pt right-edge pin; for even
        // ears it's zero and the form blooms symmetrically. Sits BEFORE the
        // isOpen animation so an open/close morph carries the slide on the
        // same spring as the width.
        .offset(x: (earRight - earLeft) / 2)
        // Spring expand (eased by how hard the cursor arrived — see `openSpring`);
        // the collapse settles on `closeSpring` (XII-108) so the shell drops back
        // with a touch of gravity/rebound instead of a flat clamp — EXCEPT when
        // the close lands on the extended busy rest. The rebound's undershoot
        // briefly renders the island SMALLER than the hardware notch (shorter
        // and narrower both); on a normal close that whole dip hides inside the
        // black cutout, but the busy extension sits over visible screen, so the
        // same dip reads as the "notch" shrinking away from the bezel. A busy
        // close takes the overshoot-free settle instead.
        .animation(isOpen ? openSpring : (earLeft + earRight > 0 ? busySettle : closeSpring), value: isOpen)
        // The busy/sense extension's own grow/retract (no open/close involved —
        // e.g. the detached answer lands while the notch rests) must NOT bounce:
        // an underdamped settle undershoots the rest width, and for a beat the
        // drawn island is NARROWER than the hardware notch it's impersonating —
        // physically impossible, and exactly the tell that breaks the illusion.
        // A near-critically-damped, unhurried ease reads as the notch quietly
        // relaxing back into the bezel. (A close that lands ON the extended
        // rest still rides `closeSpring` via the isOpen animation above — its
        // target there is wider than the notch, so its rebound never dips
        // below the hardware width.)
        .animation(busySettle, value: earLeft)
        .animation(busySettle, value: earRight)
        // The kick fires on the open *edge*, reading the entry vector the hover
        // just recorded. Closing lets any residual kick decay on its own.
        .onChange(of: isOpen) { _, nowOpen in
            if nowOpen { applyEntryKick() }
        }
        // The ears' measured content widths feed `earLeft`/`earRight`; the flex
        // then re-settles (on the same `busySettle` keyed below) whenever a
        // stage's content changes size — hint phrase → dots → verdict, and the
        // ⌘C ear folding shut on confirm.
        .onPreferenceChange(SenseEarWidthsKey.self) { senseEarContent = $0 }
        .onPreferenceChange(WorkEarWidthsKey.self) { workEarContent = $0 }
        .onPreferenceChange(FocusEarWidthsKey.self) { focusEarContent = $0 }
        .onPreferenceChange(AlertEarWidthsKey.self) { alertEarContent = $0 }
        // Opening the panel is the user acknowledging what was waiting, so every
        // per-app tally resets.
        .onChange(of: model.open) { _, nowOpen in
            if nowOpen { alerts.notchDidOpen(now: Date()) }
        }
        .onChange(of: agentPermissionPending, perform: { pending in
            handleAgentPermissionPendingChange(pending)
        })
        .onChange(of: capabilities.agenticModeEnabled) { _, enabled in
            // A bridge may already have a live request when the user restores
            // Agentic mode. Route that request immediately instead of waiting
            // for a second approval event.
            guard enabled, agentPermissionPending else { return }
            handleAgentPermissionPendingChange(true)
        }
        .onAppear {
            model.setDirectApprovalPending(agentPermissionPending)
        }
        .onReceive(focusBorderTick, perform: handleFocusBorderTick)
        // Keep the model's resting-notch hover rect in step with the ears —
        // hovering the verb/clock, the finished badge, or the copy hint must
        // count as hovering the notch (see `pointerInsideRestingNotch`).
        .onAppear { model.registerRestingEars(left: earLeft, right: earRight) }
        .onChange(of: earLeft) { _, _ in
            model.registerRestingEars(left: earLeft, right: earRight)
        }
        .onChange(of: earRight) { _, _ in
            model.registerRestingEars(left: earLeft, right: earRight)
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.72), value: model.openWidth)
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: model.mode)
        // The note-save feedback line (Saving… → Added to Notes → gone) changes the
        // body's intrinsic height. Without these, only the inner idleView spring
        // governed that change — it animates the line's own fade/scale but does NOT
        // propagate up to this island's frame, glass background, or clip shape, so
        // the outer form resized on a mismatched (or no) transaction while the inner
        // text eased out. Keying the island's grow/shrink on the same note states,
        // with the SAME spring idleView uses (response 0.42, damping 0.82), makes the
        // whole island — content and glass shell — settle as one smooth motion.
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: model.noteSaving)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: model.lastSavedNote)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: model.noteError)
        // Expanding / collapsing the Recent list changes the body's intrinsic
        // height. Like the note-save line above, that height change must drive the
        // island's frame, glass background AND clip shape on ONE spring — otherwise
        // the inner `moduleTransition` animates the list's own fade/slide while the
        // outer shell resizes on a mismatched (or no) transaction. The visible
        // symptom was exactly that desync: the black notch cap and the glass veil
        // (whose gradient stops are derived from the live, animating height) redrew
        // out of step with the growing form, so the black zone and frost appeared to
        // "jump" as the list opened. Keying the island here — same spring the clock
        // toggle uses — makes the whole form grow as one piece, so the glass reads
        // as one continuous surface unfurling rather than a stack snapping open.
        // `showHistoryFilter` is included because revealing the ⌘F field also nudges
        // the height, and it should ride the same coherent motion.
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: model.showHistory)
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: model.showHistoryFilter)
        // NOT keyed here: the prompt box growing a line. That one is owned at its
        // source instead — `PromptField`'s height report writes `inputHeight` inside
        // an explicit `withAnimation` (see `NotchBody.promptGrowth`), so the row, the
        // chrome laid out under it AND this island's frame / glass / clip all ride one
        // transaction. Keying it here as well was tried and does nothing: a
        // `.animation(…, value:)` at this level only governs changes SwiftUI already
        // decided to animate, and an un-transacted state write out of an AppKit
        // callback isn't one of them.
        // Publish the island's live frame (canvas-window space) so the model can
        // verify hover events against the pointer's real position — the raw
        // enter/exit stream includes artifacts synthesized by this very frame
        // animating (see `NotchModel.pointerInsideIsland`). A plain var write on
        // the model, deliberately not @Published: this fires per frame during
        // the open/close springs.
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { model.registerIslandFrame(proxy.frame(in: .global), for: metrics.displayID) }
                .onChange(of: proxy.frame(in: .global)) { _, frame in
                    model.registerIslandFrame(frame, for: metrics.displayID)
                }
        })
        .onHover(perform: handleIslandHover)
        .frame(maxWidth: .infinity, alignment: .center)   // center within canvas
    }

    // MARK: - Tear-off (detach drag)

    /// How far the body leans with a live pre-tear pull: a few points, heavily
    /// saturated — a grabbed slab of glass giving, not content sliding away.
    private var detachLean: CGSize {
        guard let drag = model.detachDrag else { return .zero }
        let lean = NotchModel.detachRubberized(drag.translation, limit: 16)
        return CGSize(width: lean.width, height: max(lean.height, -6))
    }

    // MARK: - Entry physics

    /// 0…1 measure of how energetically the cursor arrived. √-compressed so the
    /// difference between a lazy drift and a normal move reads, while slamming
    /// the mouse can't push past the cap.
    private var entryEnergy: CGFloat {
        let v = model.entryVelocity
        let speed = (v.dx * v.dx + v.dy * v.dy).squareRoot()
        return min(speed / 2500, 1).squareRoot()
    }

    /// The unfurl spring, eased by approach speed. The resting end is *calmer*
    /// than the old fixed spring (longer response, more damping — an unhurried
    /// bloom); a fast entry only tightens it back to roughly the old feel, so
    /// momentum shows up as the energetic end of the range, never as haste
    /// beyond what the panel already had.
    private var openSpring: Animation {
        guard !reduceMotion else {
            return .spring(response: 0.50, dampingFraction: 0.85)
        }
        let s = entryEnergy
        return .spring(response: 0.50 - 0.06 * s,
                       dampingFraction: 0.82 - 0.10 * s)
    }

    /// The busy extension's grow/retract at rest: gentle and, crucially,
    /// overshoot-free (dampingFraction ≥ 0.95 keeps the width from ever dipping
    /// below the hardware notch — see the comment at the use site).
    private var busySettle: Animation {
        guard !reduceMotion else { return .easeOut(duration: 0.30) }
        return .spring(response: 0.50, dampingFraction: 0.95)
    }

    /// The handover between two occupants of the shoulders.
    ///
    /// Faster than `busySettle` (which carries the WIDTH) on purpose: the two are
    /// one motion, and the content must not still be crossfading after the
    /// shoulder has stopped moving. Content leads, width settles under it.
    private var earSwap: Animation {
        guard !reduceMotion else { return .easeOut(duration: 0.22) }
        return .spring(response: 0.34, dampingFraction: 0.9)
    }

    /// How an ear arrives and leaves.
    ///
    /// Asymmetric, and the asymmetry is the whole point. An arrival is delayed a
    /// beat so the shoulder has begun widening before any glyph is drawn into it
    /// — the ears are `fixedSize` inside a clip, so content that lands before its
    /// slot exists renders visibly cropped for a frame or two. A departure has no
    /// delay and is quicker: the outgoing ear should be gone before the incoming
    /// one fades up, or a call swapping in over music reads as a smudge of both.
    ///
    /// Scale is 0.92, not 0.8: these live inside a 22pt strip, where a big scale
    /// reads as a pop rather than a settle.
    private var earTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.92))
                .animation(earSwap.delay(0.08)),
            removal: .opacity.combined(with: .scale(scale: 0.96))
                .animation(.easeOut(duration: 0.14)))
    }

    /// The click level's swell, in and out: quick — it is an acknowledgement, and
    /// a leisurely one reads as the panel starting to open — and overshoot-free,
    /// so the retract can never render the island narrower than the hardware notch
    /// it is impersonating (the constraint `busySettle` exists for; the swell hangs
    /// over live menu bar exactly the same way).
    private var peekSettle: Animation {
        guard !reduceMotion else { return .easeOut(duration: 0.16) }
        return .spring(response: 0.26, dampingFraction: 0.95)
    }

    /// The retract animation (XII-108): instead of a flat ease-out, the shell
    /// settles on a slightly-underdamped spring so it reads as an object dropping
    /// back into the bezel with a touch of gravity/rebound, not a clean clamp.
    /// Paced to breathe with the open (response 0.50): the original 0.34 retract
    /// was nearly twice as fast as the unfurl, and with leave-to-fold making the
    /// close a constant companion it read as a harsh clamp — too few frames for
    /// the motion to be legible at all. The slower period also lets the rebound
    /// actually READ as physics; damping comes up a touch so the longer spring
    /// stays one soft settle, not a wobble. Reduce-motion keeps the flat ease.
    private var closeSpring: Animation {
        guard !reduceMotion else { return .easeOut(duration: 0.30) }
        return .spring(response: 0.46, dampingFraction: 0.76)
    }

    /// Seed the kick from the entry vector, then release it. Two writes on
    /// purpose: the displacement lands in a no-animation transaction (one
    /// imperceptible frame — it reads as the island being struck), and the
    /// release to zero rides a soft underdamped spring, giving one gentle
    /// wobble that settles. All gains are deliberately small — a hint of give,
    /// not a stunt.
    private func applyEntryKick() {
        guard !reduceMotion else { return }
        let v = model.entryVelocity
        let speed = (v.dx * v.dx + v.dy * v.dy).squareRoot()
        // A slow deliberate approach gets no kick at all — the physics only
        // wakes up once there's real momentum to absorb.
        guard speed > 250 else { return }

        var seeded = EntryKick.zero
        // Sideways momentum: a slight nudge plus a top-hinged lean (shear), the
        // bottom edge trailing in the direction of travel.
        seeded.tx = max(-5, min(5, v.dx * 0.003))
        seeded.shear = max(-0.025, min(0.025, v.dx * 0.000015))
        // Upward momentum (dy < 0): the glass compresses a touch, absorbing the
        // hit. The clamp is asymmetric — compression reads as material give,
        // but there's almost no stretch case (you can't approach from above).
        seeded.squash = max(-0.030, min(0.010, v.dy * 0.000020))

        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { kick = seeded }
        withAnimation(.spring(response: 0.60, dampingFraction: 0.62)) {
            kick = .zero
        }
    }
}

/// The force-click setting hand-off is isolated from `NotchIsland`'s large
/// modifier stack so that the dialog remains a normal, independently-sized
/// overlay rather than contributing to the compiler's generic expression.
private struct ForceClickLookupGate: ViewModifier {
    @ObservedObject var model: NotchModel
    let isOpen: Bool

    func body(content: Content) -> some View {
        content
            .overlay {
                if model.forceClickLookupConflict != nil, isOpen {
                    ForceClickLookupDialog(onOpenSettings: openTrackpadSettings,
                                           onCancel: dismiss)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.16), value: model.forceClickLookupConflict)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                applyHeldPressureIfNeeded()
            }
    }

    private func openTrackpadSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    private func dismiss() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            model.forceClickLookupConflict = nil
        }
    }

    private func applyHeldPressureIfNeeded() {
        guard let held = model.forceClickLookupConflict,
              !SystemLookupGesture.usesForceClick else { return }
        model.applyForceClickPressure(held)
        Haptics.levelChange()
        withAnimation(.easeOut(duration: 0.16)) { model.forceClickLookupConflict = nil }
    }
}

private extension AgentSessionPreviewTone {
    /// Use the app's existing palette rather than introducing a second set of
    /// approximated shades just for agent state previews.
    var color: Color {
        switch self {
        case .blue: return Tokens.accent
        case .yellow: return Tokens.noteTint
        case .amber: return Tokens.captureTint
        case .green: return Tokens.success
        case .orange: return Tokens.reminderTint
        }
    }
}

/// The components of the entry kick, in render terms: a horizontal nudge (pt),
/// a top-hinged x-shear (x shift per pt of y), and a vertical squash (scaleY
/// delta, negative = compressed).
struct EntryKick: Equatable {
    var tx: CGFloat = 0
    var shear: CGFloat = 0
    var squash: CGFloat = 0
    static let zero = EntryKick()
}

/// Renders the entry kick as one affine transform anchored at the island's
/// top-center — the point where the glass meets the bezel, which must never
/// move. Volume is loosely conserved: vertical squash buys a little horizontal
/// spread, which is what sells the jelly read over a flat scale.
struct EntryKickEffect: GeometryEffect {
    var tx: CGFloat
    var shear: CGFloat
    var squash: CGFloat

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(tx, AnimatablePair(shear, squash)) }
        set {
            tx = newValue.first
            shear = newValue.second.first
            squash = newValue.second.second
        }
    }


    func effectValue(size: CGSize) -> ProjectionTransform {
        let sy = 1 + squash
        let sx = 1 - squash * 0.5
        let recenter = CGAffineTransform(translationX: -size.width / 2, y: 0)
        let deform = CGAffineTransform(a: sx, b: 0, c: shear, d: sy, tx: 0, ty: 0)
        let back = CGAffineTransform(translationX: size.width / 2 + tx, y: 0)
        return ProjectionTransform(recenter.concatenating(deform).concatenating(back))
    }
}

private extension View {
    /// `NotchIsland` has a deliberately rich interaction chain. This boundary
    /// keeps incremental builds from asking the SwiftUI type checker to solve it
    /// as one enormous generic expression.
    func erasingNotchViewType() -> AnyView {
        AnyView(self)
    }
}

/// Bridges global key events (Esc) into SwiftUI without stealing focus.
struct KeyEventCatcher: NSViewRepresentable {
    var handler: (NSEvent) -> Bool

    func makeNSView(context: Context) -> NSView {
        let v = CatcherView()
        v.handler = handler
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CatcherView)?.handler = handler
    }

    final class CatcherView: NSView {
        var handler: ((NSEvent) -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    // One catcher lives in every per-screen panel, and local
                    // monitors all see every app key event — only the panel that
                    // actually holds the keyboard may act, or N panels would each
                    // consume/act on the same Esc.
                    guard let self, self.window?.isKeyWindow == true else { return event }
                    if self.handler?(event) == true { return nil }
                    return event
                }
            }
        }
        deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
    }
}
