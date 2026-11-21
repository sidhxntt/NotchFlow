import SwiftUI
import Combine
import AppKit   // NSWorkspace — opening Notes/Reminders for a Recent capture
import Carbon.HIToolbox
import UniformTypeIdentifiers   // UTType — is a pasted file URL an image? (agent ⌘V)

@MainActor
extension NotchModel {
    // MARK: - Detached session windows (tear-off)

    /// The live tear-off drag, while the ghost card is still attached to the
    /// island: set by the header drag gesture (NotchBody), rendered as the ghost
    /// card + goo bridge by NotchIsland's overlay.
    struct DetachDrag: Equatable {
        var session: DetachedSession
        var face: DetachedCardFace
        /// Raw pointer translation since the grab, unclamped.
        var translation: CGSize = .zero
    }

    /// How far the grab must travel (raw, unclamped) before the panel tears
    /// free into its window. Short — the tear should feel immediate, the
    /// pre-phase is just accident insurance.
    static let detachThreshold: CGFloat = 60

    /// The attached phase's rubber band: the pull follows the hand with rising
    /// resistance, saturating at `limit` — the glass giving, not the panel
    /// escaping. tanh keeps the response smooth from the very first point.
    static func detachRubberized(_ t: CGSize, limit: CGFloat = 96) -> CGSize {
        let mag = (t.width * t.width + t.height * t.height).squareRoot()
        guard mag > 0.5 else { return .zero }
        let eff = limit * CGFloat(tanh(Double(mag / limit)))
        return CGSize(width: t.width * eff / mag, height: t.height * eff / mag)
    }

    /// 0…1 how close this pull is to the tear threshold.
    static func detachProgress(_ t: CGSize) -> CGFloat {
        min((t.width * t.width + t.height * t.height).squareRoot() / detachThreshold, 1)
    }

    /// What a tear-off from the current page would carry: the open agent-run
    /// detail if one is up, the on-screen thread next, and — with neither — the
    /// idle prompt itself, which tears out as a standalone composer (`.compose`).
    /// Nil only on the pages that own the whole body (settings, What's New),
    /// which have nothing to carry.
    var detachableSession: DetachedSession? {
        guard open, !showWhatsNew else { return nil }
        if let id = agentDetailTaskID { return .agentTask(id: id) }
        if mode != .idle, !turns.isEmpty, !showHistory {
            return .thread(id: threadHistoryID)
        }
        if mode == .idle, turns.isEmpty { return .compose }
        return nil
    }

    /// The face the tear-off card wears — computed at grab time so ghost and
    /// window render the same card.
    private func detachedFace(for session: DetachedSession) -> DetachedCardFace {
        switch session {
        case .compose:
            // A composer carries no session — the draft in the box is the only
            // thing it has to show for a face (empty on a bare prompt).
            return DetachedCardFace(
                title: text.replacingOccurrences(of: "\n", with: " "),
                subtitle: L("input.placeholder"),
                isAgent: agentComposeActive,
                running: false)
        case .shortcutComposer:
            return DetachedCardFace(
                title: L("shortcuts.promptAction.window.context"),
                subtitle: "", isAgent: false, running: false)
        case .agentTask(let id):
            if let task = AgentTaskManager.shared.tasks.first(where: { $0.id == id }) {
                return DetachedCardFace(
                    title: task.prompt.replacingOccurrences(of: "\n", with: " "),
                    subtitle: "\(task.engine.displayName) · \(task.folder.lastPathComponent)",
                    isAgent: true,
                    running: task.isRunning)
            }
            return DetachedCardFace(title: L("detached.task.gone"), subtitle: "",
                                    isAgent: true, running: false)
        case .thread:
            let q = turns.first(where: { $0.role == "user" })?.text ?? ""
            let streaming = turns.contains { $0.streaming }
            return DetachedCardFace(
                title: q.replacingOccurrences(of: "\n", with: " "),
                subtitle: streaming ? L("busy.writing") : L("detached.thread.subtitle"),
                isAgent: threadIsAgentRun,
                running: streaming)
        }
    }

