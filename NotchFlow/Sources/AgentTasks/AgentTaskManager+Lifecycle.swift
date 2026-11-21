import Foundation
import AppKit

@MainActor
extension AgentTaskManager {
    /// Kick off an agent run on `engine`. Runs in parallel with anything
    /// already working — each submit is its own process. No-op only when the
    /// engine's binary/sign-in is missing (the entry button is gated on
    /// availability, so this is belt-and-braces). `model` / `effort` are the
    /// armed row's explicit picks; nil leaves the CLI on its own config.
    /// `imagesJPEG` are the pasted images riding the task (already downsampled +
    /// JPEG-encoded off-main): codex attaches them natively (one `-i <file>` per
    /// image); claude has no image flag, so the prompt goes in as a stream-json
    /// user message carrying base64 vision blocks instead of plain stdin text.
    @discardableResult
    func start(folder: URL, prompt: String, engine: AgentEngine,
               model: String? = nil, effort: AgentEffort? = nil,
               imagesJPEG: [Data] = []) -> UUID? {
        guard LicenseService.shared.state.allowsProductServices else { return nil }
        guard NotchCapabilityStore.shared.agenticModeEnabled else { return nil }
        guard let binary = Self.binary(for: engine) else {
            // The entry button is availability-gated, so a missing binary or
            // sign-in here means the user pressed ⏎ and nothing happened —
            // worth a breadcrumb (metadata only, never the prompt).
            DiagnosticsLog.shared.record(provider: "Agent/\(engine.displayName)",
                                         kind: "agent-binary-missing")
            return nil
        }

        let t = AgentTask(engine: engine, modelID: model, folder: folder,
                          prompt: prompt, startedAt: Date(),
                          armedModel: model, armedEffort: effort)
        tasks.append(t)
        if engine == .codex {
            launchCodexAppServer(taskID: t.id, folder: folder, prompt: prompt,
                                 model: model, effort: effort)
            return t.id
        }
        launch(taskID: t.id, binary: binary, engine: engine, folder: folder,
               prompt: prompt, model: model, effort: effort,
               imagesJPEG: imagesJPEG, resumeSession: nil)
        return t.id
    }

    /// Codex turns launched by NotchFlow use the app-server rather than a
    /// detached `codex exec` process. The app-server owns the approval callbacks,
    /// so the Agent tab can make a per-session decision without a Terminal jump.
    private func launchCodexAppServer(taskID: UUID, folder: URL, prompt: String,
                                      model: String?, effort: AgentEffort?) {
        appServerPrompts[taskID] = prompt
        CodexAppServerBridge.shared.startTurn(
            folder: folder, prompt: prompt, model: model, effort: effort,
            onThreadStarted: { [weak self] threadID in
                guard let self, let i = self.taskIndex(taskID) else { return }
                self.tasks[i].sessionID = threadID
                self.tasks[i].activity = "Thinking"
            },
            onText: { [weak self] delta in
                guard let self, let i = self.taskIndex(taskID), self.tasks[i].isRunning else { return }
                self.tasks[i].result += delta
                self.tasks[i].activity = "Responding"
            },
            onFinished: { [weak self] success in
                self?.settleCodexAppServer(taskID: taskID, success: success)
            })
    }

    private func settleCodexAppServer(taskID: UUID, success: Bool) {
        guard let i = taskIndex(taskID), tasks[i].isRunning else { return }
        var task = tasks[i]
        let turnPrompt = appServerPrompts.removeValue(forKey: taskID) ?? task.prompt
        task.finishedAt = Date()
        task.activity = nil
        task.outcome = success ? .success : .failure
        if !success { task.failureReason = "Codex ended before completing this turn." }
        let answer = task.result.trimmingCharacters(in: .whitespacesAndNewlines)
        task.exchanges.append(AgentExchange(prompt: turnPrompt,
                                            answer: answer.isEmpty ? (success ? L("agent.done", task.engine.displayName, NotchModel.formatAgentElapsed(task.elapsed)) : task.failureReason ?? "Codex failed") : answer))
        tasks[i] = task
        onSettled?(task)
        if success {
            NotificationService.shared.postAgentFinished(engineName: task.engine.displayName,
                                                          prompt: task.prompt,
                                                          failureReason: nil,
                                                          success: true,
                                                          threadID: task.id)
        }
    }

