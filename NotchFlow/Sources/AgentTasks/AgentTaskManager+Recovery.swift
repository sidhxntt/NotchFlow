import Foundation
import AppKit

@MainActor
extension AgentTaskManager {
    // MARK: - Surviving an abnormal exit

    /// A run that was still in flight, remembered on disk. The live task lives
    /// only in memory and history is written when the run *settles* — so a quit,
    /// a crash, or a kill mid-run used to erase the run entirely: no card, no
    /// Recent row, nothing but the CLI's own session on disk. This marker is
    /// written when the process spawns and cleared when it settles; anything
    /// still there at launch is by definition a run that never got to settle.
    /// (Since the reliability pass, "settle" here means *filed to disk*: the
    /// marker outlives settle itself and is cleared by `recordAgentHistory`
    /// only after the run's history row is written.)
    private struct InFlightRun: Codable {
        struct Round: Codable { let prompt: String; let answer: String }
        let engine: String
        let folderPath: String
        /// The task description the run started with (the headline).
        let prompt: String
        /// The prompt of the round that was actually interrupted — the task
        /// description on round one, the follow-up text after.
        let currentPrompt: String
        let startedAt: Date
        /// Rounds that had already settled before the interruption.
        let rounds: [Round]
        /// The CLI's own conversation handle, when the round got far enough to
        /// report one — the run is resumable from a terminal with it.
        let sessionID: String?
        // v2 (runs survive the app): identify the possibly-still-running
        // process, and carry the round's pasted images. All optional so a
        // marker written by an older build still decodes (it just can't
        // re-attach — its process died with its pipes anyway).
        /// The spawned process, for the relaunch to find again.
        let pid: Int32?
        /// Wall clock at spawn — matched against the kernel's start time for
        /// `pid` on recovery, so a recycled pid can't impersonate the run.
        let processStartedAt: Date?
        /// This round's images (filenames in the history image store), so a
        /// recovered exchange keeps its screenshots.
        let currentImageFiles: [String]?
    }

    /// Each parallel run writes its own marker under `<prefix>_<task-uuid>`.
    /// The bare prefix is also the pre-parallel single-slot key — recovery
    /// consumes it too, so an update never loses a run that was in flight.
    private nonisolated static let inFlightKeyPrefix = "notch_agent_inflight"

    // Pure string assembly — nonisolated so `clearInFlight` (called off-main
    // from the archive write's completion) can build the key too.
    private nonisolated static func inFlightKey(_ taskID: UUID) -> String {
        inFlightKeyPrefix + "_" + taskID.uuidString
    }

    static func saveInFlight(task: AgentTask?, currentPrompt: String,
                                     pid: Int32?, spawnedAt: Date?,
                                     imageFiles: [String]) {
        guard let t = task else { return }
        let run = InFlightRun(
            engine: t.engine.rawValue,
            folderPath: t.folder.path,
            prompt: t.prompt,
            currentPrompt: currentPrompt,
            startedAt: t.startedAt,
            rounds: t.exchanges.map { .init(prompt: $0.prompt, answer: $0.answer) },
            sessionID: t.sessionID,
            pid: pid,
            processStartedAt: spawnedAt,
            currentImageFiles: imageFiles.isEmpty ? nil : imageFiles)
        guard let data = try? JSONEncoder().encode(run) else { return }
        UserDefaults.standard.set(data, forKey: inFlightKey(t.id))
    }

    /// Cleared only when the settled run's history row is on disk (see
    /// `NotchModel.recordAgentHistory`) — or consumed by launch recovery.
    /// The run's log files go with it: once the row is filed, the bytes are done.
    /// `nonisolated` so the archive write's completion can call it off-main;
    /// UserDefaults is thread-safe.
    nonisolated static func clearInFlight(taskID: UUID) {
        UserDefaults.standard.removeObject(forKey: inFlightKey(taskID))
        removeRunLogs(taskID: taskID)
    }

    /// Re-record the session id once the CLI reports it, so a run interrupted
    /// mid-flight still names a resumable session in its Recent row.
    func refreshInFlight(_ t: AgentTask) {
        let run = runs[t.id]
        Self.saveInFlight(task: t, currentPrompt: run?.currentPrompt ?? t.prompt,
                          pid: run?.pid, spawnedAt: run?.spawnedAt,
                          imageFiles: run?.currentImageFiles ?? [])
    }

