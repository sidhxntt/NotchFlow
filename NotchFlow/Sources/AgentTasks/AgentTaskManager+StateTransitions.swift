import Foundation
import AppKit

@MainActor
extension AgentTaskManager {
    // MARK: - Internal state transitions

    /// Hard cap on the detail log — a marathon run keeps its newest trail, not
    /// an unbounded array of every command it ever ran.
    private static let logCap = 300

    private static func permissionToolName(for entry: AgentLogEntry) -> String? {
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.hasPrefix("$") { return "Bash" }
        if title.hasPrefix("Editing ") { return "Edit" }
        if title.hasPrefix("Creating ") { return "Write" }
        if title.hasPrefix("Searching ") { return "WebSearch" }
        if title.hasPrefix("Reading http") { return "WebFetch" }
        let firstWord = title.split(separator: " ", maxSplits: 1).first.map(String.init) ?? title
        if ["Bash", "Write", "Edit", "MultiEdit", "NotebookEdit"].contains(firstWord)
            || firstWord.lowercased().hasPrefix("mcp__") {
            return firstWord
        }
        return nil
    }

    private func schedulePermissionCheck(taskID: UUID, entryID: UUID, toolName: String, startedAt: Date) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(AgentPermissionPolicy.delay * 1_000_000_000))
            guard let self, let i = self.taskIndex(taskID), self.tasks[i].isRunning,
                  self.tasks[i].activePermissionTool == toolName,
                  self.tasks[i].activePermissionEntryID == entryID,
                  self.tasks[i].activePermissionStartedAt == startedAt else { return }
            self.tasks[i].pendingPermissionTool = toolName
        }
    }

    func applyProgress(_ update: AgentProgress, for taskID: UUID) {
        guard let i = taskIndex(taskID), tasks[i].isRunning else { return }
        var t = tasks[i]
        let newSession = update.sessionID != nil && update.sessionID != t.sessionID
        if let activity = update.activity { t.activity = activity }
        if let model = update.model { t.modelID = model }
        if let session = update.sessionID { t.sessionID = session }
        if let used = update.contextUsed { t.contextUsed = used }
        if let window = update.contextWindow { t.contextWindow = window }
        for file in update.changedFiles where !t.changedFiles.contains(file) {
            t.changedFiles.append(file)
        }
        if !update.entries.isEmpty {
            t.log.append(contentsOf: update.entries)
            if t.log.count > Self.logCap {
                let dropped = t.log.count - Self.logCap
                t.log.removeFirst(dropped)
                // Keep the round-start marker pointing at the same entry.
                if let run = runs[taskID] {
                    run.logStartIndex = max(0, run.logStartIndex - dropped)
                }
            }
            if let entry = update.entries.last,
               let toolName = Self.permissionToolName(for: entry) {
                let startedAt = Date()
                t.activePermissionTool = toolName
                t.activePermissionEntryID = entry.id
                t.activePermissionStartedAt = startedAt
                t.pendingPermissionTool = nil
                schedulePermissionCheck(taskID: taskID, entryID: entry.id,
                                        toolName: toolName, startedAt: startedAt)
            }
        }
        // A block still being written grows in place; an id that fell off the
        // cap is simply gone (no-op), same as the two loops below.
        for (id, text) in update.appends {
            if let j = t.log.firstIndex(where: { $0.id == id }) { t.log[j].title += text }
        }
        // The CLI's authoritative copy of a block, or a plan being revised.
        for (id, title, detail) in update.rewrites {
            guard let j = t.log.firstIndex(where: { $0.id == id }) else { continue }
            t.log[j].title = title
            if let detail { t.log[j].detail = detail }
        }
        // Outputs arrive after their tool call (a later result event) — attach
        // in place. A row that drew its OWN detail (a patch, a checklist) keeps
        // it: the tool result for those is boilerplate ("the file was updated").
        // A failed call is the exception — it replaces the row's content, and
        // demotes it to a plain one, so a rejected edit can't keep reading as an
        // applied patch.
        for (id, detail, isError) in update.details {
            guard let j = t.log.firstIndex(where: { $0.id == id }) else { continue }
            if isError {
                t.log[j] = AgentLogEntry(id: t.log[j].id, title: t.log[j].title,
                                         mono: t.log[j].mono, detail: detail)
            } else if t.log[j].kind == .plain {
                t.log[j].detail = detail
            }
        }
        if let activeEntryID = t.activePermissionEntryID,
           (update.details.contains(where: { $0.id == activeEntryID })
            || update.completedEntries.contains(activeEntryID)) {
            t.activePermissionTool = nil
            t.activePermissionEntryID = nil
            t.activePermissionStartedAt = nil
            t.pendingPermissionTool = nil
        }
        tasks[i] = t
        // The session id lands a beat after the spawn, so the in-flight marker
        // is re-written once it's known: an interrupted run's Recent row can
        // then name the command that picks the session back up.
        if newSession { refreshInFlight(t) }
    }

    /// Remove the temp image files a codex run attached, if any. Idempotent.
    private func cleanupTempImages(_ run: RunState) {
        for url in run.tempImageURLs { try? FileManager.default.removeItem(at: url) }
        run.tempImageURLs = []
    }

    /// `interrupted` is the re-attached path's verdict: the process exited
    /// without its stream ever reaching a terminal event (killed externally,
    /// crashed) — files like a death-with-the-app, resumable from its row.
    func settle(taskID: UUID, snapshot: AgentSnapshot,
                        exitStatus: Int32, interrupted: Bool = false) {
        guard let i = taskIndex(taskID), tasks[i].isRunning,
              let run = runs[taskID] else {
            // A settle that lands here leaves NO exchange and NO history row —
            // if a run ever "vanishes", this breadcrumb is the lead. Should be
            // unreachable: the teardown latch fires exactly once per run.
            DiagnosticsLog.shared.record(provider: "Agent", kind: "agent-settle-dropped")
            return
        }
        var t = tasks[i]
        runs[taskID] = nil
        cleanupTempImages(run)
        // The in-flight crash marker is NOT cleared here: it survives until the
        // history row is safely on disk (`recordAgentHistory` clears it after
        // its immediate archive write). Clearing at settle left a window —
        // marker gone, row still in the save debounce — where a crash erased
        // the run entirely.
        t.finishedAt = Date()
        t.activity = nil
        t.result = snapshot.finalMessage

        if run.cancelRequested {
            t.outcome = .cancelled
        } else if interrupted {
            t.outcome = .failure
            t.failureReason = L("agent.interrupted")
            t.interrupted = true
        } else if let failure = snapshot.failure {
            t.outcome = .failure
            t.failureReason = Self.friendlyFailure(failure, engine: t.engine)
        } else if exitStatus != 0 && snapshot.finalMessage.isEmpty {
            t.outcome = .failure
            t.failureReason = snapshot.stderrTail.isEmpty
                ? nil : Self.friendlyFailure(snapshot.stderrTail, engine: t.engine)
        } else {
            t.outcome = .success
        }

        // Every settled round becomes an exchange — a cancel included. A run
        // the user stops after ten minutes still edited files and still has a
        // resumable CLI session; dropping it on the floor was how a stopped run
        // vanished the moment its card was dismissed. The answer text here is
        // what history shows, so empty results fall back to the same outcome
        // lines the card headline uses.
        let answer: String
        switch t.outcome {
        case .success:
            let body = t.result.trimmingCharacters(in: .whitespacesAndNewlines)
            answer = body.isEmpty
                ? L("agent.done", t.engine.displayName,
                    NotchModel.formatAgentElapsed(t.elapsed))
                : body
        case .cancelled:
            // Whatever the run had already reported before the stop is worth
            // keeping — it's the only trace of the work it did.
            let body = t.result.trimmingCharacters(in: .whitespacesAndNewlines)
            answer = body.isEmpty
                ? L("agent.cancelled")
                : L("agent.cancelled") + "\n" + body
        default:
            let reason = (t.failureReason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if t.interrupted {
                // Same closing line the launch-recovery interrupted rows use.
                answer = L("agent.interrupted")
            } else {
                answer = reason.isEmpty
                    ? L("agent.failed", t.engine.displayName)
                    : L("agent.failed", t.engine.displayName) + "\n" + reason
            }
        }
        // A follow-up marker is only a live placeholder. Once the round becomes
        // an exchange, the prompt is rendered by `UserQuestionBubble`; leaving
        // the marker in either trail printed the same instruction again below.
        var roundStartIndex = run.logStartIndex
        if let markerID = run.promptMarkerID {
            if let markerIndex = t.log.firstIndex(where: { $0.id == markerID }) {
                t.log.remove(at: markerIndex)
                if markerIndex < roundStartIndex { roundStartIndex -= 1 }
            }
            for exchangeIndex in t.exchanges.indices {
                t.exchanges[exchangeIndex].log.removeAll { $0.id == markerID }
            }
        }
        let roundLog = roundStartIndex < t.log.count
            ? Array(t.log[roundStartIndex...]) : []
        t.exchanges.append(AgentExchange(prompt: run.currentPrompt, answer: answer,
                                         imageFiles: run.currentImageFiles,
                                         log: roundLog))
        tasks[i] = t

        // The history record is filed FIRST (via `onSettled` → Recent, keyed by
        // the task id), so the banner's tap below can land on an existing row.
        onSettled?(t)

        // An agent task runs for minutes — the user has almost certainly moved
        // on, so a finished run announces itself. Not a cancel, though: the user
        // just did that by hand, so there's nothing to announce (the row is
        // still filed above — it just doesn't buzz).
        if t.outcome != .cancelled {
            NotificationService.shared.postAgentFinished(
                engineName: t.engine.displayName,
                prompt: t.exchanges.last?.prompt ?? t.prompt,
                failureReason: t.failureReason,
                success: t.outcome == .success,
                threadID: t.id)
        }

        // An interrupt is a cancel that hands over: the stopped round is filed
        // above like any other, and the instruction that stopped it opens the
        // next one right now, in the same session. Anything queued behind it
        // stays queued — it dispatches on the interrupting round's own settle.
        if let prompt = run.interruptPrompt, let i = taskIndex(taskID) {
            beginFollowUpRound(index: i, prompt: prompt,
                               imagesJPEG: run.interruptImages, appendMarker: true,
                               existingMarkerID: nil)
            return
        }

        // Follow-ups typed while this round ran dispatch now, oldest first, one
        // per settle — each becomes its own round in the same session. A cancel
        // clears the queue instead: the user said stop, so nothing auto-restarts.
        if t.outcome == .cancelled {
            pendingFollowUps[taskID] = nil
        } else if var queue = pendingFollowUps[taskID], !queue.isEmpty {
            let next = queue.removeFirst()
            pendingFollowUps[taskID] = queue.isEmpty ? nil : queue
            if let i = taskIndex(taskID) {
                beginFollowUpRound(index: i, prompt: next.prompt,
                                   imagesJPEG: next.imagesJPEG, appendMarker: false,
                                   existingMarkerID: next.markerID)
            }
        }
    }
}