    /// Continue a settled task in the same CLI session — the multi-turn path.
    /// Spawns a fresh process with the engine's resume flag pointed at the
    /// session the first round persisted; the same task revives as running and
    /// its work trail carries on. A follow-up sent while the task is still
    /// running is never dropped: it queues, and `settle` dispatches it as the
    /// next round the moment the current one ends. `imagesJPEG` are images
    /// pasted into the follow-up field — they ride the round exactly like
    /// round one's (codex `exec resume -i`; claude's stream-json vision blocks
    /// work the same under `--resume`).
    func followUp(taskID: UUID, prompt: String, imagesJPEG: [Data] = []) {
        guard LicenseService.shared.state.allowsProductServices else { return }
        guard NotchCapabilityStore.shared.agenticModeEnabled else { return }
        guard let i = taskIndex(taskID) else {
            DiagnosticsLog.shared.record(provider: "Agent", kind: "agent-followup-dropped")
            return
        }
        if tasks[i].isRunning {
            // Mid-round: the CLI can't take a new instruction while a round is
            // in flight, so the line queues for the next one. Its marker joins
            // the trail right away, so the user sees the instruction landed.
            let markerID = UUID()
            pendingFollowUps[taskID, default: []].append(
                QueuedFollowUp(prompt: prompt, imagesJPEG: imagesJPEG,
                               markerID: markerID))
            tasks[i].log.append(AgentLogEntry(id: markerID, title: "› " + prompt,
                                              mono: false))
            return
        }
        beginFollowUpRound(index: i, prompt: prompt, imagesJPEG: imagesJPEG,
                           appendMarker: true, existingMarkerID: nil)
    }

    /// The spawn half of `followUp`: revive the settled task as running and
    /// launch the round against its persisted session. `appendMarker` is false
    /// on a queued dispatch — that line's marker already joined the trail at
    /// queue time. No-op (with breadcrumb) when the task never got far enough
    /// to report a session id — nothing to resume, ever — in which case any
    /// queued lines are cleared too, since no future settle will dispatch them.
    func beginFollowUpRound(index i: Int, prompt: String,
                                    imagesJPEG: [Data], appendMarker: Bool,
                                    existingMarkerID: UUID?) {
        guard LicenseService.shared.state.allowsProductServices else {
            pendingFollowUps[tasks[i].id] = nil
            return
        }
        var t = tasks[i]
        guard let session = t.sessionID, let binary = Self.binary(for: t.engine) else {
            // Round one never reported a session id, or the engine's
            // binary/sign-in vanished since. Breadcrumb, metadata only.
            DiagnosticsLog.shared.record(provider: "Agent/\(t.engine.displayName)",
                                         kind: t.sessionID == nil
                                            ? "agent-followup-dropped" : "agent-binary-missing")
            pendingFollowUps[t.id] = nil
            return
        }

        t.outcome = nil
        t.finishedAt = nil
        t.startedAt = Date()
        t.result = ""
        t.failureReason = nil
        t.activity = nil
        // The follow-up joins the work trail where it happened, so the
        // transcript reads as one conversation.
        let markerID: UUID?
        if appendMarker {
            let id = UUID()
            t.log.append(AgentLogEntry(id: id, title: "› " + prompt, mono: false))
            markerID = id
        } else {
            markerID = existingMarkerID
        }
        tasks[i] = t
        if t.engine == .codex {
            launchCodexAppServerContinuation(taskID: t.id, threadID: session,
                                              prompt: prompt, effort: t.armedEffort)
            return
        }
        launch(taskID: t.id, binary: binary, engine: t.engine, folder: t.folder,
               prompt: prompt, model: t.armedModel, effort: t.armedEffort,
               imagesJPEG: imagesJPEG, resumeSession: session,
               promptMarkerID: markerID)
    }

    private func launchCodexAppServerContinuation(taskID: UUID, threadID: String,
                                                   prompt: String, effort: AgentEffort?) {
        appServerPrompts[taskID] = prompt
        CodexAppServerBridge.shared.continueTurn(
            threadID: threadID, prompt: prompt, effort: effort,
            onText: { [weak self] delta in
                guard let self, let i = self.taskIndex(taskID), self.tasks[i].isRunning else { return }
                self.tasks[i].result += delta
                self.tasks[i].activity = "Responding"
            },
            onFinished: { [weak self] success in
                self?.settleCodexAppServer(taskID: taskID, success: success)
            })
    }

