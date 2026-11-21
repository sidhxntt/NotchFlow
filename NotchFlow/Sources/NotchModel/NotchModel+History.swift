import SwiftUI
import Combine
import AppKit   // NSWorkspace — opening Notes/Reminders for a Recent capture
import Carbon.HIToolbox
import UniformTypeIdentifiers   // UTType — is a pasted file URL an image? (agent ⌘V)

@MainActor
extension NotchModel {
    /// The question strings ↑/↓ recall walks, newest first — the active bucket's
    /// `history` values with **adjacent duplicates collapsed** (bash `ignoredups`). Asking the
    /// same thing twice in a row leaves one entry here, so ↑ never fills the same
    /// line twice running and the "x / total" counter counts distinct consecutive
    /// questions. Non-adjacent repeats (asked A, then B, then A again) are kept —
    /// only *consecutive* duplicates fold.
    private var recallQuestions: [String] {
        var out: [String] = []
        for item in history where
            (agentComposeActive ? item.source == .agent : item.source != .agent) {
            // `history` is newest-first; recall stays inside the active bucket.
            if out.last != item.q { out.append(item.q) }
        }
        return out
    }
    /// Whether a ↑/↓ recall session is currently active — the idle prompt's
    /// `PromptField` uses this to keep routing ↑/↓ to recall even after the box is
    /// no longer empty (so "press ↑ again to go further back" works).
    var isRecallingHistory: Bool { historyRecallIndex != nil }

    /// Where the ↑/↓ recall cursor currently sits, for the little "3 / 12" counter
    /// the idle prompt shows in place of the clipboard quote while recalling.
    /// `pos` is 1-based (newest = 1); `total` is the history depth, both capped at
    /// 99 so the readout never overflows its slot. `nil` when no recall is active.
    var recallPosition: (pos: Int, total: Int)? {
        guard let i = historyRecallIndex else { return nil }
        return (min(i + 1, 99), min(recallQuestions.count, 99))
    }

    /// A tick that bumps on every successful ↑/↓ recall step, carrying the step's
    /// direction. The idle input row observes it to fire a small directional
    /// slide-in as the recalled question swaps in: `.older` (↑) slides down from
    /// above, `.newer` (↓) slides up from below. Purely a view cue — never
    /// persisted, and it doesn't gate any behaviour.
    enum RecallDirection { case older, newer }
    private func pulseRecall(_ dir: RecallDirection) {
        recallPulse = (recallPulse.n + 1, dir)
    }

    /// How many recent rows the *notch* list keeps — the compact quick-access slice.
    /// The full archive is retained on disk without limit (see `saveHistory`); the
    /// notch stays light by rendering only the newest `notchRecentCap`. Everything
    /// older is one click away in the standalone History window (`archiveVisible`).
    static let notchRecentCap = 100

    /// The recent items rendered in the *notch* list — the newest `notchRecentCap`
    /// of the (filtered) history, not the whole archive. The list scrolls, and
    /// keyboard nav auto-scrolls the highlight into view, so every visible item is
    /// reachable. Keyboard navigation indexes into THIS, so highlight bounds and the
    /// rendered rows can never drift apart. Older items live in the History window.
    ///
    /// A run whose task is still in the agent tray is already on screen as its
    /// status row (settled card, or a live re-run), directly above this list —
    /// so its filed record is held back here rather than stacking the same title
    /// twice. Dismissing the card reveals the record row; the archive window
    /// (`archiveVisible`) never hides it. (Freshness rides on views also
    /// observing `AgentTaskManager`, whose task changes re-render them.)
    var recentVisible: [HistoryItem] {
        let trayIDs = Set(AgentTaskManager.shared.tasks.map(\.id))
        guard !trayIDs.isEmpty else {
            return Array(recentFilteredHistory.prefix(NotchModel.notchRecentCap))
        }
        return Array(recentFilteredHistory.lazy.filter { !trayIDs.contains($0.id) }
            .prefix(NotchModel.notchRecentCap))
    }

    /// The FULL filtered history, newest-first — every retained item, uncapped.
    /// Backs the standalone History window so nothing captured is ever out of reach.
    var archiveVisible: [HistoryItem] { filteredHistory }

    /// Settled conversations created by the Force Touch popup, newest first.
    /// This is the popup's private drawer rather than another Chat/Agent bucket,
    /// so it never inherits those surfaces' search or source filters.
    var forceTouchHistory: [HistoryItem] {
        history.filter { $0.origin == .forceTouch && !$0.pending && $0.source.isThread }
    }