    /// What the runs that were in flight when the app last went away come back
    /// as — empty if the last exit was clean. Consumes the markers: called
    /// once, at launch, by `AppDelegate`. Also swallows the pre-parallel
    /// single-slot key. Three legs, in order of how much survived:
    ///
    ///  1. the **process is still alive** (the whole point of the file
    ///     redirect) → re-adopted in place: its task rejoins `tasks` as
    ///     running, the stdout log replays into the card, and the run settles
    ///     normally when the process exits. Not in the return value.
    ///  2. the process **finished while the app was away** (its log ends with
    ///     the stream's own terminal event) → returned as a normal
    ///     success/failure task, with the completion notification the user
    ///     never got.
    ///  3. the process **died mid-run** (killed, crashed, or an old marker
    ///     from before the redirect) → the historical interrupted row,
    ///     resumable via its session id.
    func recoverInterruptedRuns() -> [AgentTask] {
        let defaults = UserDefaults.standard
        var markers: [(taskID: UUID, marker: InFlightRun)] = []
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix(Self.inFlightKeyPrefix) {
            if let data = defaults.data(forKey: key),
               let run = try? JSONDecoder().decode(InFlightRun.self, from: data) {
                // The marker key carries the task id — keeping it means the run
                // settles back into the SAME Recent row across any number of
                // app restarts. (A pre-parallel single-slot key gets a fresh one.)
                let suffix = String(key.dropFirst(Self.inFlightKeyPrefix.count + 1))
                markers.append((UUID(uuidString: suffix) ?? UUID(), run))
            }
            defaults.removeObject(forKey: key)
        }

        var settled: [AgentTask] = []
        var adopted: Set<UUID> = []
        for (taskID, marker) in markers {
            guard let engine = AgentEngine(rawValue: marker.engine) else { continue }

            // Leg 1 — alive: same pid AND same kernel start time (a recycled
            // pid fails the second check).
            if let pid = marker.pid, let spawnedAt = marker.processStartedAt,
               let kernelStart = Self.processStartTime(pid: pid_t(pid)),
               abs(kernelStart.timeIntervalSince(spawnedAt)) < 15 {
                reattach(taskID: taskID, marker: marker, engine: engine, pid: pid_t(pid))
                adopted.insert(taskID)
                continue
            }

            // Leg 2 — finished while away: harvest the log's result.
            if let done = settleFromLog(taskID: taskID, marker: marker, engine: engine) {
                DiagnosticsLog.shared.record(provider: "Agent/\(engine.displayName)",
                                             kind: "agent-recovered-finished")
                NotificationService.shared.postAgentFinished(
                    engineName: engine.displayName,
                    prompt: done.exchanges.last?.prompt ?? done.prompt,
                    failureReason: done.failureReason,
                    success: done.outcome == .success,
                    threadID: done.id)
                settled.append(done)
                continue
            }

            // Leg 3 — gone: the interrupted row.
            settled.append(Self.interruptedTask(taskID: taskID, marker: marker,
                                                engine: engine))
        }

        // Sweep every log a re-attached run doesn't own — harvested,
        // interrupted and orphaned files alike (their rows are filed or moot;
        // the bytes are done).
        if let files = try? FileManager.default.contentsOfDirectory(
            at: Self.runLogsDirectory, includingPropertiesForKeys: nil) {
            for file in files {
                let stem = file.deletingPathExtension().deletingPathExtension()
                    .lastPathComponent
                if let id = UUID(uuidString: stem), adopted.contains(id) { continue }
                try? FileManager.default.removeItem(at: file)
            }
        }
        return settled
    }