    /// Pick an interrupted run back up in-app — the GUI half of `resumeCommand`.
    /// The app died mid-run; the CLI's session survived on disk, so this rebuilds
    /// the task around it and re-issues the round that never finished. `taskID` is
    /// the id of the Recent row the run left behind, so the row it settles back
    /// into REPLACES that one (same id → `recordAgentHistory` overwrites in place)
    /// rather than forking a second copy of the same conversation.
    ///
    /// No model/effort flags: the armed picks didn't survive the quit, and a
    /// resumed session already carries its own model — passing none leaves the
    /// engine on exactly what it was running. No-op if that task is somehow live.
    func resume(taskID: UUID, engine: AgentEngine, folder: URL, headline: String,
                session: String, priorRounds: [AgentExchange], prompt: String,
                imagesJPEG: [Data] = []) {
        guard LicenseService.shared.state.allowsProductServices else { return }
        guard taskIndex(taskID) == nil, let binary = Self.binary(for: engine) else {
            // The row's resume button is gated on the engine being installed, so
            // landing here means the tap silently did nothing. Breadcrumb only.
            DiagnosticsLog.shared.record(provider: "Agent/\(engine.displayName)",
                                         kind: "agent-resume-dropped")
            return
        }
        var t = AgentTask(id: taskID, engine: engine, folder: folder,
                          prompt: headline, startedAt: Date())
        t.sessionID = session
        t.exchanges = priorRounds
        // The re-issued round opens the trail where the interruption cut it off.
        let markerID = UUID()
        t.log.append(AgentLogEntry(id: markerID, title: "› " + prompt, mono: false))
        tasks.append(t)
        launch(taskID: taskID, binary: binary, engine: engine, folder: folder,
               prompt: prompt, model: nil, effort: nil,
               imagesJPEG: imagesJPEG, resumeSession: session,
               promptMarkerID: markerID)
    }

    /// The engine's resolved binary, gated on its sign-in — nil means "can't run".
    static func binary(for engine: AgentEngine) -> String? {
        switch engine {
        case .codex:  return CodexCLIService.authExists() ? CodexCLIService.resolveBinary() : nil
        case .claude: return ClaudeCLIService.authExists() ? ClaudeCLIService.resolveBinary() : nil
        case .grok:   return GrokCLIService.authExists() ? GrokCLIService.resolveBinary() : nil
        case .commandCode:
            return CommandCodeCLIService.authExists() ? CommandCodeCLIService.resolveBinary() : nil
        case .pi:
            // Resolve FIRST, then check the sign-in — the opposite order of its
            // siblings, and load-bearing: pi's `authExists` reads the catalog, and
            // the catalog is filled BY the resolution (`pi --list-models` is both
            // probes in one spawn). Asking first on a cold cache would answer "not
            // signed in" for a perfectly signed-in install.
            guard let binary = PiCLIService.resolveBinary() else { return nil }
            return PiCLIService.authExists() ? binary : nil
        }
    }

    /// The event parser for an engine's JSONL dialect.
    static func makeParser(for engine: AgentEngine) -> AgentEventParser {
        switch engine {
        case .codex:  return CodexAgentStreamState()
        case .claude: return ClaudeAgentStreamState()
        case .grok:   return GrokAgentStreamState()
        case .commandCode: return CommandCodeAgentStreamState()
        case .pi:     return PiAgentStreamState()
        }
    }

    /// The user-facing "couldn't start the CLI" reason for an engine.
    static func spawnFailureReason(_ engine: AgentEngine, _ detail: String) -> String? {
        switch engine {
        case .codex:  return CodexError.spawnFailed(detail).errorDescription
        case .claude: return ClaudeCodeError.spawnFailed(detail).errorDescription
        case .grok:   return GrokError.spawnFailed(detail).errorDescription
        case .commandCode: return CommandCodeError.spawnFailed(detail).errorDescription
        case .pi:     return PiError.spawnFailed(detail).errorDescription
        }
    }

    /// Stop one running task. The termination handler files it as cancelled.
    ///
    /// Returns whether this call is the one that requested the stop — false
    /// when the task isn't running, or a stop is already on its way (the
    /// process takes a beat to die, so a second press lands while the run
    /// still reads as live). Callers that give Esc a stepped meaning use that
    /// to hand the *next* press on to whatever comes after stopping.
    @discardableResult
    func cancel(taskID: UUID) -> Bool {
        guard let run = runs[taskID],
              tasks.first(where: { $0.id == taskID })?.isRunning == true,
              !run.cancelRequested else { return false }
        run.cancelRequested = true
        if let p = run.process {
            p.terminate()
        } else if let pid = run.pid {
            // A re-attached run has no Process handle — signal the pid
            // directly; its exit watch files the cancel.
            kill(pid, SIGTERM)
        }
        return true
    }

    /// Cancel all app-owned work when product entitlement is lost. CLI process
    /// runs settle through their normal termination handlers; app-server turns
    /// have no `RunState`, so they are settled synchronously before the shared
    /// app-server process is stopped. Queued follow-ups are discarded first so
    /// no completion race can launch another round.
    func suspendForLicenseBlock() {
        suspendAgentRuntime()
    }

    /// Agentic mode is a complete opt-out from app-owned agents and approval
    /// routing. Existing terminal hooks fail open once their socket closes, so
    /// the terminal resumes its own manual approval prompt.
    func suspendForAgenticModeDisabled() {
        suspendAgentRuntime()
    }

