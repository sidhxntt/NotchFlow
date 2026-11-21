import SwiftUI
import Combine
import AppKit   // NSWorkspace — opening Notes/Reminders for a Recent capture
import Carbon.HIToolbox
import UniformTypeIdentifiers   // UTType — is a pasted file URL an image? (agent ⌘V)

@MainActor
extension NotchModel {
    // MARK: - Note submit

    /// Route a note-classified line into Apple Notes as a new note. The surface never
    /// changes — the user stays on the same "Type anything…" input and can keep
    /// jotting (or asking) right after; the only sign it went to Notes is the quiet
    /// "Added to Notes" line that flashes below the input.
    ///
    /// The write runs **off the main thread** (see `NotesService`) so the first-run
    /// TCC permission prompt doesn't deadlock the UI. We optimistically clear the
    /// field right away and show a quiet "Saving…" cue; the main-thread callback
    /// then either confirms "Saved" or — on failure (most often permission not yet
    /// granted, or the user clicking "Don't Allow") — **restores the exact line** so
    /// nothing typed is lost, and surfaces the recovery hint.
    func submitNote() {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }

        // A deictic note ("save this") points at the clipboard, not at
        // itself — fold the copied URL/snippet into the note body so what gets filed
        // is the *referent*, not a useless directive phrase. The raw `line` is still
        // what we persist to Recent and restore on failure; only the Notes payload
        // is the compound. Self-contained jots take the plain path unchanged.
        let clip = isDeicticNoteCapture(line) ? clipboardContextIfEligible() : nil
        let noteBody = clip.map { "\(line)\n\n\($0)" } ?? line
        let usedClip = clip != nil

        // Optimistic: free the field for the next jot immediately, show progress.
        // Collapse the recent list too — clearing the text would otherwise let a
        // still-true `showHistory` pop it right back open under the saved cue.
        text = ""
        showHistory = false
        highlightedHistoryIndex = nil
        noteError = nil
        noteCueTask?.cancel()
        lastSavedNote = nil
        noteSaving = true
        // Claim the in-flight slot for THIS write (XII-117), so a later capture
        // fired inside our AppleScript retry window can supersede us.
        captureToken += 1
        let token = captureToken

        // Same optimistic contract on both destinations; only the writer (and the
        // cue wording) differs. The Markdown path appends to today's file in the
        // user's folder — no TCC prompt, no AppleScript — and its `link` is the
        // day file's path instead of an `x-coredata://` id (see `openCapture`).
        if NoteDestination.current == .markdownFolder {
            FileNotesService.writeNote(noteBody) { [weak self] result in
                guard let self else { return }
                let current = self.captureToken == token
                if current { self.noteSaving = false }
                switch result {
                case .success(let path):
                    self.persistCapture(line, source: .note, link: path)
                    if current {
                        self.flashSavedCue(usedClip ? L("feedback.addedFileClip") : L("feedback.addedFile"))
                    }
                case .failure(let err):
                    if current {
                        self.reportCaptureFailure(line, message: err.errorDescription ?? L("feedback.fileFailed"))
                    }
                }
            }
            return
        }