    /// Adopt a run whose process outlived the previous app instance: rebuild
    /// its live task, replay the stdout log from the top through a fresh
    /// parser (work trail, session id, model and context gauge all come
    /// back), keep tailing the file, and watch the pid for exit. From the
    /// outside it's the same run, still going.
    private func reattach(taskID: UUID, marker: InFlightRun,
                          engine: AgentEngine, pid: pid_t) {
        var t = AgentTask(id: taskID, engine: engine,
                          folder: URL(fileURLWithPath: marker.folderPath),
                          prompt: marker.prompt, startedAt: marker.startedAt)
        t.sessionID = marker.sessionID
        t.exchanges = marker.rounds.map { .init(prompt: $0.prompt, answer: $0.answer) }
        // A follow-up round reopens the trail where its prompt did originally.
        let promptMarkerID: UUID?
        if !t.exchanges.isEmpty {
            let id = UUID()
            t.log.append(AgentLogEntry(id: id, title: "› " + marker.currentPrompt,
                                       mono: false))
            promptMarkerID = id
        } else {
            promptMarkerID = nil
        }
        tasks.append(t)

        let run = RunState()
        run.currentPrompt = marker.currentPrompt
        run.promptMarkerID = promptMarkerID
        run.currentImageFiles = marker.currentImageFiles ?? []
        run.pid = pid
        run.spawnedAt = marker.processStartedAt
        runs[taskID] = run
        // Re-arm the marker this recovery just consumed — the run can outlive
        // THIS app instance too.
        Self.saveInFlight(task: t, currentPrompt: marker.currentPrompt,
                          pid: Int32(pid), spawnedAt: run.spawnedAt,
                          imageFiles: run.currentImageFiles)

        let state: AgentEventParser = Self.makeParser(for: engine)
        let outURL = Self.stdoutLogURL(taskID: taskID)
        let errURL = Self.stderrLogURL(taskID: taskID)
        // The tailer starts at offset zero, so its first tick replays
        // everything the run streamed before the app went away — the card
        // comes back mid-sentence.
        let tailer = RunLogTailer(url: outURL) { [weak self] data in
            if let update = state.ingest(data) {
                Task { @MainActor in
                    self?.applyProgress(update, for: taskID)
                }
            }
        }
        run.stdoutTailer = tailer

        // What's left of the runaway ceiling still applies, measured from the
        // round's original start.
        let elapsed = max(0, Date().timeIntervalSince(marker.startedAt))
        let watchdog = DispatchWorkItem { kill(pid, SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + max(30, Self.timeout - elapsed),
                                          execute: watchdog)

        // Exit detection for a process that is NOT our child: kqueue via a
        // dispatch process source. No exit status crosses it (launchd reaps
        // the orphan), so the stream's own terminal event stands in — reached
        // it = the CLI concluded; short of it = the run died out from under
        // us → files as interrupted (resumable), same as a death with the app.
        let once = OnceFlag()
        let finishUp: () -> Void = { [weak self] in
            guard once.tryFire() else { return }
            watchdog.cancel()
            tailer.finishAndDrain()
            Self.appendStderrFile(errURL, to: state)
            let snapshot = state.finish()
            Task { @MainActor in
                self?.settle(taskID: taskID, snapshot: snapshot,
                             exitStatus: snapshot.sawTerminal ? 0 : 1,
                             interrupted: !snapshot.sawTerminal)
            }
        }
        let src = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit,
                                                   queue: .global())
        src.setEventHandler { [weak src] in
            src?.cancel()
            finishUp()
        }
        run.exitWatch = src
        src.resume()
        // The pid could have exited in the beat between the liveness probe and
        // the source registration — in which case the source never fires.
        // Re-probe; `once` keeps the two paths from double-settling.
        if Self.processStartTime(pid: pid) == nil {
            src.cancel()
            finishUp()
        }

        DiagnosticsLog.shared.record(provider: "Agent/\(engine.displayName)",
                                     kind: "agent-reattached")
    }

