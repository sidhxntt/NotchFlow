import SwiftUI
import Combine
import AppKit   // NSWorkspace — opening Notes/Reminders for a Recent capture
import Carbon.HIToolbox
import UniformTypeIdentifiers   // UTType — is a pasted file URL an image? (agent ⌘V)

@MainActor
extension NotchModel {
    // MARK: - Parked session (close = park, reopen soon = restore)

    /// The page the user was on when the panel last folded, parked so a return
    /// within `parkedSessionTTL` lands exactly where they left — the thread they
    /// were reading, the follow-up they'd half-typed, the settings page mid-key.
    /// The interaction rule this implements: **closing gestures navigate, they
    /// never destroy** — only ← / ⌘N (`newChat`) and time throw a session away.
    /// After the TTL the context has likely moved on, so a late reopen falls back
    /// to the fresh idle prompt (the conversation stays one tap away in Recent).
    struct ParkedSession {
        var mode: Mode
        var turns: [Turn]
        var text: String
        var threadHistoryID: UUID
        var showWhatsNew: Bool
        var showHistory: Bool
        var closedAt: Date
        /// The thread's measured intrinsic height at close time — see
        /// `lastMeasuredAnswerHeight`. Restored before the reopened panel mounts
        /// so the result view lands in the right (short vs clipped) layout on
        /// its very first frame.
        var measuredAnswerHeight: CGFloat
        /// Whether the thread was opened by a prompt shortcut — parked so a
        /// close+reopen lands back on the FOLDED follow-up (a header chip) instead
        /// of silently promoting the thread to a standing composer.
        var fromPromptShortcut: Bool
    }

    /// How long a parked session stays restorable. "A few minutes" — long enough
    /// to answer a Slack message and come back, short enough that a reopen after
    /// real absence reads as a fresh start, not a haunting.
    static let parkedSessionTTL: TimeInterval = 300

    /// How long after the last keystroke the user still counts as "typing".
    static let typingGrace: TimeInterval = 3.0

    /// The armed "leave watch" — one small state machine covering every case
    /// where a fold is warranted but not NOW:
    ///   · the pointer left mid-typing → fold once the keystrokes stop;
    ///   · an exit event was spurious (pointer still on the island) → re-verify
    ///     after the animation settles;
    ///   · the island SHRANK away from a parked pointer (⌘N folding a tall
    ///     thread to the short idle prompt, a list collapsing…) → the user
    ///     didn't leave; fold only once the pointer genuinely moves off.
    /// It polls rather than waiting for events because AppKit's tracking state
    /// is desynced in exactly these situations — the event that would have
    /// told us may never come. Cancelled by every open path (a hover re-entry
    /// or keyboard summon supersedes any pending fold).
    struct LeaveWatch {
        var display: CGDirectDisplayID?
        var sequenced: Bool
        /// Where the mouse was when the watch was armed. A boundary-shrink
        /// leave folds only after real displacement from here.
        var armedMouse: CGPoint
        /// True when the pointer genuinely crossed out (a moving-cursor exit):
        /// fold as soon as the typing grace clears, no displacement required.
        var movedOut: Bool
    }

    private func cancelLeaveWatch() {
        leaveRecheckTask?.cancel()
        leaveRecheckTask = nil
        leaveWatch = nil
    }