    /// Drag tick from the header gesture. Arms the ghost on the first tick,
    /// stretches the membrane while attached, and fires the tear-off once the
    /// pull crosses the threshold.
    func detachDragChanged(_ translation: CGSize) {
        guard !detachHandedOff else { return }
        if detachDrag == nil {
            guard let session = detachableSession else { return }
            detachDrag = DetachDrag(session: session, face: detachedFace(for: session))
        }
        detachDrag?.translation = translation
        if Self.detachProgress(translation) >= 1 { tearOff() }
    }

    /// Release under the threshold: the membrane pulls the card home.
    func detachDragEnded() {
        detachHandedOff = false
        guard detachDrag != nil else { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.68)) {
            detachDrag = nil
        }
    }

    /// The split: the COMPLETE window is born in place over the panel — same
    /// position, full session content, no thumbnail stage — and rides the mouse
    /// from here (the window controller owns the rest of the drag). The panel
    /// lets the session go and folds underneath it.
    private func tearOff() {
        guard let drag = detachDrag else { return }
        detachHandedOff = true
        Haptics.alignment()
        let session = drag.session
        let face = drag.face
        if let spawnRect = detachWindowSpawnRect() {
            DetachedSessionWindowController.beginDragDetach(
                session: session, face: face, model: self, spawnRect: spawnRect)
        } else {
            // Geometry unknown (shouldn't happen mid-drag) — still honor the
            // intent: open the window in place without the ride.
            DetachedSessionWindowController.present(
                session: session, face: face, model: self, from: nil)
        }
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) { detachDrag = nil }
        completeDetach(of: session)
    }

    /// V0 (no drag): the header button — the same full window, fading in right
    /// over the panel.
    func openDetachedWindow() {
        guard let session = detachableSession else { return }
        let face = detachedFace(for: session)
        DetachedSessionWindowController.present(
            session: session, face: face, model: self,
            from: detachWindowSpawnRect())
        completeDetach(of: session)
    }

    /// The session left for a window: clear it off the panel (stream keeps
    /// going detached, exactly like `newChat`) and fold the shell.
    private func completeDetach(of session: DetachedSession) {
        switch session {
        case .compose:
            // The draft left with the window (the controller took a copy at
            // birth) — clear it here so the folding panel doesn't park it as an
            // idle draft and hand the same line back on the next open.
            text = ""
            showHistory = false
            highlightedHistoryIndex = nil
        case .shortcutComposer:
            // Compact shortcut composers are born outside the panel and never
            // pass through this detach path.
            break
        case .agentTask:
            agentDetailTaskID = nil
        case .thread:
            task = nil          // detach, never cancel — the round streams on
            parkedSession = nil // the window owns the page now; nothing to restore
            turns = []
            text = ""
            mode = .idle
            isAnswerPinned = false
            fromPromptShortcut = false
        }
        beginClose()
    }

    /// A detached window is closing / merging home: put the session back on the
    /// panel. A still-streaming thread reattaches its live round; a settled one
    /// reopens from Recent; `snapshot` is the window's last view of a thread
    /// that never reached history (edge insurance, not the normal path).
    func reattachDetachedSession(_ session: DetachedSession, snapshot: [Turn]?,
                                 draft: String = "",
                                 on display: CGDirectDisplayID?) {
        openPanel(on: display ?? activeDisplay)
        switch session {
        case .compose:
            // Nothing to restore but the line being written — hand the window's
            // draft back to the prompt (written after `openPanel`, which may
            // have restored a parked draft of its own).
            if !draft.isEmpty { text = draft }
        case .shortcutComposer:
            // This transient face has no panel representation to reattach to.
            break
        case .agentTask(let id):
            if AgentTaskManager.shared.tasks.contains(where: { $0.id == id }) {
                agentDetailTaskID = id
            }
        case .thread(let id):
            if let round = inFlightRounds.first(where: { $0.threadID == id }) {
                attachInFlightRound(round)
            } else if let item = history.first(where: { $0.id == id }),
                      !item.pending, item.source.isThread {
                openHistory(item)
            } else if let snapshot,
                      snapshot.contains(where: { $0.role == "assistant" && !$0.text.isEmpty }) {
                var cleaned = snapshot
                for i in cleaned.indices {
                    cleaned[i].streaming = false
                    cleaned[i].toolActivity = nil
                }
                turns = cleaned
                threadHistoryID = id
                mode = .result
            }
        }
    }

    func adoptDetachedThread(_ threadID: UUID) -> DetachedThreadStore {
        if let existing = detachedThreadStores[threadID] { return existing }
        let historyItem = history.first(where: { $0.id == threadID })
        let seed: [Turn]
        if let round = inFlightRounds.first(where: { $0.threadID == threadID }) {
            seed = round.thread
        } else if threadHistoryID == threadID, !turns.isEmpty {
            seed = turns
        } else {
            seed = historyItem?.conversation ?? []
        }
        let isAgent = historyItem?.source == .agent
        let supportsImages: Bool
        if isAgent,
           let rawEngine = historyItem?.agentResume?.engine,
           let engine = AgentEngine(rawValue: rawEngine) {
            supportsImages = engine.supportsImageInput
        } else {
            supportsImages = activeModelSupportsVision
        }
        let store = DetachedThreadStore(
            threadID: threadID,
            turns: seed,
            agentFolderPath: isAgent ? historyItem?.link : nil,
            completedAt: isAgent ? historyItem?.t : nil,
            followUpSupportsImages: supportsImages)
        detachedThreadStores[threadID] = store
        return store
    }

    func releaseDetachedThread(_ threadID: UUID) {
        detachedThreadStores[threadID] = nil
    }

    /// A follow-up typed in a detached thread window. The round runs through
    /// the exact panel pipeline (`submit`) so tools, persistence, and Recent
    /// behave identically — borrowed headless: the thread is loaded into the
    /// panel state just long enough for `submit()` to arm the round, then
    /// everything is put back and the new round is left detached ("detach,
    /// never cancel" — the same hand-off as the tear-off itself). The round's
    /// snapshots reach the window via `syncInFlight` → `detachedThreadStores`.
    func submitDetachedFollowUp(threadID: UUID, question: String,
                                images: [NSImage] = []) {
        guard LicenseService.shared.state.allowsProductServices else { return }
        var q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            guard !images.isEmpty else { return }
            q = Self.agentImageOnlyPrompt(count: images.count)
        }
        // The panel is sitting on this very thread: an ordinary panel submit —
        // both surfaces hear every chunk.
        if threadHistoryID == threadID, !turns.isEmpty {
            text = q
            askComposeImages = images
            submit()
            return
        }
        runDetachedRound(threadID: threadID, seed: detachedSeed(for: threadID),
                         question: q, images: images)
    }

    /// Regenerate the last settled answer from a detached thread window — the
    /// window footer's ↻, mirroring `regenerateLastAnswer`: drop the newest
    /// Q/A pair from the seed and re-run the question, optionally pinned to a
    /// model for this one round (XII-135).
    func regenerateDetachedAnswer(threadID: UUID, model: String? = nil) {
        guard LicenseService.shared.state.allowsProductServices else { return }
        if threadHistoryID == threadID, !turns.isEmpty {
            regenerateLastAnswer(model: model)
            return
        }
        var seed = detachedSeed(for: threadID)
        guard let last = seed.last, last.role == "assistant", !last.streaming,
              !last.isAgent else { return }
        seed.removeLast()
        guard let questionTurn = seed.last, questionTurn.role == "user" else { return }
        seed.removeLast()
        let pin = model.map { ModelPin(provider: APIKeyStore.selectedProvider, model: $0) }
        runDetachedRound(threadID: threadID, seed: seed,
                         question: questionTurn.text, pin: pin)
    }

    /// The thread a detached-window round starts from: the window's live
    /// mirror, else the persisted row (mirror already released — shouldn't
    /// happen while the window is open, but never start from nothing).
    private func detachedSeed(for threadID: UUID) -> [Turn] {
        detachedThreadStores[threadID]?.turns
            ?? history.first(where: { $0.id == threadID })?.conversation
            ?? []
    }

    /// The headless borrow shared by the window's follow-up and regenerate:
    /// swap the thread into the panel state, let `submit()` arm the round
    /// (it captures its own snapshot + thread id immediately), then restore
    /// the panel exactly as it was and leave the round streaming detached.
    /// Returns the thread id the round actually landed on — the caller's id for
    /// a follow-up, a brand-new one when `submit()` treated the (empty) seed as
    /// a fresh thread. A compose window uses it to become that thread.
    @discardableResult
    func runDetachedRound(threadID: UUID, seed: [Turn], question: String,
                                  hideUserBubble: Bool = false,
                                  trackCompactTask: Bool = false,
                                  pin: ModelPin? = nil,
                                  origin: HistoryItem.Origin? = nil,
                                  images: [NSImage] = []) -> UUID? {
        guard LicenseService.shared.state.allowsProductServices else { return nil }
        // Never stack rounds on one thread from the window: the tear-off
        // dropped the round's task handle, so a second submit couldn't
        // supersede-cancel the first. The field is disabled while streaming;
        // this is the backstop.
        guard !seed.contains(where: { $0.streaming }) else { return nil }
        // A detached round borrows the main submit pipeline, not the main
        // composer's transient state. Preserve every value submit mutates
        // synchronously, then give this round its own empty image payload and
        // one-shot model pin. Otherwise a Force Touch fired while the main box
        // holds pasted images or a pending regenerate choice can consume them.
        let highlightedID = highlightedHistoryIndex.flatMap { index in
            history.indices.contains(index) ? history[index].id : nil
        }
        let saved = (turns: turns, threadID: threadHistoryID, mode: mode,
                     text: text, task: task, pinned: isAnswerPinned,
                     error: askError, history: showHistory,
                     highlightedID: highlightedID,
                     fromPromptShortcut: fromPromptShortcut,
                     composeImages: askComposeImages,
                     regenModel: regenOverrideModel,
                     regenProvider: regenOverrideProvider)
        armModelPin(pin)
        askComposeImages = images
        task = nil                                    // detach, never cancel
        turns = seed
        threadHistoryID = threadID
        text = question
        submit(hideUserBubble: hideUserBubble)
        // A fresh submit synchronously parks its Recent placeholder. Stamp the
        // entry point before handing the round off; `persistThread` carries this
        // field forward when it replaces the placeholder with the settled row.
        if let origin,
           let index = history.firstIndex(where: { $0.id == threadHistoryID }) {
            history[index].origin = origin
        }
        // A regenerate that emptied the seed re-ids the thread (`submit`
        // treats it as fresh) — re-key the window's mirror so it keeps
        // hearing the round under the new id.
        if threadHistoryID != threadID, let store = detachedThreadStores[threadID] {
            detachedThreadStores.removeValue(forKey: threadID)
            store.threadID = threadHistoryID
            detachedThreadStores[threadHistoryID] = store
        }
        // Show the fresh question pair in the window right away — the first
        // `syncInFlight` only lands with the first token.
        if let store = detachedThreadStores[threadHistoryID] {
            store.turns = turns
        } else {
            // A compose window's FIRST question has no mirror yet: mint one here,
            // already holding the pair, so the window adopts a live thread rather
            // than an empty one waiting for the first token.
            detachedThreadStores[threadHistoryID] =
                DetachedThreadStore(threadID: threadHistoryID, turns: turns,
                                    followUpSupportsImages: activeModelSupportsVision)
        }
        let landedThreadID = threadHistoryID
        if trackCompactTask, let task {
            compactRoundTasks[landedThreadID] = task
        }
        // Hand the round off detached and put the panel back exactly as it was.
        task = saved.task
        turns = saved.turns
        threadHistoryID = saved.threadID
        mode = saved.mode
        text = saved.text
        isAnswerPinned = saved.pinned
        askError = saved.error
        showHistory = saved.history
        highlightedHistoryIndex = saved.highlightedID.flatMap { id in
            history.firstIndex(where: { $0.id == id })
        }
        fromPromptShortcut = saved.fromPromptShortcut
        askComposeImages = saved.composeImages
        regenOverrideModel = saved.regenModel
        regenOverrideProvider = saved.regenProvider
        return landedThreadID
    }

    /// Enter pressed in a detached compose window (the torn-out idle prompt).
    /// Routes exactly like the notch's own prompt — the window classified its
    /// own line and hands the destination in — but keeps everything headless:
    /// Note/Remind file through the identical services (their feedback lands on
    /// the model, which the window mirrors), an armed Agent bucket spawns its
    /// run, and an Ask runs the round detached and returns the thread id so the
    /// window can become that conversation in place.
    @discardableResult
    func submitDetachedCompose(_ line: String, destination: Panel) -> UUID? {
        guard LicenseService.shared.state.allowsProductServices else { return nil }
        let q = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        if agentComposeActive {
            borrowingText(q) { submitAgent() }
            return nil
        }
        switch destination {
        case .note:
            borrowingText(q) { submitNote() }
            return nil
        case .reminder:
            borrowingText(q) { submitReminder() }
            return nil
        case .chat:
            return runDetachedRound(threadID: UUID(), seed: [], question: q)
        }
    }

    /// Run a panel submit path against a line that isn't in the panel's box:
    /// park `text`, hand the borrowed line over, then put the panel's own draft
    /// back (every one of these paths clears `text` itself on the way through).
    private func borrowingText(_ line: String, _ body: () -> Void) {
        let saved = text
        text = line
        body()
        text = saved
    }

    /// Screens whose panels have registered geometry — the merge zones a
    /// detached window tests its drag against.
    var knownDisplays: [CGDirectDisplayID] { Array(panelScreenFrames.keys) }

    /// The island's current on-screen rect (bottom-left origin screen coords).
    func islandScreenRect(on display: CGDirectDisplayID?) -> CGRect? {
        guard let display,
              let panel = panelScreenFrames[display],
              let island = islandFrames[display] else { return nil }
        return CGRect(x: panel.minX + island.minX,
                      y: panel.maxY - island.maxY,
                      width: island.width, height: island.height)
    }

    /// The resting notch's on-screen rect — the merge drop zone. Sized from the
    /// measured cutout so the zone follows a resolution change with the island;
    /// the constant is only the no-cutout fallback.
    func restingNotchScreenRect(on display: CGDirectDisplayID?) -> CGRect? {
        guard let display,
              let panel = panelScreenFrames[display],
              let restHeight = restHeights[display] else { return nil }
        let width = hardwareNotchWidths[display].map { $0 + Tokens.notchDrawnOverhang }
            ?? Tokens.notchWidth
        return CGRect(x: panel.midX - width / 2,
                      y: panel.maxY - restHeight,
                      width: width, height: restHeight)
    }

    /// Where a detached window is born: the panel's own glass body — same
    /// left/right edges, top just under the notch zone — so the tear reads as
    /// the panel itself coming off the bezel. Clamped to a usable session size
    /// (extending downward) and onto the screen.
    private func detachWindowSpawnRect() -> CGRect? {
        guard let display = activeDisplay,
              let island = islandScreenRect(on: display),
              let restHeight = restHeights[display] else { return nil }
        let minSize = CGSize(width: 560, height: 420)
        var rect = CGRect(x: island.minX,
                          y: island.minY,
                          width: island.width,
                          height: max(island.height - restHeight, 0))
        if rect.width < minSize.width {
            rect.origin.x -= (minSize.width - rect.width) / 2
            rect.size.width = minSize.width
        }
        if rect.height < minSize.height {
            rect.origin.y -= minSize.height - rect.height   // grow downward
            rect.size.height = minSize.height
        }
        if let screen = NSScreen.screens.first(where: { $0.displayID == display })?.visibleFrame {
            rect.origin.x = max(screen.minX + 8, min(rect.origin.x, screen.maxX - rect.width - 8))
            rect.origin.y = max(screen.minY + 8, min(rect.origin.y, screen.maxY - rect.height - 8))
        }
        return rect
    }

    /// Recompute `detectedDue` off the main thread. `futureDate`/`recurrenceDate`
    /// run NSDataDetector + a handful of regexes; cheap per call, but synchronous
    /// in `text.didSet` they billed every keystroke to the main thread — visible
    /// jank during fast (IME) typing. Run them detached and publish back on the
    /// main actor, guarding that `text` is still the snapshot we read so a stale
    /// result can never land. Empty text resolves synchronously to nil so the hint
    /// clears instantly on delete-all.
    func scheduleDueDetection() {
        dueTask?.cancel()
        let snapshot = text
        guard !snapshot.isEmpty else {
            detectedDue = nil
            return
        }
        dueTask = Task { [weak self] in
            let due = await Task.detached {
                RemindersService.futureDate(in: snapshot)
                    ?? RemindersService.recurrenceDate(in: snapshot)
            }.value
            guard !Task.isCancelled, let self, self.text == snapshot else { return }
            self.detectedDue = due
        }
    }

    /// The pin this launch opens with. Normally just what was stored — except on
    /// the FIRST launch after the Note/Remind → Capture merge, which resets it to
    /// Ask so the new single Capture door is read from the resting state rather
    /// than from a leftover pinned Note/Remind. Runs once.
    static var startingSubmitMode: Panel? {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: captureMergeResetKey) {
            defaults.set(true, forKey: captureMergeResetKey)
            storedSubmitMode = nil
        }
        return storedSubmitMode
    }
    private static let captureMergeResetKey = "captureMergeModeReset"

    /// The pinned destination as it survives a relaunch. Written only by the
    /// explicit doors (Tab, `/`, a typed `:`) — never by the transient nils the
    /// agent compose and image attach set on the live property, which are about
    /// this line and shouldn't rewrite what the user chose.
    static var storedSubmitMode: Panel? {
        get { (UserDefaults.standard.string(forKey: submitModeKey)).flatMap(Panel.init(rawValue:)) }
        set {
            let defaults = UserDefaults.standard
            if let newValue { defaults.set(newValue.rawValue, forKey: submitModeKey) }
            else { defaults.removeObject(forKey: submitModeKey) }
        }
    }
    private static let submitModeKey = "pinnedSubmitMode"

    /// Pin a destination through one of the explicit doors: set it live AND
    /// remember it. The one funnel, so a door can't be added later that changes
    /// the mode without making it stick.
    func pinSubmitPanel(_ panel: Panel?) {
        manualPanelOverride = panel
        Self.storedSubmitMode = panel
    }

    func activateTypedNoteMode(trigger: Character) {
        setAgentBucket(false)
        promptShortcutMode = nil
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            typedNoteTriggerPrefix = String(trigger)
            typedNoteModeActive = true
            pinSubmitPanel(.note)
        }
    }

    /// Where pressing Enter on the *current* text will actually land. Nothing
    /// here reads the text: the destination is Ask until the USER says otherwise
    /// (a typed `:`, Tab, or a `/` command), and it stays put until they say so
    /// again. The classifier used to get a vote here and could flip the
    /// destination out from under a half-typed line; a wrong guess silently filed
    /// a question into Notes, and a right one still made the word beside the
    /// caret jitter while you typed. Guessing is not worth either.
    ///
    /// The engine itself is still around — the ⌘C clipboard hint runs on it
    /// (`senseClassify`), where an unsure read costs nothing because the user has
    /// to confirm the hint anyway.
    var effectiveSubmitPanel: Panel {
        guard turns.isEmpty else { return .chat }
        let resolved = manualPanelOverride ?? .chat
        // Capture names the BUCKET, not which of its two leaves the line lands
        // in: a captured line that names a time is filed in Reminders, everything
        // else in Notes. This is invisible — nothing in the UI switches on it —
        // it only picks which service `submitCurrent` hands the line to.
        // `/remind` is the one thing that pins a leaf, so an explicit `.reminder`
        // override (a dateless reminder) is left alone here.
        if resolved == .note, detectedDue != nil { return .reminder }
        return resolved
    }

    /// True while a typed-`:` capture line is still nothing but its trigger
    /// glyph — the one moment the little explanation beside the caret is for.
    /// The instant real text lands, that slot belongs to `captureLeaf`, which
    /// says the thing the explanation can't: where *this* line is going.
    var typedNoteHintOnly: Bool {
        guard typedNoteModeActive, let trigger = typedNoteTriggerPrefix else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines) == trigger
    }

    /// Which leaf of Capture the line in the box is heading for — `.note` or
    /// `.reminder` — or nil when the panel isn't capturing, or has nothing to
    /// capture yet. The split is `effectiveSubmitPanel`'s own, driven by
    /// `detectedDue` and recomputed off every keystroke; this only surfaces it.
    /// Capture used to make that call in silence, so a line naming a time filed
    /// itself into Reminders with nothing on screen having said so.
    var captureLeaf: Panel? {
        guard turns.isEmpty, !submitGoesToAgent, hasText, !typedNoteHintOnly else { return nil }
        switch effectiveSubmitPanel {
        case .chat:              return nil
        case .note, .reminder:   return effectiveSubmitPanel
        }
    }

    /// The word for `captureLeaf`, in the app's own destination vocabulary.
    var captureLeafLabel: String? {
        switch captureLeaf {
        case .note:     return L("hint.note")
        case .reminder: return L("hint.remind")
        default:        return nil
        }
    }

    /// Tab in the idle prompt: step where Enter will send the current line
    /// (Ask → Note → Remind → Ask…), overriding the classifier. Steps from
    /// whatever the *effective* destination is right now — including a prior
    /// override — so each press reads as "the next one", exactly what the cycled
    /// inline hint shows. The cycle stays INSIDE the Ask bucket: Agent is not a
    /// stop — it's the bucket pill's job (`setAgentBucket`). Keeping the
    /// heavyweight mode off an ambient navigation key is what makes mashing Tab
    /// through a wrong note/remind guess safe; a misrouted note costs nothing,
    /// a misrouted agent arm is a surprise. Tab while armed is inert: stepping
    /// off the Agent bucket is Shift-Tab's job (or the pill's Ask half).
    ///
    /// It also works on the EMPTY prompt, where there is no "current line" yet:
    /// the press arms a destination for the line about to be typed, the same pin
    /// a `/` command sets, and `idlePlaceholderKey` shows which one is armed.
    /// Since the pin only lifts when the field EMPTIES (`text.didSet`), one armed
    /// on an already-empty field survives right through the typing that follows.
    func toggleSubmitPanel() {
        // Armed on Agent, plain Tab does NOTHING. The Ask → Note → Remind cycle
        // is a *within-bucket* correction, and the agent compose isn't in that
        // bucket — a stray Tab there used to tear the whole compose down (folder,
        // chips, typed task) as a side effect of a key people mash. Leaving the
        // bucket is Shift-Tab's job (`toggleAgentBucket`) or the pill's Ask half.
        guard !agentComposeActive else { return }
        // One spring for the whole switch. The four call sites (Tab in the panel,
        // Tab in the detached window, and both ⌘-cycle paths) all called this
        // bare, so the pill's word, the pill's WIDTH, and the model chip that
        // only Ask carries each snapped to their new state in a single frame.
        // Animating here rather than at the call sites means they can't drift
        // apart again.
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            typedNoteTriggerPrefix = nil
            typedNoteModeActive = false
            switch effectiveSubmitPanel {
            case .chat:              pinSubmitPanel(.note)
            case .note, .reminder:   pinSubmitPanel(nil)
            }
        }
    }

    /// Whether any local agent CLI is installed + signed in — gates the bucket
    /// pill. Cheap after the launch `warmUp()`: binary resolution is cached and
    /// the sign-in probe is a file-exists.
    var agentAvailable: Bool { !AgentEngine.available.isEmpty }

    /// The bucket pill's two taps — an idempotent "set", not a toggle, so
    /// clicking the word that's already active is a no-op instead of a surprise
    /// flip. Ask restores the lightweight bucket with the classifier back in
    /// charge (no manual override — the pill picks a bucket, not a destination
    /// within one); Agent arms the compose exactly like the folder-drop path,
    /// seeded with the remembered project folder when there is one. Arming is
    /// deliberately cheap and reversible: it only unfurls the chips row — a run
    /// still needs a folder, a typed task, and an explicit Enter.
    func setAgentBucket(_ armed: Bool) {
        if armed {
            guard !agentComposeActive else { return }
            enterAgentCompose()
        } else {
            guard agentComposeActive else { return }
            // Restore the pinned destination BEFORE Agent switches off. Otherwise
            // `effectiveSubmitPanel` renders one transient Ask frame (the live
            // override is nil while Agent is armed) and only then becomes Capture,
            // making the destination half visibly jump on the way back.
            manualPanelOverride = Self.storedSubmitMode
            exitAgentCompose()
        }
    }

    /// Shift-Tab in the idle prompt: flip the bucket between Ask and Agent — the
    /// keyboard twin of tapping the `BucketTogglePill`. Kept off the plain-Tab
    /// cycle on purpose: Tab stays inside the lightweight Ask bucket (Ask → Note
    /// → Remind), so mashing it through a wrong note/remind guess can never
    /// surprise you into arming the heavyweight agent mode — that gets its own
    /// key. A no-op that stays on Ask when no agent CLI is installed, since
    /// `setAgentBucket` → `enterAgentCompose` already guards on availability.
    func toggleAgentBucket() {
        setAgentBucket(!agentComposeActive)
    }
}