        NotesService.writeNote(noteBody) { [weak self] result in
            guard let self else { return }
            // This write always persists its own Recent row (idempotent, its own
            // data) so a success is never dropped. But the shared UI state is only
            // ours to touch while we're still the current in-flight write — a newer
            // capture that superseded us owns the gate and cue now.
            let current = self.captureToken == token
            if current { self.noteSaving = false }
            switch result {
            case .success(let noteID):
                self.persistCapture(line, source: .note, link: noteID)
                if current {
                    self.flashSavedCue(usedClip ? L("feedback.addedNotesClip") : L("feedback.addedNotes"))
                }
            case .failure(let err):
                // Only bounce the line back into the input / raise the error when
                // we still own the shared state; a superseded failure must not
                // clobber the newer write's success or restore an already-filed line.
                if current {
                    self.reportCaptureFailure(line, message: err.errorDescription ?? L("feedback.notesFailed"))
                }
            }
        }
    }
    // MARK: - Reminder submit

    /// Route a time-bound line into Apple Reminders, due (and ringing) at the
    /// moment the text names. Same optimistic shape as `submitNote`: clear the
    /// field immediately, show "Saving…", and on failure (usually the Reminders
    /// permission not yet granted) restore the exact line so nothing is lost.
    ///
    /// The due date is captured **before** clearing the field — `text.didSet`
    /// recomputes `detectedDue` to nil on the clear, so reading it after would
    /// file a dateless reminder.
    func submitReminder() {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        // `detectedDue` is computed asynchronously (off-main Task). On the clipboard
        // path the submit can run in the same call stack that just kicked that Task
        // off, so it can still be nil here even though the line names a time (XII-97).
        // Fall back to a synchronous parse so a timed reminder never silently lands
        // with no due date. A line with no parseable time (incl. a pure "every day"
        // recurring reminder) legitimately stays nil — EventKit's repeat rule carries
        // it — so we don't force a date on those.
        var due = detectedDue
            ?? RemindersService.futureDate(in: line)
            ?? RemindersService.recurrenceDate(in: line)
        // Guard against a due that resolves into the PAST (a stale async value, or a
        // DST/clock-skew edge in the synthesized recurrence date): EventKit accepts it
        // but the reminder would never fire. Drop it to nil rather than file a dead
        // reminder — better a reminder with no time than one that silently never rings.
        if let d = due, d <= Date() { due = nil }

        text = ""
        showHistory = false
        highlightedHistoryIndex = nil
        noteError = nil
        noteCueTask?.cancel()
        lastSavedNote = nil
        noteSaving = true
        // Claim the in-flight slot for THIS write (XII-117) — see submitNote.
        captureToken += 1
        let token = captureToken

        RemindersService.createReminder(line, due: due) { [weak self] result in
            guard let self else { return }
            // Shared UI state is only ours while we're still the current write;
            // the Recent row always persists (its own data). See submitNote.
            let current = self.captureToken == token
            if current { self.noteSaving = false }
            switch result {
            case .success(let link):
                self.persistCapture(line, source: .reminder, link: link)
                // Echo the recurrence kind write() applied, resolving a bare
                // "weekly" line's day from `due` exactly as write() does so the
                // displayed weekday matches what EventKit actually filed.
                let suffix: String
                switch RemindersService.recurrenceKind(in: line) {
                case .daily:
                    suffix = L("recur.daily")
                case .weekly(let ekDay):
                    let dayIdx: Int
                    if let ekDay {
                        dayIdx = ekDay.rawValue - 1   // EKWeekday 1-Sun…7-Sat \u{2192} 0-based
                    } else if let due {
                        dayIdx = Calendar.current.component(.weekday, from: due) - 1
                    } else {
                        dayIdx = -1
                    }
                    if dayIdx >= 0 {
                        let abbr = Calendar.current.shortWeekdaySymbols[dayIdx % 7]
                        suffix = L("recur.weeklyOn", abbr)
                    } else {
                        suffix = L("recur.weekly")
                    }
                case .monthly:
                    suffix = L("recur.monthly")
                case nil:
                    suffix = ""
                }
                if current { self.flashSavedCue(L("feedback.addedReminders", suffix)) }
            case .failure(let err):
                // Only bounce the line back / raise the error when we still own the
                // shared state — a superseded failure must not clobber the newer
                // write's success or restore an already-filed line (XII-117).
                if current {
                    self.reportCaptureFailure(line, message: err.errorDescription ?? L("feedback.remindersFailed"))
                }
            }
        }
    }

    /// Surface a Note/Reminder save failure without ever silently dropping the
    /// user's words. If the input is still empty we put the exact line back so a
    /// retry is one keypress away. But if they've already started the next jot,
    /// clobbering that draft would be its own data loss — so instead we fold the
    /// failed line into the inline error, where it stays visible and copyable
    /// rather than vanishing with no trace.
    private func reportCaptureFailure(_ line: String, message: String) {
        if text.isEmpty {
            text = line
            noteError = message
        } else {
            noteError = L("feedback.savePreservedLine", message, line)
        }
    }

    /// File a successful Note/Reminder capture into the same Recent history the AI
    /// Q&A uses, so a jotted line leaves a visible trace instead of vanishing with
    /// the 1.7s toast. Stored with its `source` (→ Notes / → Reminders tag), the
    /// `link` back to the exact note/reminder the row's trailing button jumps to,
    /// and an explicit empty `turns`, so reopening it can never synthesize a ghost
    /// answer bubble — a capture has no thread to reopen.
    func persistCapture(_ line: String, source: HistoryItem.Source, link: String?) {
        var item = HistoryItem(q: line, a: "", t: Date(), turns: [])
        item.source = source
        item.link = link
        history.insert(item, at: 0)
        // No cap: the full archive is retained (the notch list shows only the
        // newest `notchRecentCap`; the History window shows everything).
        saveHistory()
    }

    /// Briefly show "Saved to Notes" under the record input, then fade it. A new
    /// save resets the timer so back-to-back jots don't flicker.
    private func flashSavedCue(_ line: String) {
        noteCueTask?.cancel()
        lastSavedNote = line
        noteCueTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_700_000_000)
            guard !Task.isCancelled else { return }
            // Clear the cue on the SAME spring the record view and the island both
            // use for this state (response 0.42, damping 0.82). Driving it explicitly
            // — rather than leaning on the implicit `.animation(value:)` modifiers —
            // puts the inner line's fade and the outer island's height collapse on
            // one shared transaction, so they can't be scheduled apart and the panel
            // draws up as a single smooth motion instead of a two-step settle.
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                self?.lastSavedNote = nil
            }
        }
    }

    /// Whether the round identified by its answer placeholder is still the one on
    /// screen. Once `newChat`/`fullClose` (or opening another thread) detaches it,
    /// the screen is no longer the task's to touch — only its snapshot (and, at
    /// the end, history) hears about the stream.
    func isOnScreen(answerID: UUID) -> Bool {
        turns.contains { $0.id == answerID }
    }

    /// Whether the answer is visibly mounted anywhere. Completion notifications
    /// are only for a round the user actually left; a Force Touch window watching
    /// its detached mirror is still a live presentation, even though it is not in
    /// the main panel's `turns` array.
    func isPresented(answerID: UUID) -> Bool {
        isOnScreen(answerID: answerID)
            || detachedThreadStores.values.contains { store in
                store.turns.contains { $0.id == answerID }
            }
    }

    /// Refresh a still-streaming round's reattach mirror with its task's current
    /// snapshot. No-op once the round has settled (its defer removed the entry).
    func syncInFlight(_ answerID: UUID, _ incoming: [Turn]) {
        guard let i = inFlightRounds.firstIndex(where: { $0.answerID == answerID }) else { return }
        var thread = incoming
        // Streaming callbacks own their value-type transcript, while presentation
        // changes (word rotation and ask-user cards) update the in-flight mirror.
        // Merge those runtime-only fields back before a text chunk publishes so a
        // later chunk cannot overwrite the shared state with its older snapshot.
        if let prior = inFlightRounds[i].thread.first(where: { $0.id == answerID }),
           let j = thread.firstIndex(where: { $0.id == answerID }) {
            if thread[j].thinkingWord == nil { thread[j].thinkingWord = prior.thinkingWord }
            if thread[j].thinkingOrbState == nil {
                thread[j].thinkingOrbState = prior.thinkingOrbState
            }
            if thread[j].thinkingStartedAt == nil {
                thread[j].thinkingStartedAt = prior.thinkingStartedAt
            }
            if thread[j].pendingQuestion == nil {
                thread[j].pendingQuestion = prior.pendingQuestion
            }
        }
        inFlightRounds[i].thread = thread
        // A detached window following this thread hears every snapshot too.
        detachedThreadStores[inFlightRounds[i].threadID]?.turns = thread
    }

    /// Put a still-streaming round back on screen: restore its live snapshot to
    /// `turns`, adopt its thread id (so follow-ups keep updating the same Recent
    /// row), and pick `.load` vs `.result` by whether any answer text has landed
    /// yet (`.load` re-enters the thinking dots + rotating word, which a
    /// pre-token detached round still owns). From this instant
    /// `isOnScreen(answerID:)` is true again, so every subsequent chunk, source,
    /// and activity label flows straight to the panel — the same wiring as a
    /// round that never left the screen.
    func attachInFlightRound(_ round: InFlightRound) {
        text = ""
        turns = round.thread
        threadHistoryID = round.threadID
        let hasAnswer = round.thread.contains { $0.id == round.answerID && !$0.text.isEmpty }
        mode = hasAnswer ? .result : .load
    }

    /// Land a reopening panel back on the page parked at the last close. Page
    /// flags restore verbatim; the thread needs care, because a round that was
    /// still streaming when the panel folded has since finished (or died)
    /// detached — a live one never reaches here, `attachInFlightRound` wins
    /// first. So for a non-idle snapshot: prefer the thread persisted to
    /// history under the same id (it carries the completed answer), fall back
    /// to the snapshot's own turns if they contain readable answer text, and
    /// give up to the idle prompt when the round died wordless — never restore
    /// `.load`, nothing would ever feed those thinking dots again.
    func restoreParkedSession(_ parked: ParkedSession) {
        showWhatsNew = parked.showWhatsNew
        showHistory = parked.showHistory
        guard parked.mode != .idle else {
            text = parked.text
            return
        }
        let persisted = history.first(where: { $0.id == parked.threadHistoryID })?.turns
        var restored: [Turn]
        if let persisted, !persisted.isEmpty {
            restored = persisted
        } else if parked.turns.contains(where: { $0.role == "assistant" && !$0.text.isEmpty }) {
            restored = parked.turns
        } else {
            text = parked.text
            return
        }
        // A snapshot taken mid-stream may carry live-only flags; the stream is
        // over now, so a restored turn must not show a frozen caret or a stale
        // "searching…" line.
        for i in restored.indices {
            restored[i].streaming = false
            restored[i].toolActivity = nil
        }
        turns = restored
        threadHistoryID = parked.threadHistoryID
        text = parked.text
        // Restore the shortcut origin with the thread: `fullClose` cleared it, and
        // without handing it back the reopened answer would come up with a full
        // follow-up field where the user left a folded chip.
        fromPromptShortcut = parked.fromPromptShortcut
        // Hand the parked height measurement back BEFORE `open` flips and the
        // body mounts, so NotchBody's first frame already renders the correct
        // short-vs-clipped layout (see `lastMeasuredAnswerHeight`). A thread that
        // grew while closed (a detached round finishing) may exceed the parked
        // value — harmless: clipping is monotonic with height, so a parked
        // "clipped" stays clipped, and the rare short→long race just re-measures
        // one pass later, exactly like today.
        lastMeasuredAnswerHeight = parked.measuredAnswerHeight
        mode = .result
    }

    /// Replace the streaming assistant turn's text as chunks arrive. Looked up by
    /// id so an out-of-order or post-`newChat` chunk can't write into the wrong row.
    func updateAnswer(id: UUID, text: String) {
        guard let i = turns.firstIndex(where: { $0.id == id }) else { return }
        turns[i].text = text
    }

    /// Mark a turn as holding an error reason rather than model output, so
    /// `wireContext` filters it from every later request (XII-88).
    func markTurnError(id: UUID) {
        guard let i = turns.firstIndex(where: { $0.id == id }) else { return }
        turns[i].isError = true
    }

    /// End the thinking-dots phase for `id` — but only if `id` is the round that
    /// currently owns the flag, so a superseded round finishing can't switch the dots
    /// off under a newer one. Called on the first token and at every round terminus
    /// (success, cancel, error), so the dots clear exactly when this round stops
    /// thinking, whether or not its panel is still on screen.
    func endThinking(for id: UUID) {
        guard thinkingAnswerID == id else { return }
        thinking = false
        thinkingAnswerID = nil
    }

    /// Clear the `streaming` flag on the assistant turn (its caret/typing cue can
    /// stop) without otherwise touching it. Also clears any lingering tool-activity
    /// line so a finished turn never shows "searching…".
    func markFinished(id: UUID) {
        guard let i = turns.firstIndex(where: { $0.id == id }) else { return }
        turns[i].streaming = false
        setThinkingActivity(nil)
    }

    /// Funnel the harness's transient tool-activity label (e.g. "Searching the web…")
    /// into the single `thinkingStatus` value so it *replaces* the rotating mood word
    /// rather than rendering as a second, parallel line. `nil` falls back to the word.
    func updateActivity(id: UUID, label: String?, orb: OrbState) {
        guard isOnScreen(answerID: id) else { return }
        setThinkingActivity(label, orb: orb)
    }

    /// Append a search round's sources to the on-screen assistant turn (deduped by
    /// URL), so the source badge under the answer reflects every round.
    func appendSources(id: UUID, _ newSources: [WebSource]) {
        guard let i = turns.firstIndex(where: { $0.id == id }) else { return }
        turns[i].sources = Self.mergedSources(turns[i].sources, newSources)
    }

    /// Merge two source lists preserving order and dropping URL duplicates — the
    /// same dedup the snapshot and the on-screen turn both use so they agree.
    static func mergedSources(_ existing: [WebSource], _ incoming: [WebSource]) -> [WebSource] {
        var seen = Set(existing.map(\.url))
        var out = existing
        for s in incoming where !seen.contains(s.url) {
            seen.insert(s.url)
            out.append(s)
        }
        return out
    }

    /// Park a placeholder row for a brand-new thread the instant its question is
    /// submitted, so Recent shows the question (with a three-dot "answering…"
    /// marker) immediately instead of staying blank until the answer lands. Only
    /// the FIRST turn parks one — a follow-up streams into an already-present row.
    /// `persistThread` later replaces this same-id row in place with the finished
    /// item; `settlePending` removes it if the round produces nothing.
    func parkPending(threadID: UUID, question: String) {
        // Already have a row for this thread (shouldn't happen on a first turn, but
        // be safe): just flag it pending rather than inserting a duplicate.
        if let i = history.firstIndex(where: { $0.id == threadID }) {
            history[i].pending = true
            return
        }
        var item = HistoryItem(id: threadID, q: question, a: "", t: Date())
        item.pending = true
        history.insert(item, at: 0)
        // Not saved to disk — a pending row carries no answer and must never
        // survive a relaunch. `persistThread` is what writes the settled row.
    }

    /// Drop a still-pending placeholder for a thread that ended with nothing to
    /// keep (pre-text failure / cancellation). A row that already settled into a
    /// real answer is left untouched — only an unfinished placeholder is removed.
    func settlePending(_ threadID: UUID) {
        guard let i = history.firstIndex(where: { $0.id == threadID }), history[i].pending
        else { return }
        history.remove(at: i)
    }

    /// Called once a stream completes: persist the task's snapshot of the thread
    /// to history (one recent item per thread, updated in place as it grows).
    /// Runs whether or not the thread is still on screen — a round detached by
    /// `newChat`/`fullClose` lands here all the same, which is what makes backing
    /// out mid-answer safe. Built from the snapshot rather than the live `turns`,
    /// so whatever the screen shows by completion time can't cross into this
    /// thread's row. Skips empty results (e.g. a stream that errored before any
    /// text). The recent row shows the first question + latest answer; reopening
    /// it restores every turn.
    func persistThread(_ thread: [Turn], threadID: UUID, answer ans: String) {
        var thread = thread
        let trimmed = ans.trimmingCharacters(in: .whitespacesAndNewlines)
        // No answer came back — the model returned nothing (a leaked tool call the
        // harness couldn't recover, an empty completion) or the stream died before
        // the first token. This used to DELETE the row, which took the user's
        // question with it: the thread vanished from Recent and, once the app quit,
        // there was no trace it had ever been asked. Keep the row and mark it
        // failed instead. The body is whatever reason the answer turn already
        // holds (the XII-85 error text), else a plain "no answer" line.
        let failed = trimmed.isEmpty
        var body = trimmed
        if failed {
            let reason = thread.last(where: { $0.role == "assistant" })?.text
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            body = reason.isEmpty ? L("error.noAnswer") : reason
            // Settle the snapshot too, so reopening the row shows the same reason
            // rather than an empty bubble — and flag it `isError` so `wireContext`
            // keeps it out of the next round's wire copy (the model must never see
            // a failure line as something it once said).
            if let i = thread.lastIndex(where: { $0.role == "assistant" }) {
                if thread[i].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    thread[i].text = body
                }
                thread[i].isError = true
                thread[i].streaming = false
            }
        }
        // A detached window following this thread freezes on the final state —
        // caret gone, no stale activity line — whatever happens below. Settled
        // after the patch above so a failed round mirrors the reason, not a blank.
        detachedThreadStores[threadID]?.settle(with: thread)

        let firstQ = thread.first(where: { $0.role == "user" })?.text ?? ""
        // One history entry per conversation: if this thread already has a row
        // (a follow-up), update it in place instead of inserting a duplicate, so
        // a long chat is a single recent row, not one per turn. Carry over any
        // previously generated title so follow-ups don't wipe it.
        let existing = history.first(where: { $0.id == threadID })
        let existingTitle = existing?.title
        var item = HistoryItem(id: threadID, q: firstQ, a: body, t: Date(), turns: thread)
        item.title = existingTitle
        item.failed = failed
        // A chat follow-up on a reopened agent thread updates the SAME row — it
        // must keep the row's agent identity (source, folder link, outcome,
        // resume handle) rather than silently demoting it to a plain `.ask`.
        if let existing {
            item.source = existing.source
            item.origin = existing.origin
            item.link = existing.link
            item.agentOutcome = existing.agentOutcome
            item.agentResume = existing.agentResume
        }
        if let i = history.firstIndex(where: { $0.id == threadID }) {
            history.remove(at: i)
        }
        history.insert(item, at: 0)
        if item.source == .agent, let store = detachedThreadStores[threadID] {
            store.agentFolderPath = item.link
            store.completedAt = item.t
        }
        // No cap: the full archive is retained (see `persistCapture`).
        saveHistory()

        // Derive a title from the actual conversation content so the recent list
        // doesn't just display the first user message — prompts like "summarize this"
        // would make many rows look identical. Runs asynchronously so the UI is never
        // blocked; if it fails (offline, no key, timeout) the row falls back to
        // the first question.
        //
        // Regenerate as the thread drifts, but only at milestone rounds (every
        // other round, XII-88) — re-titling on EVERY follow-up fired one extra
        // full request per round, which doubles traffic on low-RPM free tiers
        // (Kimi/GLM/MiniMax) and can 429 the next real answer. A thread that
        // drifts to a new topic still gets re-titled within a round or two;
        // a missing title is always generated regardless of round parity.
        // A failed round has no answer to summarize, and spending a whole extra
        // request on the round that just failed is the wrong moment for it — the
        // row falls back to the question, which is exactly what it should show.
        let atMilestone = thread.count > 2 && thread.count % 4 == 0
        if !failed,
           existingTitle == nil || atMilestone,
           historyTitleTasks[threadID] == nil,
           LicenseService.shared.state.allowsAsyncProductEffect(isCancelled: false) {
            let titleTask = Task { [weak self] in
                guard let self else { return }
                defer { self.historyTitleTasks[threadID] = nil }
                guard LicenseService.shared.state
                    .allowsAsyncProductEffect(isCancelled: Task.isCancelled),
                      let title = await self.generateTitle(for: thread),
                      LicenseService.shared.state
                        .allowsAsyncProductEffect(isCancelled: Task.isCancelled),
                      let index = self.history.firstIndex(where: { $0.id == threadID })
                else { return }
                self.history[index].title = title
                self.saveHistory()
            }
            historyTitleTasks[threadID] = titleTask
        }
    }

    /// Fire the native "answer ready" banner for a round that finished detached
    /// (the user walked away — see the `walkedAway` gate at the call sites). Pulls
    /// whatever title `persistThread` already has for this thread (a follow-up
    /// carries one; a fresh thread's title is still generating, so it falls back to
    /// the question inside `NotificationService`). The tap reopens this thread.
    func notifyAnswerReady(threadID: UUID, question: String, answer: String) {
        // Nothing was actually saved (empty answer) → no row to reopen, no banner.
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let title = history.first(where: { $0.id == threadID })?.title
        NotificationService.shared.postAnswerReady(
            threadID: threadID, title: title, question: question)
    }

    /// Ask the configured model to summarize the conversation into a short title.
    /// Returns `nil` when offline (stub), unconfigured, or the request fails, so
    /// the UI can always fall back to the first user message.
    private func generateTitle(for thread: [Turn]) async -> String? {
        guard !(ai is StubAIService),
              LicenseService.shared.state
                .allowsAsyncProductEffect(isCancelled: Task.isCancelled)
        else { return nil }

        // Only the tail of the conversation, size-capped (XII-88): a title should
        // reflect where the chat *went*, so the last few rounds are the right
        // input anyway — and the cap keeps a long thread from ballooning this
        // side request. Skips turns that never became real answers (a superseded
        // round's empty turn, an error card's reason text).
        var transcript = ""
        for turn in thread.suffix(6) {
            let body = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty || turn.isError { continue }
            let label = turn.role == "user" ? "User" : "Assistant"
            transcript += "\(label): \(body)\n"
        }
        let prompt = String(transcript.suffix(4000))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return nil }

        let service = ai
        do {
            var title = ""
            for try await chunk in service.stream(
                system: titleSystemPrompt,
                messages: [ChatMessage(role: "user", content: prompt)]
            ) {
                guard LicenseService.shared.state
                    .allowsAsyncProductEffect(isCancelled: Task.isCancelled)
                else { return nil }
                title += chunk
            }
            guard LicenseService.shared.state
                .allowsAsyncProductEffect(isCancelled: Task.isCancelled)
            else { return nil }
            let cleaned = title
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "^[\"']+|[\"']+$", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\n", with: " ")
            guard !cleaned.isEmpty else { return nil }
            return cleaned
        } catch {
            return nil
        }
    }

    /// Debug-only: drop a finished Q/A onto the screen as a one-exchange thread,
    /// so the result view (and its markdown renderer) can be inspected at launch
    /// without a live backend. `sources` decorates the answer with citation chips
    /// and `usedClipboard` marks the question as clipboard-enriched, so those
    /// real states can be screenshotted too. Used by the `NOTCH_DEMO` env path
    /// in `AppDelegate`.
    func seedDemo(question: String, answer: String,
                  sources: [WebSource] = [], usedClipboard: Bool = false) {
        var user = Turn(role: "user", text: question)
        user.usedClipboard = usedClipboard
        var ai = Turn(role: "assistant", text: answer)
        ai.sources = sources
        turns = [user, ai]
        mode = .result
    }

    /// Debug-only: put a line into the idle input exactly as if typed, so the
    /// destination pill ("Ask" / "Note" / "Remind") shows the routing for
    /// screenshots. `route` pins the destination via the same override Tab uses,
    /// so the pill reads the intended verb regardless of the classifier's take.
    /// The set is delayed a beat so the prompt field is mounted when the text
    /// lands. Used by the `NOTCH_DEMO_INPUT` env path.
    func seedDemoInput(_ line: String, route: Panel? = nil) {
        mode = .idle
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.text = line
            if let route { self?.manualPanelOverride = route }
            // A programmatic set while the field has focus leaves the whole line
            // selected; park the caret at the end so the shot reads mid-typing.
            DispatchQueue.main.async {
                if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                    editor.setSelectedRange(NSRange(location: (line as NSString).length, length: 0))
                }
            }
        }
    }

    /// Debug-only: park a finished exchange where `adoptDetachedThread` will find
    /// it and hand back its thread id, so a pointer window can be posed on a real
    /// answer without a live backend. Used by the `NOTCH_DEMO_FORCE=answer` env
    /// path in `AppDelegate`.
    func seedDemoDetachedThread(question: String, answer: String) -> UUID {
        let id = UUID()
        var seeded = [Turn(role: "user", text: question)]
        // An empty answer is the "still thinking" pose — the card stands with the
        // question attached and nothing under it yet.
        if !answer.isEmpty { seeded.append(Turn(role: "assistant", text: answer)) }
        turns = seeded
        threadHistoryID = id
        mode = .result
        return id
    }

    /// Debug-only: show the "Added to Notes/Reminders" capture cue WITHOUT the
    /// 1.7s auto-clear, so the post-capture state holds still for screenshots.
    /// Used by the `NOTCH_DEMO_SAVED` env path.
    func seedDemoSaved(toReminders: Bool) {
        lastSavedNote = toReminders ? L("feedback.addedReminders", "") : L("feedback.addedNotes")
    }

    /// Debug-only: seed a long multi-turn thread so the result view's scrolling and
    /// edge fades can be inspected at launch without clicking. Used by the
    /// `NOTCH_DEMO_THREAD` env path in `AppDelegate`.
    func seedDemoThread() {
        turns = [
            Turn(role: "user", text: "Who is Acme's CEO?"),
            Turn(role: "assistant", text: "**Avery Chen** is Acme's founder and chief executive officer."),
            Turn(role: "user", text: "What about the CFO?"),
            Turn(role: "assistant", text: "**Morgan Lee** is Acme's chief financial officer."),
            Turn(role: "user", text: "Who else is on the leadership team?"),
            Turn(role: "assistant", text: "Acme's leadership team also includes:\n\n- **Jordan Patel** — President\n- **Riley Kim** — Chief Technology Officer\n- **Casey Rivera** — Chief Operating Officer"),
            Turn(role: "user", text: "Where is Avery from?"),
            Turn(role: "assistant", text: "Avery was born in Portland, Oregon, in 1985 and studied computer science."),
            Turn(role: "user", text: "Did Avery found any other companies?"),
            Turn(role: "assistant", text: "Before Acme, Avery led product teams at several software companies and invested in early-stage startups."),
        ]
        mode = .result
    }
}
