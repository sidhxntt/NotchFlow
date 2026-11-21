import SwiftUI
import AppKit

/// The content that lives inside the glass, below the constant black notch zone.
/// Switches between idle / load / result exactly like the prototype's modes.
struct NotchBody: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var capabilities: NotchCapabilityStore
    @ObservedObject var utilities: UtilityCapabilityService
    /// The conversation store, observed SEPARATELY from the model: `turns` no
    /// longer publishes through `model.objectWillChange` (see `ConversationStore`),
    /// so this wrapper is what re-evaluates this body as an answer streams in.
    /// Reads stay `model.turns` — the model forwards to the same store.
    @ObservedObject private var conversation: ConversationStore
    /// Self-update state — read here only to badge the settings gear with a dot
    /// when a newer release is available (the action itself lives in settings).
    @ObservedObject var updater = UpdaterService.shared
    /// Release-notes state — read here to surface the "what's new" cue in the idle
    /// input row once, on the first launch after an update (see `unseenVersion`).
    @ObservedObject var whatsNew = WhatsNewService.shared
    /// The agent-Codex run (XII: agent-to-Codex) — observed so the idle
    /// view's task card tracks progress live and flips to the result on finish.
    @ObservedObject var agentManager = AgentTaskManager.shared
    /// The owned Codex app-server session is the decision transport for Agent.
    /// It publishes one FIFO permission queue per Codex thread.
    @ObservedObject var codexApprovals = CodexAppServerBridge.shared
    /// The Claude Code side of the same surface. Claude has no app-server, so the
    /// transport is a `PreToolUse` hook talking to a Unix socket this app owns —
    /// but it publishes the identical per-session FIFO queue.
    @ObservedObject var claudeApprovals = ClaudeHookBridge.shared
    /// Existing Codex sessions launched in Terminal use the installed NotchFlow
    /// hook protocol, which NotchFlow accepts on a compatibility socket.
    @ObservedObject var terminalCodexApprovals = CodexTerminalHookBridge.shared
    /// Recent Codex and Claude sessions, independently observed from the
    /// direct approval queues so their status, context and subagents remain
    /// visible before and after an approval is needed.
    @ObservedObject var agentSessions = AgentSessionActivityStore.shared
    /// The measured camera housing lets the workspace navigation sit directly
    /// beside the real notch instead of floating as one wide, centered capsule.
    @Environment(\.notchMetrics) var metrics
    /// The model catalog behind the ⌘⇧I picker — the same store Settings' chip reads,
    /// so a list fetched on one surface is already warm on the other.
    @ObservedObject var catalog = ModelCatalogStore.shared
    /// Two-step cancel for an agent status row: the ✕ arms this with its task's
    /// id, and only the armed "cancel?" chip actually terminates that run.
    /// Auto-disarms after a beat. One slot on purpose — arming a second row
    /// relaxes the first.
    @State var confirmingAgentCancelID: UUID? = nil
    /// Which agent status row the pointer is over. The row's trailing slot rests
    /// as an elapsed clock and only becomes the ✕ under the pointer, so a list of
    /// runs reads as durations at a glance and never as a row of close buttons.
    @State var hoveredAgentRowID: UUID? = nil
    /// Pointer over the one-time "turn this off in Settings" line
    /// (`selectionContextHintLine`) — it brightens like every other quiet link.
    @State var hoveringSelectionHint = false
    /// Where the agent model+effort card hangs from: half the chip's width, i.e.
    /// the point under its centre — **frozen for as long as the card is up**.
    /// The chip re-titles live while you pick ("Opus 5 medium" → "Sonnet 5
    /// high"), so its width moves underneath; the card must not slide with it.
    /// The chips row is leading-packed, so the chip's leading edge stays put and
    /// a held offset from it is a genuinely static anchor. Nil = not measured
    /// yet (the card can be armed by ⌘⇧I before the chip ever mounts).
    @State var agentChipAnchorX: CGFloat? = nil
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    /// Drives the custom field's first-responder. Set shortly after the panel
    /// opens so the caret lands without a click (the AppDelegate has just made
    /// the panel key; a tiny delay lets that settle first).
    @State var focused = false
    /// Natural (intrinsic) height of the answer text, reported by a preference
    /// reader. Used ONLY to decide whether the thread has outgrown `answerMaxHeight`
    /// and must switch to the clipped+scrolling layout — it does NOT drive the
    /// height of the un-clipped layout. (It used to: the scroll frame tracked this
    /// measured value, and since the measurement lags the content by a layout pass,
    /// every streamed line nudged the frame a beat late and the spring on it
    /// overshot — the per-line "jump". Now a short answer just sizes to its own
    /// content with no measure→frame feedback loop, so it grows smoothly in the same
    /// frame the text lands.)
    @State var measuredAnswerHeight: CGFloat = 0
    /// Width (pt) of everything the prompt field is currently showing — committed
    /// text plus any in-progress IME composition (pinyin) — reported live by the
    /// field via `onCaretWidth`. It's how the placeholder knows to get out of the
    /// way the moment the editor shows anything, including pinyin that hasn't
    /// committed to `model.text` yet (which lags a whole composition behind).
    @State var caretWidth: CGFloat = 0
    /// Vertical position of the prompt's last visible line, used by the
    /// punctuation-mode explanation that trails the caret.
    @State var caretY: CGFloat = 0
    /// The height the prompt box is asking for: one line at rest, growing with the
    /// wrapped text up to `NotchBody.promptMaxLines`, after which it scrolls inside
    /// itself. The input rows size themselves off these.
    @State var inputHeight: CGFloat = PromptField.lineHeight(for: NotchBody.idleFontSize)
    /// Cursor over the bucket row's "what's new" chip — brightens its glass, in the
    /// same step the Recent chevron beside it takes (see `whatsNewCue`).
    @State var whatsNewHovered = false
    /// Cursor over an "Update to X" chip — one per host (the idle prompt's bucket
    /// row, the recent list's manage bar); they're never on screen together, but
    /// separate flags keep the hover honest either way (see `updateCue`).
    @State var updateCueIdleHovered = false
    @State var updateCueBarHovered = false
    /// A thread opened by a prompt shortcut keeps its follow-up input folded into a
    /// small floating button (see `followUpButton`) until this flips — the run is a
    /// one-shot on a selection, so an always-open composer would cost a row of
    /// height nobody asked for. Reset whenever the thread changes underneath it.
    @State var followUpExpanded = false
    /// The live agent-detail page's own follow-up line — kept separate from the
    /// idle prompt's `model.text` so a line typed while watching a run doesn't
    /// leak into the fresh-chat box the page falls back to when the task ends.
    /// Enter queues it as the run's next instruction (`AgentTaskManager.followUp`),
    /// exactly like the detached agent window's field; the box stays put after
    /// send so more can be lined up.
    @State var agentDetailFollowUp: String = ""
    /// Images pasted into the live agent detail's follow-up box. They belong to
    /// that one queued/resumed round and clear as soon as it is handed off.
    @State var agentDetailFollowUpImages: [NSImage] = []
    /// The detail page's own ⌘ metadata menu (engine / folder / completion) —
    /// the same chip a reopened record's follow-up row carries. Local state, not
    /// `model.isResultMetadataMenuOpen`: the two surfaces never coexist, but the
    /// page owns its own chip and shouldn't leave the record's flag flipped.
    @State var agentDetailMetadataOpen = false
    /// Whether the agent detail page is still pinned to the tail. The page
    /// follows the newest line like a terminal — but only while the reader is
    /// AT the tail: scroll up to read an earlier tool output and the follow
    /// releases, instead of yanking the page back down on every 250ms tick.
    /// Re-arms when the reader returns to the bottom (or sends a follow-up).
    @State var agentDetailFollowsTail = true
    /// Small directional slide-in for the idle prompt as ↑/↓ recall swaps a past
    /// question in: set to a nonzero offset (with the step's direction) the instant
    /// a recall fires, then animated back to rest. See `model.recallPulse`.
    @State var recallSlide: CGFloat = 0
    /// Drives the compact history filter field's first-responder. Set when the
    /// filter icon is tapped so the caret lands in the expanded field without a
    /// second click; reset when the filter collapses so it can re-arm next time.
    @State var filterFocused = false
    /// Measured height of the immersive floating header (input, plus the copied-
    /// image preview when one is pending). The list's top
    /// runway and frost band are derived from this so the first row always rests
    /// clear of the header no matter how tall it gets — a plain input is short, a
    /// header with a preview is taller. Seeded to the plain-input baseline so the
    /// first frame (before the preference lands) already clears a bare-input header.
    @State var measuredImmersiveHeaderHeight: CGFloat = NotchBody.immersiveHeaderBaseline
    /// Whether the immersive header height has been measured at least once this open.
    /// The FIRST measurement (baseline → real height) must land silently — animating
    /// it forces a second, animated layout pass before the expand can even start,
    /// which read as a ~0.5s stall before the list moved. Only LATER changes (a preview
    /// appearing/clearing while open) animate, so those still slide. Reset on close.
    @State var didMeasureImmersiveHeader = false
    /// Which answer's source badge is currently open (hovered), shared between the
    /// badge in the scroll and the floating panel rendered by `resultView` so the
    /// popup escapes the scroll's clip (XII-118). `nil` = none open.
    @State var hoveredSourceID: UUID? = nil
    /// Deferred-close handle for the source popup, so leaving the pill doesn't snap
    /// it shut before the cursor can cross the gap to the panel. Cancelled when the
    /// cursor reaches the panel (or re-enters the pill).
    @State var sourceCloseWork: DispatchWorkItem? = nil
    /// Whether the manage bar's secondary controls (Settings + Clear) are revealed.
    /// The first level is a single ⋯ chip; tapping it unfurls the two actions to its
    /// right. Local presentational state — collapses on selection or a second tap.
    @State var manageExpanded = false
    /// Utilities owns its focused overlay locally; the workspace shortcut strip
    /// stays mounted while the lower File tray / Calendar content is replaced.
    /// Utilities owns its focused overlay locally; the workspace shortcut strip
    /// stays mounted while the lower File tray / Calendar content is replaced.
    @StateObject var utilityOverlaySession = UtilityOverlaySession()
    /// App-lifetime, not view-owned: the panel unmounts on close and the focus
    /// session has to keep counting (and keep announcing) while it is folded.
    @ObservedObject var focusTimer = FocusTimerStore.shared
    @StateObject var quickNote: QuickNoteStore
    @StateObject var quickReminder: QuickReminderStore
    @Namespace var workspaceTabNamespace

    /// Seed `measuredAnswerHeight` from the model's parked measurement, so a
    /// hover-reopen into a long answer mounts DIRECTLY in the clipped layout.
    /// NotchBody unmounts on every close (`if isOpen` in ContentView), resetting
    /// all @State — without the seed the thread re-mounted unclipped at full
    /// intrinsic height and flipped to the clipped scroller one preference pass
    /// later, mid-open-spring: a structural swap (new ScrollView, header →
    /// overlay, follow-up → float, scroll snapped to bottom) stacked on top of
    /// the unfurl, which is what made reopening an answer visibly rougher than
    /// opening the idle prompt. Seeded, the first frame is already the final
    /// layout and the open rides one clean spring — same as idle. The model zeros
    /// the seed on every close after parking it, so a non-restore open (fresh
    /// idle, settings, another thread) still mounts "unmeasured" as before.
    init(model: NotchModel, capabilities: NotchCapabilityStore, utilities: UtilityCapabilityService) {
        self.model = model
        self.capabilities = capabilities
        self.utilities = utilities
        _conversation = ObservedObject(wrappedValue: model.conversation)
        _measuredAnswerHeight = State(initialValue: model.lastMeasuredAnswerHeight)
        _quickNote = StateObject(wrappedValue: QuickNoteStore { text, completion in
            NotesService.writeNote(text) { result in
                switch result {
                case .success: completion(true)
                case .failure: completion(false)
                }
            }
        })
        _quickReminder = StateObject(wrappedValue: QuickReminderStore { text, due, completion in
            RemindersService.createReminder(text, due: due) { result in
                switch result {
                case .success: completion(true)
                case .failure: completion(false)
                }
            }
        })
    }

    /// The panel's content inset — the SAME on all four sides, so the follow-up
    /// input (and every other edge-hugging row) sits as far from the bottom as it
    /// does from the sides. 15 also reads as concentric against the open island's
    /// 30pt bottom corner radius.
    static let panelPadding: CGFloat = 15

    /// Runway under the panel's tail row: the uniform inset, except for the bare
    /// first-question wait line, which gets extra room so the lone thinking state
    /// doesn't crowd the rounded bottom edge.
    private var panelBottomPadding: CGFloat {
        if model.mode == .load && model.turns.isEmpty { return 42 }
        // Workspace surfaces already carry their own card margins. A smaller
        // runway keeps the Utilities tail close to the rounded island edge
        // without changing the chat or result layouts.
        if model.mode == .idle { return 8 }
        return NotchBody.panelPadding
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.mode {
            case .result:
                resultView
            case .load:
                // A follow-up already has the thread on screen — keep showing the
                // conversation (its last bubble renders the thinking dots) so the
                // prior turns don't vanish while the answer is in flight. Only the
                // very first question, with nothing on screen yet, gets the bare
                // centered load view.
                if model.turns.isEmpty {
                    loadView
                } else {
                    resultView
                }
            case .idle:
                // An open agent detail page owns the idle slot: the run's full
                // work trail, live while it works. Falls back to the idle panel
                // by itself once the task is dismissed (the lookup fails).
                if let task = agentDetailTask {
                    agentDetailView(task)
                } else {
                    idleView
                }
            }
        }
        .padding(.horizontal, NotchBody.panelPadding)
        .padding(.top, NotchBody.panelPadding)
        // The first-question wait line sits at the panel's visual tail. Give that
        // bare thinking state a little more runway so the activity doesn't crowd
        // the rounded bottom edge; follow-up waits keep the result layout unchanged.
        .padding(.bottom, panelBottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A file drop owns the Utilities surface regardless of which body branch
        // is currently visible. This must live at the body root: `idleView` is
        // absent while an answer, loading state, or agent detail is on screen.
        .onChange(of: capabilities.fileTrayRevealRequest) { _, _ in
            guard capabilities.workspaceTab == .utilities else { return }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                utilityOverlaySession.dismiss()
            }
        }
        // The cross-provider model chooser — opened by the Ask bucket's model chip
        // (`askModelChip`), the settings chip, and ⌘⇧I's fallback when no agent CLI is
        // installed. It hangs under the panel body rather than off the chip so all three
        // front doors land it right below the island, where the eye already is.
        //
        // The rows are built only while the menu is actually up: `rows` walks every
        // provider (each one's `ready` check, then the whole catalog's fold and sort),
        // and this modifier sits on the panel body — so an unfurl used to pay for a
        // menu nobody asked for. The body re-runs when `showModelPicker` flips, which
        // is before the presenter reads them.
        .modelMenu(isPresented: $model.showModelPicker,
                   models: model.showModelPicker ? catalog.rows(selected: selectedProvider) : [],
                   selectedProvider: selectedProvider,
                   selectedID: selectedModelID,
                   centered: true,
                   onSelect: { prov, id in
                       ModelCatalogStore.select(provider: prov, model: id)
                   },
                   onConfigure: { m in
                       // "Add key" on a keyless model: the menu can't take a key, so
                       // hand the pick to Settings — it opens on that provider's key
                       // row and commits the model the moment the key lands. The active
                       // backend stays untouched until then.
                       model.pendingModelSetup = .init(provider: m.provider, id: m.info.id)
                       withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                           model.openSettings()
                       }
                   })
        .onChange(of: model.showModelPicker) { _, open in
            // A menu is a snapshot of the catalog it was built from — refresh the live
            // models on open so the *next* one is current (the bundled list shows now).
            if open { Task { await catalog.loadAll() } }
            // The menu is its own window, outside the island's tracking area —
            // suspend the leave-collapse while it's up, exactly as the settings
            // picker does, or moving the pointer into the card folds the panel away.
            model.isModelPickerOpen = open
        }
        // The agent's model+effort picker (⌘⇧I / the compose chip tap) hangs off
        // the model chip itself — see `agentComposeChips` — not the body, so it
        // pops from the control that opened it exactly like the Ask chip's menu.
        .onChange(of: model.showAgentPicker) { _, open in
            model.isModelPickerOpen = open
        }
        .onChange(of: model.showAskModelPicker) { _, open in
            model.isModelPickerOpen = open
        }
        .onChange(of: model.showAgentFolderPicker) { _, open in
            model.isModelPickerOpen = open
        }
        .onChange(of: model.open) { _, isOpen in
            if isOpen {
                refocusInput()
            } else {
                focused = false
            }
        }
        // Returning to the idle prompt (← / back button / Enter-submit-then-finish)
        // tears down the result/follow-up field and builds a fresh idle PromptField,
        // which has never held focus — so its ↓/↑ history-nav keys went dead. Re-arm
        // the focus latch on every switch *into* idle while open, so the caret (and
        // the keyboard history nav that rides on it) always lands back in the prompt.
        // The same crossover in the other direction: submitting tears down the idle
        // PromptField and mounts the follow-up box, again with no false→true edge on
        // `focused` — so the caret would be left nowhere and the user would have to
        // click before typing the next line. Re-arm on the way into a result too.
        .onChange(of: model.mode) { _, newMode in
            if shouldRefocus(after: newMode) {
                refocusInput()
            }
        }
        // A settled answer hands the caret back to the follow-up field, so the next
        // question can be typed straight away. The round's own layout churn (the
        // streaming turn's footer appearing, the composer moving between sibling and
        // overlay) can drop first-responder mid-write; this re-arms it the moment the
        // last streaming turn settles.
        .onChange(of: model.turns.contains { $0.streaming }) { _, isStreaming in
            if !isStreaming, model.open, model.mode == .result {
                refocusInput()
            }
        }
        // Collapsing the recent list returns the caret to the prompt. Without this, a
        // user who clicked into the new HistorySearchField (taking first-responder off
        // the prompt) and then pressed Esc to fold the list would be left in focus
        // limbo on the now-removed filter field — unable to type until they click.
        .onChange(of: model.showHistory) { _, isShowing in
            if model.open, !isShowing, model.mode == .idle {
                refocusInput()
            }
            // Closing the list tears down the immersive layout, so re-arm the
            // "first measurement lands silently" latch for the next open — otherwise
            // the next open's baseline→real jump would animate (and stall) again.
            if !isShowing { didMeasureImmersiveHeader = false }
        }
        // When the answer grows past `answerMaxHeight` and the clipped layout mounts,
        // followUpRow moves from a VStack sibling to a ZStack child in a new structural
        // position — SwiftUI recreates the NSTextField underneath, and the `focused`
        // Bool has no false→true edge to re-grab first-responder. refocusInput() drops
        // then re-raises `focused` next runloop, so the follow-up caret survives the
        // crossover without a click. Only the false→true edge of `isAnswerClipped`
        // matters (the moment the answer first crosses the ceiling this session).
        .onChange(of: isAnswerClipped) { _, nowClipped in
            if nowClipped, model.open {
                refocusInput()
            }
        }
        // Leaving a thread (← / ⌘N new-chat, tearing it off into a window) empties
        // `turns` while the panel — and this view — stay mounted, so neither init's
        // seed nor the measurement probe runs again: the OLD thread's measurement
        // would survive into the next one. If that thread was long (>300), a fresh
        // short question mounts straight into the full-height clipped scroller and
        // — because the probe deliberately stays down while streaming — holds full
        // height for the entire answer. Zero the measurement (and its model mirror,
        // which seeds the next mount) the moment the thread leaves the screen, so
        // every new chat starts unclipped and sizes to its content. Close is
        // unaffected: `fullClose` parks the measurement before it empties `turns`.
        .onChange(of: model.turns.isEmpty) { _, isEmpty in
            if isEmpty {
                measuredAnswerHeight = 0
                model.lastMeasuredAnswerHeight = 0
                // A thread leaving the screen re-folds the shortcut follow-up, so the
                // next shortcut run opens on its button rather than an unfolded field
                // it inherited from the previous answer.
                followUpExpanded = false
            }
        }
        // A fresh prompt-shortcut run (hotkey pressed again while the panel is up)
        // re-folds too — same reason, without waiting for `turns` to empty.
        .onChange(of: model.fromPromptShortcut) { _, isShortcut in
            if isShortcut { followUpExpanded = false }
        }
        .onAppear {
            if model.open {
                refocusInput()
            }
        }
    }

    /// The provider and model in effect — what the ⌘⇧I picker opens on. Read straight
    /// from the store rather than mirrored into state: a pick closes the popover, so the
    /// body re-reads on the next summon and can never show a stale selection.
    var selectedProvider: Provider { APIKeyStore.selectedProvider }

    /// The wire id in effect, with the sentinels resolved (an empty override, or a CLI
    /// backend's legacy "codex" / "grok" / "claude", all mean "this provider's
    /// default") — mirrors the settings chip.
    var selectedModelID: String {
        let p = selectedProvider
        let id = APIKeyStore.storedModel(for: p)
        if p == .codex, id.isEmpty || id == "codex" { return p.defaultModel }
        if p == .grokCode, id.isEmpty || id == "grok" { return p.defaultModel }
        if p == .claudeCode, id.isEmpty || id == "claude" { return p.defaultModel }
        if p == .commandCode, id.isEmpty || id == CommandCodeCLIService.defaultSentinel {
            return p.defaultModel
        }
        if p == .piCode, id.isEmpty || id == PiCLIService.defaultSentinel {
            return p.defaultModel
        }
        return id.isEmpty ? p.defaultModel : id
    }

    /// Re-arm the PromptField's first-responder latch. `focusTrigger` only fires on
    private func shouldRefocus(after mode: NotchModel.Mode) -> Bool {
        guard model.open else { return false }
        return mode == .idle || mode == .result
    }

    /// a false→true edge, so when `focused` is already true (e.g. coming back to
    /// idle without the panel ever closing) we must drop it first, then raise it
    /// next runloop — otherwise there's no edge and the new field never grabs focus.
    /// The small delay also lets SwiftUI finish swapping the field in.
    func refocusInput() {
        focused = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { focused = true }
    }

    // MARK: - Agent run detail page

    /// The detail scroll's height. Tuned so the whole page (26pt header + 10 gap
    /// + this + 10 gap + 39pt follow-up row = 320pt) matches the immersive
    /// history layout, whose 320pt list is the only thing that opens the island
    /// (its input header floats as an overlay, taking no layout height) — the
    /// agent page must never make the island taller than the recent list does.
    let agentDetailScrollHeight: CGFloat = 235

    /// Breathing room between the bottom of the floating header and the first row's
    /// resting top. `baseline (54) + gap (12) = 66`, the runway the bare-input layout
    /// uses; a header with a preview measures taller and the runway grows with it.
    let immersiveHeaderGap: CGFloat = 12

    /// How far the immersive list's content reaches DOWN behind the floating manage
    /// bar — the bottom mirror of `immersiveTopReach`. It's the runway the last rows
    /// scroll down into and dissolve (fade + frost) behind the ⋯ chrome, so
    /// reaching the very bottom of the list reads as rows sliding under the buttons,
    /// not stopping above them. Sized to clear the bar (gear 30 + 4pt bottom pad ≈
    /// 34) plus a little headroom so a row can travel fully behind it.
    let immersiveBottomReach: CGFloat = 44

    /// Height of the compact scroll region, and the two content measurements the
    /// compact overflow test weighs against it: one recent row (9pt padding on each
    /// side of a 14pt line) and the end-of-list footer (hairline + gap + one 25pt
    /// glass pill, plus its 10pt lead-in). Estimates, not measurements — they only
    /// decide whether the bottom taper is worth drawing.
    let compactListHeight: CGFloat = 220
    let compactRowHeight: CGFloat = 35
    let historyFooterHeight: CGFloat = 50

    // MARK: - Result

    /// The tallest the answer area is ever allowed to grow. Short answers size to
    /// their own content (below this); only long ones clip + scroll at the ceiling.
    /// This value is ALSO the threshold that flips `isAnswerClipped` — do NOT change
    /// it to match the clipped frame height; those are intentionally different.
    let answerMaxHeight: CGFloat = 300

    /// Fixed frame height for `clippedConversation` when the follow-up input floats
    /// over its bottom. = answerMaxHeight (300) + the .padding(.top, 24) gap that
    /// today separates the scroll from the follow-up row (24) + followUpRow's own
    /// rendered height (27pt content + 6+6 vertical padding = 39pt) = 363pt.
    /// Absorbing those 63pt into the scroll frame keeps `resultView`'s total height
    /// identical to today — the panel never resizes at the short↔long crossover,
    /// which also keeps the source-popup y-offset formula (`rect.minY - geo.size.height`)
    /// correct without needing to account for the shift.
    let clippedAnswerMaxHeight: CGFloat = 363

    /// Height of the floating header block the clipped thread reaches UP behind:
    /// the 26pt back/pin row plus the 18pt gap the short layout keeps below it.
    /// When clipped, that block leaves the VStack flow and floats over the scroll's
    /// top, and the scroll frame grows by exactly this much — so the panel's total
    /// height never changes at the crossover, and the header renders at the same
    /// spot in both layouts. It doubles as the top runway: the fade taper length
    /// and the first row's resting inset when scrolled fully up (the result-view
    /// mirror of `immersiveTopReach`).
    let resultHeaderReach: CGFloat = 44

    /// Bottom runway inside `clippedConversation`: empty scroll space the last turn
    /// scrolls DOWN into, behind the floating follow-up input. = the input's reach
    /// from the viewport bottom (the 39pt box, no lift) + 23pt breathing room = 62pt.
    /// It lives
    /// ABOVE the `scrollBottomID` anchor in the VStack (not in `.padding(.bottom)`),
    /// so `scrollTo(anchor:.bottom)` pins the anchor's bottom to the viewport bottom
    /// while the last real turn rests ~64pt above it — 13pt above the input's top
    /// edge, entirely within the dissolve zone.
    let clippedBottomRunway: CGFloat = 62

    /// Height of the taper at each scroll edge, in points. Generous on purpose so
    /// the dissolve is a long, gentle gradient — not a thin line that still reads
    /// as a cut. The scroll content carries matching top/bottom padding, so the
    /// fade falls across that breathing room rather than over live text.
    let edgeFade: CGFloat = 64

    /// The compact RECENT list's TOP taper — deliberately shorter than `edgeFade`.
    /// The compact list is only ~6 rows tall, so mirroring the full 64pt reserve up
    /// top would spend two rows of the viewport on empty runway. This is just enough
    /// to swallow a row on its way out under the RECENT header instead of cutting it
    /// mid-glyph, and the scroll content carries a matching top inset so the first
    /// row still rests below the gradient at full strength.
    let compactTopFade: CGFloat = 24

    /// Stable id for the invisible spacer at the very bottom of the thread; the
    /// `ScrollViewReader` scrolls to it to keep the newest text in view.
    let scrollBottomID = "conversation-bottom"
}