    /// The unsearched size of the bucket currently owning Recent. Agent compose
    /// sees only agent conversations; Chat owns Ask / Notes / Reminders.
    /// Footer affordances use this instead of the global archive count so an Agent
    /// list never advertises rows that are outside its scope.
    var recentScopeHistoryCount: Int {
        history.lazy.filter { item in
            self.agentComposeActive ? item.source == .agent : item.source != .agent
        }.count
    }

    private var recentFilteredHistory: [HistoryItem] {
        if agentComposeActive {
            if let cached = agentFilteredHistoryCache { return cached }
            var items = history.filter { $0.source == .agent }
            if !historySearchQuery.isEmpty {
                items = items.filter {
                    $0.displayTitle.localizedCaseInsensitiveContains(historySearchQuery)
                }
            }
            agentFilteredHistoryCache = items
            return items
        }

        // Chat is a sibling bucket, not the old all-source ledger: Agent rows
        // never bleed into it. The optional source filter can only narrow within
        // Ask / Notes / Reminders.
        return filteredHistory.filter { $0.source != .agent }
    }

    /// The global filter pipeline retained for the standalone all-history archive.
    /// The notch's two bucket scopes live in `recentFilteredHistory`.
    private var filteredHistory: [HistoryItem] {
        if let cached = filteredHistoryCache { return cached }
        var items = history
        if let source = historySourceFilter {
            items = items.filter { $0.source == source }
        }
        if !historySearchQuery.isEmpty {
            items = items.filter {
                $0.displayTitle.localizedCaseInsensitiveContains(historySearchQuery)
            }
        }
        filteredHistoryCache = items
        return items
    }
    // MARK: - Archive as context (search_history)

    /// Answer one `search_history` call: the slice of the user's own archive the
    /// model asked for, flattened to the digest rows it actually reads.
    ///
    /// Deliberately NOT `filteredHistory`: that pipeline serves the on-screen list
    /// (its inputs are the UI's own filter chips, and its text match only looks at
    /// `displayTitle`, so a keyword that appears in the body of a note finds
    /// nothing). This one is a real content search over the whole row, and it must
    /// never be perturbed by — or perturb — whatever the user has typed into the
    /// Recent filter field.
    ///
    /// Two rows are always withheld:
    ///  • **`pending`** — the question being answered right now is parked in
    ///    `history` the instant it's submitted (`parkPending`), so without this the
    ///    model would find the very question it is currently answering and report
    ///    it back as a past activity.
    ///  • **the thread on screen** — already in the wire context verbatim; the tool
    ///    exists for what's *outside* the current conversation.
    func searchArchive(_ query: HistoryQuery) -> HistoryDigest {
        Self.archiveDigest(query, in: history, currentThread: threadHistoryID)
    }