    private func suspendAgentRuntime() {
        pendingFollowUps.removeAll()
        externalMonitorTimer?.invalidate()
        externalMonitorTimer = nil
        externalTrackedTools.removeAll()
        externalApprovals = []

        let processTaskIDs = Array(runs.keys)
        for id in processTaskIDs { cancel(taskID: id) }

        let appServerIndices = tasks.indices.filter {
            tasks[$0].isRunning && runs[tasks[$0].id] == nil
        }
        for index in appServerIndices {
            var task = tasks[index]
            let prompt = appServerPrompts.removeValue(forKey: task.id) ?? task.prompt
            task.finishedAt = Date()
            task.activity = nil
            task.outcome = .cancelled
            task.failureReason = nil
            task.activePermissionTool = nil
            task.activePermissionEntryID = nil
            task.activePermissionStartedAt = nil
            let partial = task.result.trimmingCharacters(in: .whitespacesAndNewlines)
            let answer = partial.isEmpty
                ? L("agent.cancelled")
                : L("agent.cancelled") + "\n" + partial
            task.exchanges.append(AgentExchange(prompt: prompt, answer: answer))
            tasks[index] = task
            onSettled?(task)
        }
        CodexAppServerBridge.shared.shutdownForLicenseBlock()
        ClaudeHookBridge.shared.shutdownForLicenseBlock()
        CodexTerminalHookBridge.shared.shutdownForLicenseBlock()
    }

    /// Stop the round in flight and hand the agent a new instruction straight
    /// away — the "no, do this instead" of a terminal's Esc. The CLI has no way
    /// to take a mid-round instruction (headless, no TTY, stdin already closed),
    /// so this is the honest equivalent: kill the process, keep everything it
    /// reported, and re-open the SAME session with the new prompt the moment it
    /// settles. `whileRunning` is why this exists at all — queueing (`followUp`)
    /// makes the user wait out work they've already decided is wrong.
    ///
    /// Falls back to queueing when there's no session to resume yet (the round
    /// died before its id landed): stopping there would end the task outright.
    /// Returns whether the round was actually interrupted.
    @discardableResult
    func interrupt(taskID: UUID, prompt: String, imagesJPEG: [Data] = []) -> Bool {
        guard LicenseService.shared.state.allowsProductServices else { return false }
        guard let i = taskIndex(taskID), tasks[i].isRunning,
              let run = runs[taskID], tasks[i].sessionID != nil else {
            followUp(taskID: taskID, prompt: prompt, imagesJPEG: imagesJPEG)
            return false
        }
        run.interruptPrompt = prompt
        run.interruptImages = imagesJPEG
        cancel(taskID: taskID)
        return true
    }

    /// Dismiss one finished task's card. Never clears a running task. Any
    /// follow-ups still queued go with it — their task can no longer settle.
    func dismissFinished(taskID: UUID) {
        guard let i = taskIndex(taskID), !tasks[i].isRunning else { return }
        tasks.remove(at: i)
        pendingFollowUps[taskID] = nil
    }

    /// Clear only successfully completed work from the roster. Failed,
    /// cancelled, and still-running tasks remain available for inspection.
    func dismissCompleted() {
        let completedIDs = tasks.compactMap { task in
            task.outcome == .success ? task.id : nil
        }
        for id in completedIDs { dismissFinished(taskID: id) }
    }

    /// Reveal a task's folder in Finder — the finished card's "Open Folder".
    func openFolder(taskID: UUID) {
        guard let folder = tasks.first(where: { $0.id == taskID })?.folder else { return }
        NSWorkspace.shared.open(folder)
    }

    /// NotchFlow intentionally sends permission handling back to the terminal
    /// rather than attempting to answer an agent's approval request itself.
    /// Open Terminal in the run's working directory so the relevant session is
    /// immediately discoverable without changing the run's approval state.
    func openTerminalForPermission(taskID: UUID) {
        guard let task = tasks.first(where: { $0.id == taskID }) else { return }
        let escapedPath = task.folder.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "tell application \"Terminal\"\nactivate\ndo script \"cd \\\"\(escapedPath)\\\"\"\nend tell"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if error != nil, let terminal = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.open(terminal)
        }
    }

    /// Focus the user-owned Terminal process that is waiting for this external
    /// session's answer. If Terminal is not open, start it in the session's
    /// working folder; no approval is ever sent by NotchFlow.
    func openTerminalForExternalApproval(_ approval: ExternalApproval) {
        if let terminal = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.Terminal").first {
            terminal.activate(options: [.activateIgnoringOtherApps])
            return
        }
        let escapedPath = approval.folder.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "tell application \"Terminal\"\nactivate\ndo script \"cd \\\"\(escapedPath)\\\"\"\nend tell"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if error != nil, let terminal = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.open(terminal)
        }
    }
}