    /// (Re-)arm the watch and schedule its next re-check.
    private func armLeaveWatch(_ watch: LeaveWatch, after delay: TimeInterval) {
        leaveWatch = watch
        leaveRecheckTask?.cancel()
        leaveRecheckTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000) + 50_000_000)
            guard !Task.isCancelled, let self else { return }
            self.recheckLeaveWatch()
        }
    }

    /// Mark the user as actively typing. Called from `text`/`historySearchQuery`
    /// didSets and from view-local fields (settings API keys) via their onChange.
    func noteUserTyping() {
        lastEditAt = Date()
    }
    // MARK: - Handoff

    /// Compress the on-screen conversation into a single portable block the user can
    /// paste into a full chat (ChatGPT, Claude, …) to pick up exactly where the
    /// notch left off — copied to the clipboard so the handoff is one click. Plain
    /// Q/A transcript with a short framing line; no app-specific markup so it drops
    /// cleanly into any assistant.
    @discardableResult
    func copyHandoffContext() -> String {
        var lines = ["Here's a conversation I'd like to continue. Please pick up from the last answer.\n"]
        var round = 0
        for turn in turns {
            let body = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            if turn.role == "user" {
                round += 1
                lines.append("Q\(round): \(body)")
            } else {
                lines.append("A\(round): \(body)\n")
            }
        }
        let text = lines.joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        return text
    }

    /// Re-sync the clipboard baseline after Notch itself wrote to the pasteboard
    /// from *within* an open panel — e.g. the per-code-block copy button. Without
    /// this, that in-app write bumps `changeCount` past `pasteboardChangeCountAtOpen`,
    /// and `clipboardContextIfEligible()` would then mistake the user's own just-copied
    /// code for "something they copied to ask about" and silently inject it into the
    /// next Ask. Same one-line re-baseline `newChat()` uses after a handoff copy.
    func rebaselineClipboardAfterInAppWrite() {
        pasteboardChangeCountAtOpen = NSPasteboard.general.changeCount
        senseLastChangeCount = pasteboardChangeCountAtOpen
    }
    // MARK: - Open / collapse

    /// Whether the island on `display` should render expanded. A `nil` active
    /// display means "no specific screen claimed the panel" (debug launch paths
    /// set `open` directly) and unfurls everywhere; otherwise only the claiming
    /// screen expands.
    func isOpen(on display: CGDirectDisplayID?) -> Bool {
        open && (activeDisplay == nil || display == nil || activeDisplay == display)
    }

    /// Open (or migrate) the panel on the given screen. Hovering another screen's
    /// resting notch while the panel is open elsewhere moves the whole island —
    /// conversation and all — to where the user actually is. `activeDisplay` is
    /// set BEFORE `open` so AppDelegate's combined observer keys the right panel.
    /// `velocity` is the cursor's approach vector (zero for non-hover opens);
    /// it must land before `open` so the island's animation reads it fresh.
    func openPanel(on display: CGDirectDisplayID?, velocity: CGVector = .zero) {
        guard LicenseService.shared.state.allowsProductServices else {
            openRestrictedLicenseSettings()
            return
        }
        if let display { activeDisplay = display }
        // Only the *closed→open* edge sets the clipboard baseline. Hover fires
        // `openPanel` again on every re-enter and on display migration while already
        // open — re-baselining there would clobber a copy the user made mid-session.
        // The baseline is the count from when the notch was last *resting* (before
        // this open), NOT the count right now: the user copies first and opens
        // second, so by now the copy has already bumped the live count. Carrying the
        // pre-open resting value forward is what lets that copy-then-open read as
        // fresh in `clipboardContextIfEligible`.
        if !open {
            // The entry vector belongs to the closed→open EDGE and nowhere else.
            // Setting it on every call meant the synthetic enter that the unfurling
            // island fires at its own parked pointer — the island arriving at the
            // cursor, which `hoverEntered` forwards straight back here — overwrote
            // the real approach with whatever the last 120ms held. On a click open
            // that is the press's own jitter: a couple of points over a few
            // milliseconds, i.e. hundreds of points per second, pointing wherever
            // the hand happened to twitch. `applyEntryKick` then read it off the
            // `isOpen` edge and shoved the panel sideways on every single open.
            entryVelocity = velocity
            // Seed the hover flag from where the pointer really is: a hover-open
            // already had `.onHover` set it, but a hot-key summon under a resting
            // cursor gets no fresh enter event, and its chips would stay hidden
            // with the pointer sitting right on them. Unknown geometry falls back
            // to "shown" — the pre-hide behaviour.
            pointerInside = pointerInsideIsland(on: display, slop: 16) ?? true
            // One trackpad tap on the closed→open edge only — hover re-enters and
            // display migrations while already open stay silent, as do the
            // programmatic opens (settings / What's New), which can
            // fire without the cursor on the island.
            Haptics.alignment()
            pasteboardChangeCountAtOpen = pasteboardChangeCountAtRest
            if mode == .idle, turns.isEmpty, let round = inFlightRounds.last {
                // A round is still streaming in the background — the busy
                // extension is out, and hovering the working notch should land
                // on the answer being written, not on the idle prompt with the
                // work hidden behind a Recent row. Newest round wins when
                // several are in flight (older ones stay reachable through
                // their pending Recent rows). The parked idle draft is
                // deliberately NOT consumed on this path: it stays parked and
                // hands back on the next plain idle open. Any parked page IS
                // dropped: the live round is newer activity than the snapshot.
                attachInFlightRound(round)
                parkedSession = nil
            } else {
                // A return within the TTL lands back on the parked page — the
                // thread being read, the half-typed follow-up, the settings form.
                // Past the TTL the snapshot is stale context: drop it and open
                // fresh (the conversation is still one tap away in Recent).
                if let parked = parkedSession,
                   Date().timeIntervalSince(parked.closedAt) <= Self.parkedSessionTTL {
                    restoreParkedSession(parked)
                }
                parkedSession = nil
                // Hand back an unsent idle draft parked at the last close, so folding
                // the notch away and re-opening it doesn't drop what the user was
                // typing. Only into a fresh, empty idle prompt — never clobber a line
                // already in the box (e.g. one restored with the panel). Consumed here
                // so it's handed back exactly once. Runs on the closed→open edge only:
                // hover re-enters and display migrations keep `open` true and skip it.
                if mode == .idle, !hasText, !savedIdleDraft.isEmpty {
                    text = savedIdleDraft
                }
                savedIdleDraft = ""
            }
            // Opening the panel is the app being *used*, which is the moment the
            // curated shortlists want to be current — launch alone misses a Mac
            // that stays up for a week. A cheap no-op inside the manifest's TTL.
            Task.detached(priority: .background) { await RemoteModelManifest.refreshIfDue() }
        }
        // A hover re-entry supersedes any pending leave watch — and any pending
        // dwell has just been answered (by itself or by another route in).
        cancelLeaveWatch()
        cancelHoverDwell()
        // Re-entering during the close dissolve cancels it: clear the flag so the
        // content (held mounted while `open` is true) springs back to full opacity
        // instead of completing its fade, and the pending `beginClose` timer no-ops.
        closing = false
        open = true
        // An open retires a visible sense hint (the panel takes over the screen),
        // while a saving/saved narration settles on its own timer, just unseen.
        if case .hinting = clipboardSense { senseCancelHint() }
    }

    /// Toggle the panel from a global hot key: open it on `display` if resting,
    /// or close it if it's already showing. Summoned by keyboard, so it routes
    /// through `openPanel` (idle prompt, clipboard baseline preserved) on the open
    /// edge and a hard `fullClose` on the close edge — no hover required.
    func toggleSummon(on display: CGDirectDisplayID?) {
        guard LicenseService.shared.state.allowsProductServices else {
            openRestrictedLicenseSettings()
            return
        }
        if open {
            fullClose()
        } else {
            mode = .idle
            openPanel(on: display)
        }
    }

    /// Open the separate macOS Settings window. The notch deliberately remains
    /// on its current surface instead of replacing its content with preferences.
    func toggleSettings() {
        NotificationCenter.default.post(name: .openSettingsRequested, object: nil)
    }

    /// Compatibility route for callers that still ask the model to open Settings.
    /// Preferences now live in their own scene, so this never opens the notch.
    func openSettings(on display: CGDirectDisplayID? = nil) {
        NotificationCenter.default.post(name: .openSettingsRequested, object: nil)
    }

    private func openRestrictedLicenseSettings() {
        settingsSection = InlineSettingsView.Section.about.rawValue
        NotificationCenter.default.post(name: .openSettingsRequested, object: nil)
    }

    /// Open the panel straight into the "What's New" release notes — the path ⌘↵,
    /// the input-row cue, and the once-per-version auto-show all take. Mirrors
    /// `openSettings`: works whether the panel was resting or already open, clears
    /// any stale entry vector so the keyboard summon doesn't kick the unfurl, and
    /// folds the recent list / settings away (they share the same body slot).
    /// Marks the running version as seen so the cue and auto-show don't re-fire.
    func openWhatsNew(on display: CGDirectDisplayID? = nil) {
        guard LicenseService.shared.state.allowsProductServices else {
            openRestrictedLicenseSettings()
            return
        }
        entryVelocity = .zero
        if let display { activeDisplay = display }
        if !open {
            pasteboardChangeCountAtOpen = pasteboardChangeCountAtRest
        }
        // Cancel any in-flight close dissolve (see `openPanel`), and any pending
        // leave watch — this keyboard summon supersedes it.
        closing = false
        cancelLeaveWatch()
        open = true
        mode = .idle
        showWhatsNew = true
        showHistory = false
        highlightedHistoryIndex = nil
        WhatsNewService.shared.markSeen()
    }

    /// Leave What's New and return to the idle prompt (panel stays open).
    func closeWhatsNew() {
        showWhatsNew = false
    }

    /// Toggle the pin on the answer currently on screen. Pinned → the pointer can
    /// leave without folding the panel (see `collapseOnLeave`). Unpinning while the
    /// pointer is already off the island re-arms the normal leave-fold immediately,
    /// so an un-pin doesn't strand a panel open until the next hover.
    func toggleAnswerPin() {
        isAnswerPinned.toggle()
        if !isAnswerPinned { collapseOnLeave(from: activeDisplay) }
    }

    /// Temporarily protects the hover-driven shell while an in-panel control is
    /// tracking pointer input. Ending the interaction deliberately leaves the
    /// current presentation alone; the next genuine pointer exit resumes normal
    /// leave-to-collapse behavior.
    func setPanelControlInteraction(_ active: Bool) {
        panelControlInteraction = active
        if active { cancelLeaveWatch() }
    }

    /// Mirrors the approval transports' combined pending state. Kept on the shell
    /// model so a synthetic hover exit caused by opening the Agent surface cannot
    /// retract the exact card the user needs to decide.
    func setDirectApprovalPending(_ pending: Bool) {
        directApprovalPending = pending
        if pending { cancelLeaveWatch() }
    }

    /// Whether a live control interaction really is holding the panel open.
    ///
    /// `panelControlInteraction` is raised by a gesture's `onChanged` and
    /// lowered by its `onEnded` — but SwiftUI does not guarantee the second
    /// half: a press that a Button inside the media module claims cancels the
    /// module's simultaneous drag with no `onEnded` at all, stranding the flag
    /// raised. And a raised flag blocks the fold that would unmount the view
    /// whose `onDisappear` is the only other thing that lowers it, so the panel
    /// stayed open for good after using a media control.
    ///
    /// So the flag is corroborated against the hardware: no mouse button down
    /// means no drag in progress, whatever the gesture last reported. A stale
    /// flag is cleared here rather than merely ignored, so the next leave starts
    /// from a clean slate.
    private var controlInteractionHolds: Bool {
        guard panelControlInteraction else { return false }
        guard NSEvent.pressedMouseButtons == 0 else { return true }
        panelControlInteraction = false
        return false
    }

    /// Holds the hover-driven shell for the complete lifetime of a Utilities
    /// overlay, including AppKit-backed Stepper button presses and text editing.
    func setUtilityOverlayPresented(_ presented: Bool) {
        utilityOverlayPresented = presented
        if presented { cancelLeaveWatch() }
    }

    /// Auto-retract once the pointer leaves — for EVERY page (the rule the user
    /// settled on: leave = fold, always). Closing is cheap now: the page is
    /// parked by `fullClose` and a hover within `parkedSessionTTL` restores it
    /// exactly, so the panel no longer needs to cling open to protect content.
    ///
    /// The single exception: **actively typing**. While the keyboard is engaged
    /// the pointer isn't an attention signal — folding mid-keystroke would yank
    /// focus, a real interruption no restore compensates. So a leave during
    /// typing defers the fold until `typingGrace` after the last keystroke
    /// (the deferred fold re-checks, so continued typing keeps deferring; a
    /// hover re-entry or keyboard summon cancels it via `leaveRecheckTask`).
    func collapseOnLeave(from display: CGDirectDisplayID? = nil, sequenced: Bool = true) {
        // The pointer left: a pending dwell can no longer be an intentional
        // hover. Cleared before the `open` guard because the dwell exists while
        // the panel is closed.
        cancelHoverDwell()
        // Nothing to fold on a resting notch — and a stale deferred fold must
        // never fire `fullClose` on an already-closed panel (that would wipe a
        // freshly parked session).
        guard open else { return }
        // The user pinned this answer: leaving is no longer a fold signal. Drop any
        // watch that was already armed (a leave-during-typing may have scheduled
        // one before the pin) so it can't fire behind the pin's back.
        //
        // The open `/` menu joins the pickers here for the same reason: its card
        // hangs BELOW the island in its own window, so reaching down to the lower
        // rows reads as "left the island" and would fold the panel out from under
        // the menu being read. Ordinary leave-folding resumes the moment the menu
        // is gone (a picked row, a keystroke past the command word, Esc).
        // A utility overlay (Pomodoro / Quick note / Reminder) is deliberately
        // NOT in this list: it is another module in the panel's stack, and it
        // folds on leave like the Chat, Media and Utilities tabs it sits among.
        // Layout jolts from mounting it are already handled below, by the
        // boundary-shrink check that holds the panel for a stationary pointer.
        if directApprovalPending || isAnswerPinned || controlInteractionHolds || isModelPickerOpen || isFolderPickerOpen
            || isResultMetadataMenuOpen || slashMenuOpen || detachDrag != nil {
            cancelLeaveWatch()
            return
        }
        // The pointer leaving a *resting* notch on a screen that isn't hosting
        // the open panel has nothing to fold — and must never close the island
        // that's actually in use on another display.
        if let display, let active = activeDisplay, display != active { return }
        // Verify the exit against the pointer's real position: the open/close
        // springs update the tracking area per frame, and AppKit synthesizes
        // exit events for a stationary pointer when the boundary moves under
        // it. Folding on those made the island flap (see `pointerInsideIsland`).
        // Tight slop: a real leave should fold even from just past the edge.
        let mouse = NSEvent.mouseLocation
        let inside = pointerInsideIsland(on: display ?? activeDisplay, slop: 2)
        if inside == true {
            armLeaveWatch(LeaveWatch(display: display, sequenced: sequenced,
                                     armedMouse: mouse, movedOut: false), after: 0.35)
            return
        }
        // The pointer really is outside. But WHY: did it cross the boundary, or
        // did the boundary shrink away from a parked pointer (⌘N folding a tall
        // thread to the short idle prompt, a list collapsing)? A genuine leave
        // has the cursor in motion; a UI shrink arrives with a cursor that
        // hasn't moved at all — that one is NOT the user leaving, so hold the
        // panel and fold only once the pointer really moves off (the watch).
        // Unknown geometry (nil) falls back to trusting the event, as before.
        let movedOut = inside == nil
            || MouseVelocityTracker.shared.cursorMoved(within: 0.25)
        if !movedOut {
            armLeaveWatch(LeaveWatch(display: display, sequenced: sequenced,
                                     armedMouse: mouse, movedOut: false), after: 0.35)
            return
        }
        let sinceEdit = Date().timeIntervalSince(lastEditAt)
        if sinceEdit < Self.typingGrace {
            armLeaveWatch(LeaveWatch(display: display, sequenced: sequenced,
                                     armedMouse: mouse, movedOut: true),
                          after: Self.typingGrace - sinceEdit)
            return
        }
        // Route through the two-beat dissolve so the content fades before the
        // shell retracts, matching Esc.
        beginClose(sequenced: sequenced)
    }

    /// One poll tick of the armed leave watch. Ends in exactly one of: fold
    /// (pointer verifiably off the island, displaced or genuinely crossed out,
    /// keyboard quiet), re-arm (still undecided), or dissolve (panel no longer
    /// open / answer pinned / watch cancelled elsewhere).
    private func recheckLeaveWatch() {
        guard let watch = leaveWatch else { return }
        guard open else { leaveWatch = nil; return }
        if directApprovalPending || isAnswerPinned || controlInteractionHolds || isModelPickerOpen || isFolderPickerOpen
            || isResultMetadataMenuOpen || slashMenuOpen {
            cancelLeaveWatch(); return
        }
        // Parked back over (or still over) the island: nothing to fold, but keep
        // watching — AppKit's tracking state may be desynced, so the exit that
        // would restart this conversation might never arrive.
        if pointerInsideIsland(on: watch.display ?? activeDisplay, slop: 2) == true {
            armLeaveWatch(watch, after: 0.35)
            return
        }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - watch.armedMouse.x
        let dy = mouse.y - watch.armedMouse.y
        let displaced = (dx * dx + dy * dy).squareRoot() > 6
        // A boundary-shrink leave holds until the pointer actually goes
        // somewhere. Displacement is measured against the ORIGINAL armed
        // position, so slow drift accumulates instead of resetting each tick.
        if !watch.movedOut, !displaced {
            armLeaveWatch(watch, after: 0.35)
            return
        }
        let sinceEdit = Date().timeIntervalSince(lastEditAt)
        if sinceEdit < Self.typingGrace {
            var held = watch
            held.movedOut = true
            armLeaveWatch(held, after: Self.typingGrace - sinceEdit)
            return
        }
        leaveWatch = nil
        beginClose(sequenced: watch.sequenced)
    }

    /// How long the content lingers, fading, before the shell retracts. Kept short
    /// — this is a dissolve to soften the snap, not a second animation the user
    /// waits through; the shell's own retract spring picks up right after. Paced
    /// with the calmer `closeSpring` so the two beats read as one motion.
    static let closeContentFade: TimeInterval = 0.16

    /// The two-beat close. The first beat fades the content out while the shell
    /// holds its expanded size (`closing = true`, `open` still true); the second,
    /// once the content is gone, drops `open` so the shell retracts. This makes the
    /// close symmetric with the open — content and shell move in sequence rather
    /// than clamping shut on one transaction.
    ///
    /// `sequenced` is the caller's reduce-motion gate (the views own that
    /// environment value): when motion is reduced — or when there's nothing to fade
    /// because the panel is already resting — it collapses straight away. Re-entrancy
    /// is safe: a second close request while already `closing` is a no-op, and any
    /// open (`openPanel`/`openSettings`/…) clears `closing` so an interrupted close
    /// that reopens starts clean.
    func beginClose(sequenced: Bool = true) {
        guard open, sequenced else { fullClose(); return }
        guard !closing else { return }
        closing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + NotchModel.closeContentFade) { [weak self] in
            // The close may have been overtaken — a hover re-opened the island, or a
            // full close already fired — in which case `closing` was cleared and this
            // stale beat must not yank the panel shut.
            guard let self, self.closing else { return }
            self.fullClose()
        }
    }

    /// Hard close from Esc / click-outside — always collapses regardless of mode,
    /// including mid-request: an answer still in flight is detached, not cancelled.
    /// The task keeps streaming on its own snapshot (see `submit`) and files the
    /// finished round into Recent, so closing never loses a conversation.
    func fullClose() {
        // A pending leave watch is moot once the panel actually closes.
        cancelLeaveWatch()
        // Park the page the user was on, so a reopen within the TTL lands right
        // back here (closing gestures navigate, they never destroy). A bare idle
        // prompt has nothing worth parking — its unsent draft rides the separate,
        // un-expiring `savedIdleDraft` below. Unconditional overwrite is safe:
        // every close is preceded by an open, and every open consumed or cleared
        // the previous snapshot.
        parkedSession = (mode != .idle || showWhatsNew || showHistory)
            ? ParkedSession(mode: mode, turns: turns, text: text,
                            threadHistoryID: threadHistoryID,
                            showWhatsNew: showWhatsNew,
                            showHistory: showHistory, closedAt: Date(),
                            measuredAnswerHeight: lastMeasuredAnswerHeight,
                            fromPromptShortcut: fromPromptShortcut)
            : nil
        // The measurement now lives in the park (if any). Zero the live mirror so
        // every non-restore open (fresh idle, settings, a different thread) seeds
        // the next NotchBody mount with "unmeasured", exactly as before.
        lastMeasuredAnswerHeight = 0
        // Detach, don't cancel: dropping the reference leaves the Task running
        // (deinit doesn't cancel it) and frees the slot so the next submit's
        // supersede-cancel can't reach the detached round.
        task = nil
        open = false
        // The two-beat close has landed (or this was a direct hard close): the shell
        // is retracting now, so drop the dissolve flag. Clearing it here also disarms
        // any in-flight `beginClose` timer — its `guard self.closing` then no-ops.
        closing = false
        activeDisplay = nil
        // Park an unsent idle draft so the next open can restore it — but only a
        // genuine idle draft: never a follow-up typed on top of an answer
        // (`.result`), and never an empty line. A submit already cleared `text`
        // before any close, so a sent line stashes nothing. `newChat` clears
        // without routing through here, so "start fresh" still lands blank.
        savedIdleDraft = (mode == .idle && hasText) ? text : ""
        mode = .idle
        isAnswerPinned = false
        utilityOverlayPresented = false
        fromPromptShortcut = false
        promptShortcutContext = nil
        clearSelectionContext()
        isModelPickerOpen = false
        isFolderPickerOpen = false
        showModelPicker = false
        showAgentPicker = false
        showAskModelPicker = false
        showAgentFolderPicker = false
        isResultMetadataMenuOpen = false
        text = ""; turns = []
        showHistory = false
        showWhatsNew = false
        confirmingClear = false
        highlightedHistoryIndex = nil
        // Drop any lingering note-save feedback so a fresh open starts clean.
        noteCueTask?.cancel()
        lastSavedNote = nil
        noteError = nil
        noteSaving = false
        // Retire any in-flight capture write's claim (XII-117): bumping the token
        // means a late callback from a write still in its AppleScript retry window
        // won't touch the state we just reset (it still saves its own Recent row).
        captureToken += 1
        // Snapshot the resting clipboard count: the next open baselines against this
        // (the count from *before* the user's next copy-then-open), so a copy made
        // while the notch is closed still reads as fresh context on the next Ask.
        pasteboardChangeCountAtRest = NSPasteboard.general.changeCount
        // The sense watcher resumes from here too: anything written or copied
        // during the session (handoff copy, code-block copy, in-panel ⌘C) is
        // already accounted for and can never hint on the way out.
        senseLastChangeCount = pasteboardChangeCountAtRest
    }

    /// "Back" / start a new conversation: drop the current Q&A from the screen and
    /// return to the idle input — but stay OPEN, so the user lands straight on a
    /// fresh prompt instead of the panel collapsing. Triggered by the back button
    /// in a result view and by the ← arrow key. Like `fullClose`, an answer still
    /// in flight is detached rather than cancelled — it finishes in the background
    /// and lands in Recent, so backing out while waiting never loses the round.
    func newChat() {
        task = nil
        // ← / ⌘N is the one gesture that DESTROYS a session (closing only parks).
        // Drop any parked page too, so "start fresh" can't be haunted by a
        // snapshot from before the reset.
        parkedSession = nil
        // The park is gone; so must the parked height measurement. Left in place,
        // a long thread's >300pt value would seed the next NotchBody mount into
        // the clipped full-height layout for a brand-new short chat. NotchBody
        // zeroes its live @State when `turns` empties below — this covers the
        // mirror when the body isn't mounted to see that change.
        lastMeasuredAnswerHeight = 0
        mode = .idle
        isAnswerPinned = false
        fromPromptShortcut = false
        promptShortcutContext = nil
        clearSelectionContext()
        agentDetailTaskID = nil
        text = ""; turns = []
        showHistory = false
        highlightedHistoryIndex = nil
        // Clear the note/reminder-save state, exactly like `fullClose` does (XII-86).
        // Backing out with Back while a Note/Reminder write is still in flight (e.g.
        // an AppleScript retry) used to leave `noteSaving` stuck true here. Resetting
        // it (plus the cue task and feedback fields) keeps the next session clean.
        noteCueTask?.cancel()
        lastSavedNote = nil
        noteError = nil
        noteSaving = false
        // Retire any in-flight capture write's claim (XII-117) — see fullClose.
        captureToken += 1
        // Re-baseline the clipboard against NOW. The handoff-copy button writes the
        // transcript to the pasteboard (bumping changeCount past the open baseline);
        // without this reset, the next first-turn Ask would mistake our own handoff
        // text for "something the user copied to ask about" and inject it.
        pasteboardChangeCountAtOpen = NSPasteboard.general.changeCount
    }
    // MARK: - Open width per state (matches the prototype's s-* widths)

    var openWidth: CGFloat {
        // What's New is a reading surface — give it the same comfortable column
        // as the result view. Also shows only over idle, so it wins like settings.
        if showWhatsNew { return Tokens.openWidthWhatsNew }
        switch mode {
        case .result: return Tokens.openWidthResult
        // A follow-up loads with the thread already on screen (shown via the result
        // view), so it must keep the result width — only the first question, with
        // nothing on screen yet, uses the narrower load width.
        case .load:   return turns.isEmpty ? Tokens.openWidthLoad : Tokens.openWidthResult
        case .idle:   return hasText ? Tokens.openWidthIdle : Tokens.openWidthIdle
        }
    }
}