    /// Harvest a run whose process finished while the app was away: parse the
    /// full stdout log; only a stream that reached its own terminal event
    /// (claude's `result`, codex's `turn.completed`/`turn.failed`) counts as
    /// finished — anything short of that returns nil and files as interrupted
    /// instead.
    private func settleFromLog(taskID: UUID, marker: InFlightRun,
                               engine: AgentEngine) -> AgentTask? {
        let outURL = Self.stdoutLogURL(taskID: taskID)
        guard let data = try? Data(contentsOf: outURL), !data.isEmpty else { return nil }
        let state: AgentEventParser = Self.makeParser(for: engine)
        let progress = state.ingest(data)
        Self.appendStderrFile(Self.stderrLogURL(taskID: taskID), to: state)
        let snapshot = state.finish()
        guard snapshot.sawTerminal else { return nil }

        var t = AgentTask(id: taskID, engine: engine,
                          folder: URL(fileURLWithPath: marker.folderPath),
                          prompt: marker.prompt, startedAt: marker.startedAt)
        // The log is fresher than the marker: `--resume` forks a new session
        // id per round, and the marker only catches up when the app was still
        // around to see the init event.
        t.sessionID = progress?.sessionID ?? marker.sessionID
        t.modelID = progress?.model
        t.contextUsed = progress?.contextUsed
        t.contextWindow = progress?.contextWindow
        t.changedFiles = progress?.changedFiles ?? []
        t.exchanges = marker.rounds.map { .init(prompt: $0.prompt, answer: $0.answer) }
        // Finished when the log stopped growing, not when we found it — keeps
        // the "finished in …" line honest.
        let attrs = try? FileManager.default.attributesOfItem(atPath: outURL.path)
        t.finishedAt = attrs?[.modificationDate] as? Date ?? Date()
        t.result = snapshot.finalMessage
        if let failure = snapshot.failure {
            t.outcome = .failure
            t.failureReason = Self.friendlyFailure(failure, engine: engine)
        } else {
            t.outcome = .success
        }

        // Same answer text a live settle would have produced.
        let answer: String
        if t.outcome == .success {
            let body = snapshot.finalMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            answer = body.isEmpty
                ? L("agent.done", engine.displayName,
                    NotchModel.formatAgentElapsed(t.elapsed))
                : body
        } else {
            let reason = (t.failureReason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            answer = reason.isEmpty
                ? L("agent.failed", engine.displayName)
                : L("agent.failed", engine.displayName) + "\n" + reason
        }
        t.exchanges.append(AgentExchange(prompt: marker.currentPrompt, answer: answer,
                                         imageFiles: marker.currentImageFiles ?? []))
        return t
    }

    /// Claude's raw auth-failure strings ("OAuth session expired and could
    /// not be refreshed", …) tell the user nothing actionable — swap in the
    /// terminal `/login` guidance. Codex reasons pass through verbatim (its
    /// re-auth lives in-app, not in the terminal).
    nonisolated static func friendlyFailure(_ reason: String,
                                                    engine: AgentEngine) -> String {
        if engine == .claude, ClaudeCodeError.isAuthFailure(reason) {
            return L("claudecode.error.authExpired")
        }
        if engine == .grok, GrokError.isAuthFailure(reason) {
            return L("grok.error.authExpired")
        }
        if engine == .commandCode, CommandCodeError.isAuthFailure(reason) {
            return L("commandcode.error.authExpired")
        }
        if engine == .pi, PiError.isAuthFailure(reason) {
            return L("pi.error.authExpired")
        }
        return reason
    }

    /// The last-resort recovery: nothing left of the run but its marker (and
    /// maybe a truncated log) — the historical interrupted row.
    private static func interruptedTask(taskID: UUID, marker: InFlightRun,
                                        engine: AgentEngine) -> AgentTask {
        var t = AgentTask(id: taskID, engine: engine,
                          folder: URL(fileURLWithPath: marker.folderPath),
                          prompt: marker.prompt,
                          startedAt: marker.startedAt)
        t.sessionID = marker.sessionID
        t.exchanges = marker.rounds.map { .init(prompt: $0.prompt, answer: $0.answer) }
        t.finishedAt = Date()
        t.outcome = .failure
        t.failureReason = L("agent.interrupted")
        t.interrupted = true
        // The interrupted round closes the thread with the one fact we have.
        // How to pick it back up is NOT baked into the answer text: the session
        // id rides the Recent row instead (`HistoryItem.agentResume`), where it
        // becomes a one-tap resume — and only degrades to the terminal command
        // when the engine itself has gone missing.
        t.exchanges.append(AgentExchange(prompt: marker.currentPrompt,
                                         answer: L("agent.interrupted"),
                                         imageFiles: marker.currentImageFiles ?? []))
        return t
    }
    // MARK: - Run log files & process probing

    /// Where each round's redirected stdout/stderr live. `<taskID>.out.jsonl`
    /// doubles as the recovery record: on relaunch it replays through the same
    /// parser as if the stream had never stopped.
    nonisolated static var runLogsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask).first!
            .appendingPathComponent("Notch", isDirectory: true)
            .appendingPathComponent("AgentRunLogs", isDirectory: true)
    }

    nonisolated static func stdoutLogURL(taskID: UUID) -> URL {
        runLogsDirectory.appendingPathComponent(taskID.uuidString + ".out.jsonl")
    }

    nonisolated static func stderrLogURL(taskID: UUID) -> URL {
        runLogsDirectory.appendingPathComponent(taskID.uuidString + ".err.log")
    }

    nonisolated private static func removeRunLogs(taskID: UUID) {
        try? FileManager.default.removeItem(at: stdoutLogURL(taskID: taskID))
        try? FileManager.default.removeItem(at: stderrLogURL(taskID: taskID))
    }

    /// Feed a run's redirected stderr file to its parser at teardown — the
    /// live pipe handler this replaces streamed the same bytes. Capped: only
    /// the tail survives into the failure reason anyway.
    nonisolated static func appendStderrFile(_ url: URL, to state: AgentEventParser) {
        guard var data = try? Data(contentsOf: url), !data.isEmpty else { return }
        if data.count > 65_536 {
            // Re-encode through a lossy decode so a suffix cut mid-character
            // can't fail the parser's strict UTF-8 read.
            data = Data(String(decoding: data.suffix(65_536), as: UTF8.self).utf8)
        }
        state.appendStderr(data)
    }

    /// The kernel's start time for `pid` — nil when no such process exists.
    /// The pair (pid, start time) identifies a process for good: a recycled
    /// pid can't match the original's start time.
    nonisolated private static func processStartTime(pid: pid_t) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0,
              size > 0, info.kp_proc.p_pid == pid else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec)
                    + TimeInterval(tv.tv_usec) / 1e6)
    }
}