    /// The query itself, as a pure function of (request, rows) — so it can be
    /// exercised against fixtures and against a real `history.json` without
    /// standing up a `NotchModel` (see `scripts/history_eval`). `nonisolated`
    /// because nothing here touches this object's state: the two rows the instance
    /// method withholds are passed in, not read.
    nonisolated static func archiveDigest(_ query: HistoryQuery,
                                          in items: [HistoryItem],
                                          currentThread: UUID?) -> HistoryDigest {
        let cal = Calendar.current
        // `until` names a whole day, so the bound is the START of the following day
        // and the comparison is strictly-less — otherwise "until today" would drop
        // everything after 00:00 today, i.e. all of today.
        let lowerBound = query.since.map { cal.startOfDay(for: $0) }
        let upperBound = query.until
            .flatMap { cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: $0)) }

        let matches = items.lazy.filter { item in
            guard !item.pending else { return false }
            guard item.id != currentThread else { return false }
            if let kind = query.kind, item.source.rawValue != kind { return false }
            if let lower = lowerBound, item.t < lower { return false }
            if let upper = upperBound, item.t >= upper { return false }
            guard let needle = query.text, !needle.isEmpty else { return true }
            return item.matchesArchiveSearch(needle)
        }

        // `history` is maintained newest-first (every write inserts at 0), but sort
        // explicitly rather than lean on that — the digest states "newest first" to
        // the model, and a row that ever lands out of order would make it misread
        // the chronology it's summarizing.
        let ordered = matches.sorted { $0.t > $1.t }
        // The full match count rides along, not just the capped slice: it's what
        // lets the digest admit it was truncated (see `HistoryDigest`).
        return HistoryDigest(rows: ordered.prefix(query.limit).map(\.digestRow),
                             totalMatches: ordered.count)
    }
    // MARK: - History

    /// Reopen a conversation by its history id — the path a tapped answer
    /// notification takes. Finds the matching (settled) Recent row and routes it
    /// through `openHistory`, so the panel lands straight on that thread's detail
    /// view. No-op if the row is gone or still pending. The caller (AppDelegate)
    /// must already have summoned the panel open on a screen.
    func openThread(id: UUID) {
        guard LicenseService.shared.state.allowsProductServices else { return }
        guard let item = history.first(where: { $0.id == id }), !item.pending else { return }
        openHistory(item)
    }

    func openHistory(_ item: HistoryItem) {
        guard LicenseService.shared.state.allowsProductServices else { return }
        // Opening a saved thread replaces the idle draft; its unsent attachments
        // must not hide off-screen and ride the next follow-up by surprise.
        askComposeImages = []
        // Still answering: this row is a placeholder whose live stream runs
        // detached — reattach the stream to the screen (the same move as
        // hovering the busy notch) so tapping the row lands on the answer as
        // it writes; the `inFlightRounds` mirror carries everything streamed so
        // far. A pending row with no live round behind it (the round is settling
        // this very instant) stays a no-op; it becomes a normal row momentarily.
        if item.pending {
            guard let round = inFlightRounds.first(where: { $0.threadID == item.id }) else { return }
            showHistory = false
            highlightedHistoryIndex = nil
            attachInFlightRound(round)
            return
        }

        // A Note/Reminder capture has no AI answer to reopen — it lives in Apple
        // Notes/Reminders. Tapping the ROW body must NOT switch the user out to
        // another app: they opened the notch expecting to stay here, and a silent
        // jump to Notes/Reminders yanks them somewhere they didn't ask to go. The
        // jump lives on a dedicated trailing button instead (`openCaptureInApp`),
        // so leaving the app is always a deliberate, separate tap. Here the row
        // body is a no-op for captures — the list stays open, nothing switches.
        guard item.source.isThread else { return }

        showHistory = false
        highlightedHistoryIndex = nil

        text = ""
        // Restore the whole thread, and adopt this item's id so a follow-up on the
        // reopened conversation updates the same recent row rather than forking a
        // new one. (Legacy single-Q/A items rebuild a two-turn thread.)
        turns = item.conversation
        threadHistoryID = item.id
        // A reopened thread that rode an image puts it back on the wire, so a
        // follow-up ("so how do I fix it?") still sees the screenshot the thread
        // started from instead of asking about nothing. The saved JPEG is already
        // the downsampled one that went out the first time. Only when the model on
        // duty now reads images at all — a text-only model gets the thread's text.
        threadImages = activeModelSupportsVision ? Self.parkedImages(for: item) : nil
        mode = .result
    }

    /// Images a saved thread carries, rebuilt from the history image store.
    private static func parkedImages(for item: HistoryItem)
        -> (threadID: UUID, images: [ChatImage])?
    {
        let files = item.conversation.first(where: { $0.role == "user" })?.imageFiles ?? []
        let images = files.compactMap { file -> ChatImage? in
            guard let jpeg = try? Data(contentsOf: historyImageURL(file)) else { return nil }
            return ChatImage(base64: jpeg.base64EncodedString(), mediaType: "image/jpeg")
        }
        guard !images.isEmpty else { return nil }
        return (threadID: item.id, images: images)
    }

    /// Jump a Note/Reminder capture out to its app — the DELIBERATE exit, fired
    /// only by the row's trailing "open in app" button, never by tapping the row
    /// body (which stays put; see `openHistory`). Switching apps is a decision the
    /// user makes on purpose, so it has its own control. No-op for `.ask` rows.
    func openCaptureInApp(_ item: HistoryItem) {
        guard !item.source.isThread else { return }
        openCapture(item)
        // Attention is moving to Notes/Reminders — hard-close the panel behind it
        // so the notch doesn't hang unfurled over the app the user just jumped to.
        fullClose()
    }

    /// Jump from a Recent row straight to the note/reminder it created.
    ///
    /// Two tiers, so a jump never dead-ends:
    ///   1. With a stored `link`, open that exact item — Notes via AppleScript
    ///      `show` (the `link` is the note's `x-coredata://` id), Reminders via
    ///      the `x-apple-reminderkit://` URL. A stale link (item deleted in the
    ///      app, or the undocumented Reminders scheme stops resolving) fails
    ///      quietly *inside* the app and lands the user on its current view.
    ///   2. Without a link — captures saved before this feature shipped, or a
    ///      save that returned no identifier — just bring the destination app
    ///      forward by its bundle id, so an old row still goes *somewhere* useful
    ///      rather than doing nothing.
    private func openCapture(_ item: HistoryItem) {
        switch item.source {
        case .note:
            if let id = item.link, !id.isEmpty {
                if id.hasPrefix("x-coredata://") {
                    // Apple Notes capture. `show` can fail on a stale id (note
                    // deleted, or a Core Data id synced from another device) or
                    // revoked Automation access — when it does, don't dead-end:
                    // fall back to Notes' main window so the tap still lands the
                    // user *somewhere*.
                    NotesService.showNote(id: id) { [weak self] ok in
                        if !ok { self?.openApp(bundleID: "com.apple.Notes") }
                    }
                } else {
                    // Markdown capture: the link is the day file's absolute path.
                    // Open it in the default editor; if the file has been moved or
                    // deleted, reveal the folder instead so the jump still lands.
                    if FileManager.default.fileExists(atPath: id) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: id))
                    } else {
                        FileNotesService.revealFolder()
                    }
                }
            } else {
                // Link-less legacy row: no way to know which destination filed it,
                // so land on wherever notes go *now* — the least surprising target.
                switch NoteDestination.current {
                case .appleNotes:     openApp(bundleID: "com.apple.Notes")
                case .markdownFolder: FileNotesService.revealFolder()
                }
            }
        case .reminder:
            if let link = item.link, let url = URL(string: link) {
                NSWorkspace.shared.open(url)
            } else {
                openApp(bundleID: "com.apple.reminders")
            }
        case .ask, .agent:
            break   // threads — handled by openHistory; never reached here
        }
    }

    /// Bring an app forward by bundle id — the no-deep-link fallback. Uses the
    /// modern `openApplication(at:configuration:)` since `launchApplication` is
    /// deprecated; resolving the URL first keeps it a no-op if the app is missing.
    private func openApp(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
    // MARK: - Shell-style history recall (↑/↓ fill the input)

    /// ↑ on the idle prompt: pull the previous question straight into the input,
    /// the way a shell's up-arrow recalls the last command. The first press (from
    /// an empty box) fills the most recent question; each further ↑ steps one item
    /// older, clamping at the oldest. Returns `true` when it filled the box, so the
    /// field swallows the key; `false` (no history, or already at the oldest) lets
    /// ↑ do its usual thing.
    @discardableResult
    func recallPreviousQuestion() -> Bool {
        let questions = recallQuestions
        guard !questions.isEmpty else { return false }
        // Clamp the resume point in case `history` shrank since the last step, then
        // advance one older. `guard` catches "already at the oldest" (no-op).
        let current = min(historyRecallIndex ?? -1, questions.count - 1)
        let next = current + 1
        guard next < questions.count else { return false }   // already at the oldest
        fillRecall(at: next, in: questions)
        pulseRecall(.older)
        return true
    }

    /// ↓ while recalling: step back toward the newest question. Stepping past the
    /// newest clears the box (back to where the user started), ending the session.
    /// Returns `true` while a recall session is live so ↓ stays owned by recall;
    /// `false` when there's nothing being recalled, so ↓ falls through to its
    /// normal duty (opening / stepping the recent list).
    @discardableResult
    func recallNextQuestion() -> Bool {
        guard let current = historyRecallIndex else { return false }
        if current <= 0 {
            // Past the newest — clear back to an empty box and end recall.
            historyRecallIndex = nil
            setRecallText("")
        } else {
            let questions = recallQuestions
            guard !questions.isEmpty else {
                // History emptied out from under us mid-recall — end the session.
                historyRecallIndex = nil
                setRecallText("")
                pulseRecall(.newer)
                return true
            }
            // Clamp defensively: `history` can shrink mid-recall (a row deleted),
            // so the cursor might now point past the end.
            fillRecall(at: min(current - 1, questions.count - 1), in: questions)
        }
        pulseRecall(.newer)
        return true
    }

    /// Move the recall cursor to `index` in the dedup'd `questions` and drop that
    /// question into the box.
    private func fillRecall(at index: Int, in questions: [String]) {
        historyRecallIndex = index
        setRecallText(questions[index])
    }

    /// Write `text` as part of a recall step — flagged so `text.didSet` doesn't
    /// read the fill as the user typing and cancel the session.
    private func setRecallText(_ value: String) {
        isRecallingText = true
        text = value
        isRecallingText = false
    }
    // MARK: - History keyboard navigation

    /// ↓ in the empty idle prompt: open the recent list (if any) and highlight
    /// the next row. The first press both reveals the list and lands on row 0;
    /// each subsequent press steps down, clamping at the last row. Returns
    /// `false` when there's nothing to navigate (no history), so the caller can
    /// let the keystroke fall through to its default behaviour.
    @discardableResult
    func historyNavigateDown() -> Bool {
        let items = recentVisible
        guard !items.isEmpty else { return false }
        if !showHistory { showHistory = true }
        let next = (highlightedHistoryIndex ?? -1) + 1
        highlightedHistoryIndex = min(next, items.count - 1)
        return true
    }

    /// ↑ while navigating the recent list: step the highlight up. Moving up past
    /// the first row collapses the list and returns the caret to the input — the
    /// inverse of the ↓ that opened it. Returns `false` when the list isn't open
    /// / nothing is highlighted, so ↑ behaves normally in the field otherwise.
    @discardableResult
    func historyNavigateUp() -> Bool {
        guard showHistory, let current = highlightedHistoryIndex else { return false }
        if current <= 0 {
            // Past the top — fold the list back up and release the highlight.
            highlightedHistoryIndex = nil
            showHistory = false
        } else {
            highlightedHistoryIndex = current - 1
        }
        return true
    }

    /// Enter while a recent row is highlighted: open it. Returns `false` when
    /// nothing is highlighted, so a normal Enter still submits the prompt. Also
    /// bails whenever the box has text — visible text always owns Enter, so a
    /// stale highlight can never swallow a real submit (backstop to
    /// `text.didSet`, which already closes the list the moment text arrives).
    @discardableResult
    func historyConfirmHighlighted() -> Bool {
        guard !hasText, showHistory, let i = highlightedHistoryIndex else { return false }
        let items = recentVisible
        guard items.indices.contains(i) else { return false }
        let item = items[i]
        // Enter is a deliberate confirm, not an accidental body tap — so on a
        // highlighted capture it fires the jump (the keyboard twin of clicking the
        // trailing button), while a mouse click on the row body stays put. Ask
        // rows reopen the thread as before.
        if item.source.isThread {
            openHistory(item)
        } else {
            openCaptureInApp(item)
        }
        return true
    }

    /// Esc / outside-collapse for the list alone: fold it back to the input
    /// without closing the whole panel. Returns `false` when the list isn't
    /// open, letting Esc fall through to its usual full-close.
    @discardableResult
    func collapseHistory() -> Bool {
        guard showHistory else { return false }
        showHistory = false
        highlightedHistoryIndex = nil
        return true
    }

    /// How much of the archive a Clear wipes. The confirmation only offers the
    /// choice when the narrow scope is actually narrower — see
    /// `historyCountWithinLastDay`.
    enum HistoryClearScope: Equatable {
        /// Chat / Notes / Reminders filed in the last 24 hours; older rows and
        /// every Agent conversation stay.
        case lastDay
        /// Every Chat / Notes / Reminders row, leaving Agent untouched.
        case chat
        /// Every Agent conversation, leaving Ask / Notes / Reminders untouched.
        case agent
    }

    /// The window `.lastDay` wipes.
    static let historyLastDayWindow: TimeInterval = 24 * 60 * 60

    /// Rows filed within `historyLastDayWindow` — the size of the narrow scope,
    /// and what tells the confirmation whether there's a choice worth offering.
    var historyCountWithinLastDay: Int {
        let cutoff = Date().addingTimeInterval(-Self.historyLastDayWindow)
        return history.lazy.filter {
            $0.t >= cutoff
                && (self.agentComposeActive ? $0.source == .agent : $0.source != .agent)
        }.count
    }

    /// Total represented by the active Clear confirmation. Agent's confirmation
    /// counts only the rows it can remove; Chat counts Ask / Notes / Reminders.
    var historyClearTotalCount: Int { recentScopeHistoryCount }

    func clearHistory(scope: HistoryClearScope = .chat) {
        // Everything filed at/after this instant goes. A full clear reaches all the
        // way back, which is just `.distantPast` — so both scopes are one cutoff and
        // one code path.
        let cutoff: Date = switch scope {
        case .chat, .agent: .distantPast
        case .lastDay: Date().addingTimeInterval(-Self.historyLastDayWindow)
        }
        // Clearing before the launch load lands must also reach the rows the read
        // hasn't handed over yet, or the wiped window pops back once it finishes.
        if scope == .agent {
            armAgentClearBeforeLoad()
        } else {
            armChatClearBeforeLoad(cutoff)
        }

        let doomed = history.filter {
            $0.t >= cutoff && (scope == .agent ? $0.source == .agent : $0.source != .agent)
        }
        guard !doomed.isEmpty || !historyLoaded || scope == .chat || scope == .agent else { return }
        // The rows go, so their attachments go with them. (A clear that lands before
        // the load only sees what's in memory; the rest of the store is swept by the
        // prune in `mergeLoadedHistory`, which then finds nothing referencing it.)
        Self.deleteHistoryImages(doomed.flatMap(\.imageFiles))
        history.removeAll {
            $0.t >= cutoff && (scope == .agent ? $0.source == .agent : $0.source != .agent)
        }
        saveHistory()

        // The keyboard highlight indexes into the *visible* slice, and a partial
        // clear pulls rows out from the TOP of it — so a stale index would leave
        // the selection sitting on a completely different row (it looked like the
        // highlight teleported down the list as the rows above it vanished), or
        // past the end entirely. Nothing survives a Clear as "the selected row",
        // so release it — and fold the list once it's empty, like `deleteHistory`.
        highlightedHistoryIndex = nil
        if recentVisible.isEmpty { showHistory = false }
    }

    /// The Agent workspace trash control only removes successfully completed
    /// work. In-progress, failed, and cancelled runs remain available so that
    /// clearing a roster can never discard a live task or error report.
    func clearCompletedAgentHistory() {
        let doomed = history.filter {
            $0.source == .agent && $0.agentOutcome == "success"
        }
        guard !doomed.isEmpty else { return }
        Self.deleteHistoryImages(doomed.flatMap(\.imageFiles))
        history.removeAll { $0.source == .agent && $0.agentOutcome == "success" }
        saveHistory()
        highlightedHistoryIndex = nil
        if recentVisible.isEmpty { showHistory = false }
    }

    /// Drop a single recent item by id (right-click → Delete on its row). Keeps the
    /// keyboard highlight valid: removing a row at/above the highlighted index would
    /// otherwise leave the caret pointing past the end or at the wrong row, so we
    /// recompute it against the shortened visible slice — clamping to the last row,
    /// or releasing the highlight (and folding the list) once it's empty.
    func deleteHistory(id: UUID) {
        guard let removedVisibleIndex = recentVisible.firstIndex(where: { $0.id == id }) else { return }
        Self.deleteHistoryImages(history.first(where: { $0.id == id })?.imageFiles ?? [])
        history.removeAll { $0.id == id }
        saveHistory()

        guard let current = highlightedHistoryIndex else { return }
        let remaining = recentVisible.count
        if remaining == 0 {
            highlightedHistoryIndex = nil
            showHistory = false
        } else if removedVisibleIndex <= current {
            highlightedHistoryIndex = min(current, remaining - 1)
        }
    }
    // MARK: - History persistence
    //
    // The archive is unbounded (every retained item, full transcripts included),
    // so both halves of its persistence are kept off the main actor:
    //   • it lives in its own file under Application Support, not in UserDefaults
    //     — a multi-MB blob in the defaults plist rides along on every cfprefsd
    //     round-trip for the whole domain, and `set(_:forKey:)` of the full
    //     archive ran synchronously on the main thread after EVERY answer;
    //   • loads decode on a background task at launch (the archive merges in a
    //     beat later), and saves encode+write on a serial utility queue behind a
    //     short debounce (a finished answer saves once immediately and again when
    //     its generated title lands — the debounce folds those into one write).

    /// Serial queue that owns every write of the archive file, so two debounced
    /// snapshots can never interleave their bytes.
    private static let historyIO = DispatchQueue(label: "com.lofilab.notch.history-io",
                                                 qos: .utility)

    nonisolated private static var historyFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        return base.appendingPathComponent("Notch", isDirectory: true)
            .appendingPathComponent("history.json")
    }
    // MARK: - History images
    //
    // An attached image is kept as its own JPEG beside the archive, and the turn
    // that carried it references it by filename (`Turn.imageFiles`). The bytes are
    // the ones already downsampled for the wire (`encodeJPEGForVision` — long side
    // ≤1568px), so a saved thumbnail costs a couple hundred KB, not the multi-MB
    // Retina original. Files are removed with the rows that reference them
    // (`deleteHistory` / `clearHistory`), and anything orphaned by a crash is swept
    // at the next launch (`pruneHistoryImages`).

    nonisolated static var historyImagesDirectory: URL {
        historyFileURL.deletingLastPathComponent()
            .appendingPathComponent("HistoryImages", isDirectory: true)
    }

    nonisolated static func historyImageURL(_ name: String) -> URL {
        historyImagesDirectory.appendingPathComponent(name)
    }

    /// Park one already-encoded JPEG in the store. Returns the filename to stamp on
    /// the turn, or `nil` if the write failed — in which case the turn simply keeps
    /// no attachment, exactly as it did before this existed.
    nonisolated static func storeHistoryImage(_ jpeg: Data) -> String? {
        let dir = historyImagesDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = UUID().uuidString + ".jpg"
        guard (try? jpeg.write(to: dir.appendingPathComponent(name), options: .atomic)) != nil
        else { return nil }
        return name
    }

    /// The image behind a saved filename, or `nil` if the file is gone (a wiped store,
    /// a hand-deleted file). Views render nothing in that case rather than a broken box.
    /// Decoded once per file per launch (see `historyImageCache`): the Recent list and
    /// the archive rebuild on every keystroke in their search field, and re-decoding a
    /// JPEG on each pass would show as jank.
    nonisolated static func historyImage(named name: String) -> NSImage? {
        if let cached = historyImageCache.object(forKey: name as NSString) { return cached }
        guard let image = NSImage(contentsOf: historyImageURL(name)), image.isValid else { return nil }
        historyImageCache.setObject(image, forKey: name as NSString)
        return image
    }

    nonisolated static func deleteHistoryImages(_ names: [String]) {
        guard !names.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            for name in names {
                historyImageCache.removeObject(forKey: name as NSString)
                try? FileManager.default.removeItem(at: historyImageURL(name))
            }
        }
    }

    /// Sweep images no saved row references any more — the residue of a crash between
    /// writing the file and persisting the row that names it. A file young enough to
    /// belong to a round still in flight (its row lands in the archive only once the
    /// answer does) is left alone, so this can never delete an attachment out from
    /// under a live conversation.
    nonisolated private static func pruneHistoryImages(keeping referenced: Set<String>) {
        let dir = historyImagesDirectory
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return }
        let cutoff = Date().addingTimeInterval(-3600)
        for name in names where !referenced.contains(name) {
            let url = dir.appendingPathComponent(name)
            let written = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let written, written > cutoff { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Records a pre-load Chat clear's reach. Two clears keep the earlier cutoff —
    /// it removes more, while still never crossing into Agent.
    private func armChatClearBeforeLoad(_ cutoff: Date) {
        guard !historyLoaded else { return }
        chatHistoryClearedBeforeLoad = min(
            chatHistoryClearedBeforeLoad ?? .distantFuture, cutoff)
    }

    private func armAgentClearBeforeLoad() {
        guard !historyLoaded else { return }
        agentHistoryClearedBeforeLoad = true
    }
    func loadHistoryAsync() {
        Task.detached(priority: .userInitiated) { [weak self] in
            let loaded = Self.readHistoryFromDisk()
            await MainActor.run { [weak self] in
                self?.mergeLoadedHistory(loaded)
            }
        }
    }

    private func mergeLoadedHistory(_ loaded: [HistoryItem]) {
        defer {
            historyLoaded = true
            if historySaveDeferred {
                historySaveDeferred = false
                saveHistory()
            }
            // The archive is now whole, so anything in the image store it doesn't
            // reference is residue (a crash between writing the JPEG and persisting
            // the row, a Clear that landed before the load) — sweep it.
            let referenced = Set(history.flatMap(\.imageFiles))
            DispatchQueue.global(qos: .utility).async {
                Self.pruneHistoryImages(keeping: referenced)
            }
        }
        guard !loaded.isEmpty else { return }
        // A clear that landed before this read finished also owns the matching
        // bucket's rows it never got to see. Apply both scopes independently so
        // neither clear can erase the sibling bucket.
        var surviving = chatHistoryClearedBeforeLoad.map { cutoff in
            loaded.filter { $0.source == .agent || $0.t < cutoff }
        } ?? loaded
        if agentHistoryClearedBeforeLoad {
            surviving.removeAll { $0.source == .agent }
        }
        guard !surviving.isEmpty else { return }
        // Anything already in `history` arrived after launch — newer than
        // everything on disk — so it stays in front (the list is newest-first).
        //
        // De-duped BY ID, in-memory wins. A run can settle before this merge lands
        // (an agent run resumed at launch files its record right away), and
        // `recordAgentHistory`'s "replace the row for this task id" only sees the
        // in-memory half — the disk copy of that same id hasn't arrived yet. A raw
        // concat then leaves two rows carrying the SAME id, which the Recent list's
        // `ForEach(id: \.element.id)` renders as undefined results: one of the two
        // draws as a blank row. Keeping the first occurrence of each id also heals
        // an archive that already picked up such a pair on an earlier launch.
        history = Self.dedupedByID(history + surviving)
    }

    /// Newest-first list with each `id` kept once, at its earliest (newest) position.
    /// `history` must never hold two items sharing an id: rows are keyed by it in
    /// every list, and `deleteHistory`/`openHistory` look items up by it.
    private static func dedupedByID(_ items: [HistoryItem]) -> [HistoryItem] {
        var seen = Set<UUID>()
        return items.filter { seen.insert($0.id).inserted }
    }

    nonisolated private static func readHistoryFromDisk() -> [HistoryItem] {
        if let data = try? Data(contentsOf: historyFileURL) {
            return decodeHistory(data)
        }
        // No archive file yet: migrate the legacy UserDefaults blob (where the
        // archive lived through 0.1.13) into the file, and only then drop the
        // defaults copy so the plist shrinks back to settings-sized. If the file
        // write fails the blob stays put and the next launch retries.
        guard let data = UserDefaults.standard.data(forKey: historyKey) else { return [] }
        let items = decodeHistory(data)
        if writeHistoryToDisk(items) {
            UserDefaults.standard.removeObject(forKey: historyKey)
        }
        return items
    }

    nonisolated private static func decodeHistory(_ data: Data) -> [HistoryItem] {
        let decoder = JSONDecoder()
        // Decode item-by-item rather than `decode([HistoryItem].self …)`. The array
        // decode is all-or-nothing — one element that throws (a corrupt blob, or a
        // field that becomes required in a future build) drops the WHOLE list and
        // every Recent row vanishes. `LossyArray` decodes each element in isolation
        // and skips the failures, so one bad item costs only itself.
        if let lossy = try? decoder.decode(LossyArray<HistoryItem>.self, from: data) {
            return lossy.elements
        }
        // Fall back to the strict decode only if even the lossy pass can't open the
        // top-level array (e.g. the blob isn't a JSON array at all).
        return (try? decoder.decode([HistoryItem].self, from: data)) ?? []
    }

    @discardableResult
    nonisolated private static func writeHistoryToDisk(_ items: [HistoryItem]) -> Bool {
        guard let data = try? JSONEncoder().encode(items) else { return false }
        let url = historyFileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        // Atomic, so a crash mid-write can never leave a truncated archive.
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    func saveHistory() {
        guard historyLoaded else { historySaveDeferred = true; return }
        pendingHistorySave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingHistorySave = nil
                // Value-type snapshot on the main actor; the encode + write of the
                // full archive happens on the utility queue.
                let snapshot = self.history
                Self.historyIO.async { Self.writeHistoryToDisk(snapshot) }
            }
        }
        pendingHistorySave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Immediate, non-debounced archive write for rows that must not sit in the
    /// debounce window. `then` runs after the write lands (on the IO queue) —
    /// the agent path uses it to clear its crash-recovery marker only once the
    /// row is safely on disk. Pre-load (launch recovery, whose marker is
    /// already consumed) it falls back to the deferred-save path and runs the
    /// completion immediately.
    func saveHistoryNow(then completion: @escaping @Sendable () -> Void) {
        guard historyLoaded else {
            historySaveDeferred = true
            completion()
            return
        }
        pendingHistorySave?.cancel()
        pendingHistorySave = nil
        let snapshot = history
        Self.historyIO.async {
            Self.writeHistoryToDisk(snapshot)
            completion()
        }
    }

    /// Quit-time flush: run the debounced save NOW (synchronously through the IO
    /// queue) so the newest rows survive a ⌘Q inside the debounce window.
    func flushHistorySave() {
        guard pendingHistorySave != nil else { return }
        pendingHistorySave?.cancel()
        pendingHistorySave = nil
        guard historyLoaded else { return }
        let snapshot = history
        Self.historyIO.sync { Self.writeHistoryToDisk(snapshot) }
    }
}
