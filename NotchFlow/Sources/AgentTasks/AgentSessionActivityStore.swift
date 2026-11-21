import Foundation
import AppKit

// MARK: - External Codex / Claude session observation

/// Reads the recent, user-owned JSONL records that Codex and Claude Code write.
/// Approval bridges own the approve/deny connection; this store simply supplies
/// an independent live status, context meter, and sub-agent count per session.
@MainActor
final class AgentSessionActivityStore: ObservableObject {
    static let shared = AgentSessionActivityStore()
    @Published private(set) var sessions: [AgentSessionState] = []
    @Published private(set) var discoveryMessage: String?
    /// The folded notch is only an announcement surface. It shows the newest
    /// non-permission state briefly, then releases the hardware notch while the
    /// persistent session card remains available in the Agent tab.
    @Published private(set) var preview: AgentSessionPreview?

    private struct Marker { let value: AgentSessionMarker; let receivedAt: Date }
    private struct ExternalSessionSnapshot {
        let sessions: [AgentSessionState]
        let codexHierarchy: CodexSessionHierarchy
        let discoveryMessage: String?
    }
    private var markers: [String: Marker] = [:]
    /// Terminal rows explicitly cleared from the roster. The source transcript
    /// is never touched; a future active state for the same id can still return.
    private var dismissedCompletedSessionKeys = Set<String>()
    /// Last background scan. Markers can immediately decorate this cached data
    /// without sending filesystem work through the main UI actor.
    private var scannedSessions: [AgentSessionState] = []
    /// When the scan behind `scannedSessions` began reading. A marker older than
    /// this has already been accounted for by the transcript, so it is spent —
    /// see `AgentSessionStatus.isTranscriptObservable`.
    private var scannedAt = Date.distantPast
    /// Shared with the approval bridges so child callbacks can be presented under
    /// their root session without ever changing the callback's own thread ID.
    private var codexHierarchy = CodexSessionHierarchy()
    private var codexHierarchyObservers: [UUID: (CodexSessionHierarchy) -> Void] = [:]
    private var scanInFlight = false
    private var usageImportInFlight = false
    private var lastCodexUsageImportAt: Date?
    private var refreshTimer: Timer?
    private var previewExpiryTimer: Timer?
    private static let codexUsageImportInterval: TimeInterval = 5 * 60
    private static let markerLifetime: TimeInterval = 30 * 60

    private init() {
        refresh()
        // Permission bridges are push-driven and retain their own fast poll.
        // Transcript discovery is deliberately slower: a two-second cadence is
        // still live enough for a roster, without asking the filesystem to walk
        // every Claude root and child directory twice per second forever.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func record(marker: AgentSessionMarker) {
        var normalized = normalized(marker)
        let markerKey = key(normalized.source, normalized.sessionID)
        if normalized.goal == nil, let retainedGoal = markers[markerKey]?.value.goal {
            normalized = normalized.retaining(goal: retainedGoal)
        }
        if !isTerminal(normalized.status) {
            dismissedCompletedSessionKeys.remove(key(normalized.source, normalized.sessionID))
        }
        markers[markerKey] = Marker(value: normalized, receivedAt: Date())
        rebuild(from: scannedSessions, at: Date())
        refresh()
    }

    /// Remove only terminal session cards. Active Working, Planning, permission,
    /// and question states are deliberately excluded from this operation.
    func clearCompletedSessions() {
        let completed = sessions.filter { isTerminal($0.status) }
        guard !completed.isEmpty else { return }
        for session in completed {
            let id = key(session.source, session.id)
            dismissedCompletedSessionKeys.insert(id)
            markers.removeValue(forKey: id)
        }
        if let preview, isTerminal(preview.session.status) { self.preview = nil }
        rebuild(from: scannedSessions, at: Date())
    }

    /// The presentation owner for a Codex callback. Unknown sessions remain
    /// independent until the scanner discovers their session metadata.
    func rootSessionID(for source: AgentApprovalSource, sessionID: String) -> String {
        guard source == .codex else { return sessionID }
        return codexHierarchy.rootSessionID(for: sessionID)
    }

    /// Keeps direct terminal permissions on the same visible root as a resumed
    /// transcript, while retaining the original thread ID for the callback.
    func groupedForPresentation(_ approval: AgentApproval) -> AgentApproval {
        let hierarchyRoot = rootSessionID(for: approval.source, sessionID: approval.threadID)
        let hierarchyGrouped = approval.grouped(under: hierarchyRoot)
        return hierarchyGrouped.grouped(under: AgentSessionWorkspaceMatcher.rootID(
            for: hierarchyGrouped,
            among: scannedSessions
        ))
    }

    /// Child session metadata lands asynchronously. Bridges subscribe so already
    /// visible approvals collapse into the parent row as soon as it is known.
    func observeCodexHierarchy(_ observer: @escaping (CodexSessionHierarchy) -> Void) -> UUID {
        let id = UUID()
        codexHierarchyObservers[id] = observer
        return id
    }

    func recordApproval(_ approval: AgentApproval) {
        record(marker: .init(sessionID: approval.sessionGroupID, source: approval.source,
                             status: .needsYou, detail: approval.detail))
    }

    func resolveApproval(_ approval: AgentApproval) {
        let rootID = approval.sessionGroupID
        let id = key(approval.source, rootID)
        guard markers[id]?.value.status == .needsYou else { return }
        record(marker: .init(sessionID: rootID, source: approval.source, status: .working))
    }

    /// Extra context for the non-actionable status cards. Questions and plan
    /// notices are deliberately informational: only a permission request owns
    /// an approval callback and can show controls in the Notch.
    func marker(for state: AgentSessionState) -> AgentSessionMarker? {
        markers[key(state.source, state.id)]?.value
    }

    private func refresh() {
        let now = Date()
        markers = markers.filter {
            let age = now.timeIntervalSince($0.value.receivedAt)
            return age >= 0 && age < Self.markerLifetime
        }
        guard !scanInFlight else {
            rebuild(from: scannedSessions, at: now)
            return
        }
        scanInFlight = true
        let importIsDue = lastCodexUsageImportAt.map {
            now.timeIntervalSince($0) >= Self.codexUsageImportInterval
        } ?? true
        let shouldImportCodexUsage = importIsDue && !usageImportInFlight
        if shouldImportCodexUsage {
            lastCodexUsageImportAt = now
            usageImportInFlight = true
        }
        Task.detached(priority: .utility) { [weak self] in
            let snapshot = Self.scanExternalSessions(now: now)
            await MainActor.run {
                guard let self else { return }
                self.scanInFlight = false
                self.scannedSessions = snapshot.sessions
                // `now`, not the completion time: a marker that arrived while
                // the scan was reading may describe an event written after the
                // file was read, so it must still count as fresher than it.
                self.scannedAt = now
                self.updateCodexHierarchy(snapshot.codexHierarchy)
                self.discoveryMessage = snapshot.discoveryMessage
                self.rebuild(from: snapshot.sessions, at: Date())
            }
            // Initial session discovery is latency-sensitive; the token history
            // is not. Publish the small, current roster before starting the
            // eight-day backfill, then keep that backfill out of the UI path.
            if shouldImportCodexUsage {
                await Self.importRecentCodexUsage(now: now)
                await Self.importRecentClaudeUsage(now: now)
                await MainActor.run { self?.usageImportInFlight = false }
            }
        }
    }

    private func rebuild(from scanned: [AgentSessionState], at now: Date) {
        normalizeStoredMarkers()
        var all = scanned
        var indexes = Dictionary(uniqueKeysWithValues: all.enumerated().map { (key($0.element.source, $0.element.id), $0.offset) })
        for (id, marker) in markers {
            if let index = indexes[id] {
                // A marker is a push about something the scan has not seen yet.
                // Once a later scan has read the transcript, the transcript is
                // the better witness for anything it can observe for itself, so
                // a spent marker is dropped instead of being re-applied on every
                // 0.5s rebuild — which is what pinned quiet sessions to Working
                // for the marker's full 30-minute lifetime.
                //
                // A pending permission or question is never in the transcript,
                // so those markers are exempt and hold until they are resolved.
                if marker.value.goal == nil,
                   marker.value.status.isTranscriptObservable, marker.receivedAt < scannedAt {
                    continue
                }
                if let goal = marker.value.goal { all[index].goal = goal }
                else { all[index].apply(status: marker.value.status) }
            } else {
                all.append(.init(id: marker.value.sessionID, source: marker.value.source,
                                 status: marker.value.status, goal: marker.value.goal))
                indexes[id] = all.count - 1
            }
        }
        all.removeAll { session in
            let id = key(session.source, session.id)
            guard dismissedCompletedSessionKeys.contains(id) else { return false }
            // A revived session must always return; only its prior terminal
            // incarnation remains hidden after the user clears it.
            if isTerminal(session.status) { return true }
            dismissedCompletedSessionKeys.remove(id)
            return false
        }
        let next = all.sorted {
            rank($0.status) == rank($1.status) ? $0.id < $1.id : rank($0.status) > rank($1.status)
        }
        // A preview is only valid while its session remains in the live roster.
        // Once a CLI closes/ages out and the scanner drops that session, keeping
        // the old preview would make the folded UI report stale "Working" state.
        if let preview,
           !next.contains(where: { $0.id == preview.session.id && $0.source == preview.session.source }) {
            self.preview = nil
            previewExpiryTimer?.invalidate()
            previewExpiryTimer = nil
        }
        announceChangedStatus(in: next, at: now)
        // The scanner is intentionally quiet when no actual state changed. This
        // avoids rebuilding the entire glass panel every refresh tick.
        if next != sessions { sessions = next }
    }

    private func announceChangedStatus(in next: [AgentSessionState], at now: Date) {
        let prior = Dictionary(uniqueKeysWithValues: sessions.map { (key($0.source, $0.id), $0) })
        guard let changed = next.first(where: {
            let previous = prior[key($0.source, $0.id)]
            if $0.goal != previous?.goal, $0.goal?.status.previewLabel != nil { return true }
            return $0.status != .needsYou && previous?.status != $0.status
        }) else { return }
        let previous = prior[key(changed.source, changed.id)]
        let announcement: AgentSessionPreviewAnnouncement
        if changed.goal != previous?.goal, let goal = changed.goal,
           goal.status.previewLabel != nil {
            announcement = .goal(goal.status)
        } else {
            announcement = .session(changed.status)
        }
        preview = AgentSessionPreview(session: changed, announcement: announcement, shownAt: now)
        previewExpiryTimer?.invalidate()
        previewExpiryTimer = Timer.scheduledTimer(withTimeInterval: AgentSessionPreview.duration,
                                                   repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, let preview = self.preview,
                      !preview.isVisible(at: Date()) else { return }
                self.preview = nil
            }
        }
    }

    private func rank(_ status: AgentSessionStatus) -> Int {
        switch status { case .needsYou: 4; case .question: 3; case .planning, .planReady: 2; case .working: 1; case .done, .interrupted: 0 }
    }
    private func isTerminal(_ status: AgentSessionStatus) -> Bool {
        status.isClearable
    }
    private func key(_ source: AgentApprovalSource, _ id: String) -> String { "\(source.rawValue):\(id)" }

    private func normalized(_ marker: AgentSessionMarker) -> AgentSessionMarker {
        let hierarchyRoot = rootSessionID(for: marker.source, sessionID: marker.sessionID)
        let presentationID: String
        if let workingDirectory = marker.workingDirectory {
            let probe = AgentApproval(id: "marker:\(marker.sessionID)", threadID: hierarchyRoot,
                                      itemID: "marker", title: "", workingDirectory: workingDirectory,
                                      source: marker.source, sessionGroupID: hierarchyRoot)
            presentationID = AgentSessionWorkspaceMatcher.rootID(for: probe, among: scannedSessions)
        } else {
            presentationID = hierarchyRoot
        }
        return AgentSessionMarker(sessionID: presentationID, source: marker.source, status: marker.status,
                                  detail: marker.detail, options: marker.options,
                                  workingDirectory: marker.workingDirectory)
    }

    private func normalizeStoredMarkers() {
        var rekeyed: [String: Marker] = [:]
        for marker in markers.values {
            let next = normalized(marker.value)
            let nextKey = key(next.source, next.sessionID)
            if let existing = rekeyed[nextKey], existing.receivedAt >= marker.receivedAt { continue }
            rekeyed[nextKey] = Marker(value: next, receivedAt: marker.receivedAt)
        }
        markers = rekeyed
    }

    private func updateCodexHierarchy(_ next: CodexSessionHierarchy) {
        let merged = codexHierarchy.merging(next)
        guard merged != codexHierarchy else { return }
        codexHierarchy = merged
        normalizeStoredMarkers()
        codexHierarchyObservers.values.forEach { $0(merged) }
    }

    private nonisolated static func scanExternalSessions(now: Date) -> ExternalSessionSnapshot {
        let codex = codexSessions(now: now)
        let claude = claudeSessions(now: now)
        let sessions = codex.sessions + claude.sessions
        return .init(sessions: sessions, codexHierarchy: codex.hierarchy,
                     discoveryMessage: AgentTranscriptDiscovery.message(
                        transcriptsFound: codex.transcriptsFound + claude.transcriptsFound,
                        recognizedSessions: sessions.count
                     ))
    }

    /// Codex stores provider-reported counters in its local JSONL transcripts.
    /// They are cumulative per session, so `CodexTranscriptUsage` converts them
    /// to timestamped deltas before they enter the local ledger.
    private nonisolated static func importRecentCodexUsage(now: Date) async {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        let oldest = now.addingTimeInterval(-8 * 24 * 60 * 60)
        for file in recentCodexFiles(root, since: oldest, now: now).sorted(by: { $0.modifiedAt > $1.modifiedAt }) {
            let url = file.url
            // Two bounds, both load-bearing on a long-lived session.
            //
            // A rollout left running for weeks reaches hundreds of megabytes,
            // and this used to read every one of them whole, every five
            // minutes, re-deriving thousands of events the ledger had already
            // stored and re-encoding each one. Reading a bounded tail is enough:
            // `incrementalEvents` works from differences between consecutive
            // counter records, so it only needs the recent ones, and the first
            // record in the window is spent establishing the baseline.
            guard importedCodexUsage(url, modifiedAt: file.fileModifiedAt) == false,
                  let data = read(url, limit: 4 * 1024 * 1024, tail: true) else { continue }
            // The second bound is time: an actively-written file always looks
            // changed, so the mtime check above can never skip it. Only events
            // newer than the newest one already taken from this file are worth
            // offering to the ledger.
            let alreadyImportedThrough = importedCodexUsageThrough(url)
                let sessionID = url.deletingPathExtension().lastPathComponent
                let project = lines(data).first(where: { $0["type"] as? String == "session_meta" })
                    .flatMap { $0["payload"] as? [String: Any] }
                    .flatMap { projectName(for: string($0["cwd"])) }
                if let context = CodexTranscriptContext.latest(in: data) {
                    TokenMeter.shared.recordContext(provider: "Codex", project: project, used: context.used,
                                                    window: context.window, at: file.modifiedAt)
                }
                var newest = alreadyImportedThrough
                for event in CodexTranscriptUsage.incrementalEvents(in: data, identifierPrefix: "codex:\(sessionID)")
                where event.timestamp >= oldest && event.timestamp <= now
                    && event.timestamp > alreadyImportedThrough {
                    TokenMeter.shared.record(input: event.input, output: event.output,
                                         provider: "Codex", recordedAt: event.timestamp,
                                         identifier: event.id, project: project)
                    newest = max(newest, event.timestamp)
            }
            noteCodexUsageImported(url, through: newest)
            // A fresh install can have hundreds of old rollouts. Cooperatively
            // yielding alone immediately resumes on the same idle core; this
            // small cadence leaves room for the resting notch and input work
            // while a durable backfill continues in the background.
            try? await Task.sleep(for: .milliseconds(250))
            await Task.yield()
        }
    }

    private nonisolated static func importRecentClaudeUsage(now: Date) async {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        let oldest = now.addingTimeInterval(-8 * 24 * 60 * 60)
        guard let files = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return }
        let candidates = files.compactMap { item -> (url: URL, modifiedAt: Date)? in
            guard let url = item as? URL, url.pathExtension == "jsonl", !url.path.contains("/subagents/"),
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true, let modifiedAt = values.contentModificationDate,
                  modifiedAt >= oldest else { return nil }
            return (url, modifiedAt)
        }.sorted { $0.modifiedAt > $1.modifiedAt }
        for candidate in candidates {
            let url = candidate.url
            guard url.pathExtension == "jsonl", !url.path.contains("/subagents/"),
                  let data = read(url, limit: 4 * 1024 * 1024, tail: true)
            else { continue }
            let entries = lines(data)
            let sessionID = entries.compactMap { string($0["sessionId"]) ?? string($0["session_id"]) }.first
                ?? url.deletingPathExtension().lastPathComponent
            let project = entries.compactMap { string($0["cwd"]) }.first.flatMap(projectName)
            for event in ClaudeTranscriptUsage.events(in: data, identifierPrefix: "claude:\(sessionID)")
            where event.timestamp >= oldest && event.timestamp <= now {
                TokenMeter.shared.record(input: event.input, output: event.output, provider: "Claude",
                                         recordedAt: event.timestamp, identifier: event.id, project: project)
            }
            try? await Task.sleep(for: .milliseconds(250))
            await Task.yield()
        }
    }

    private struct CodexRecord { let id: String; let parent: String?; let child: Bool; let state: AgentSessionState }
    private struct CodexSessionSnapshot {
        let sessions: [AgentSessionState]
        let hierarchy: CodexSessionHierarchy
        let transcriptsFound: Int
    }
    private nonisolated static func codexSessions(now: Date) -> CodexSessionSnapshot {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions", isDirectory: true)
        let files = recentCodexFiles(root, since: now.addingTimeInterval(-AgentSessionObservation.activeFileWindow), now: now)
            .filter { $0.url.lastPathComponent.hasPrefix("rollout-") }
            .sorted { $0.modifiedAt > $1.modifiedAt }
        let records = files.compactMap { parseCodex($0.url, modifiedAt: $0.modifiedAt,
                                                    cacheModifiedAt: $0.fileModifiedAt, now: now) }
        let hierarchy = CodexSessionHierarchy(parentBySessionID: Dictionary(
            uniqueKeysWithValues: records.compactMap { record in
                guard record.child, let parent = record.parent else { return nil }
                return (record.id, parent)
            }))
        let activeChildIDs = Set(records.lazy
            .filter { $0.child && !$0.state.status.isSettled }
            .map(\.id))
        let sessions = records.filter { !$0.child }.map { record -> AgentSessionState in
            var state = record.state
            state.subagentCount = hierarchy.activeSubagentCount(for: record.id,
                                                                activeIDs: activeChildIDs)
            return state
        }
        return .init(sessions: sessions, hierarchy: hierarchy, transcriptsFound: files.count)
    }

    /// Everything about a rollout that comes from its bytes, and therefore only
    /// changes when the file does.
    private struct CodexFileFacts {
        let identity: CodexSessionIdentity
        let activity: AgentSessionStatus
        let completed: Bool
        let aborted: Bool
        let used: Int?
        let window: Int?
        let model: String?
        let cwd: String?
        let goal: AgentGoal?
    }

    /// Parsed rollouts, keyed by path and invalidated by size and modification
    /// date.
    ///
    /// The roster rescans twice a second, and a long-lived Codex session's
    /// rollout grows without bound — one session left running for nineteen days
    /// accounted for most of 322 MB across six live files here. Re-reading and
    /// re-parsing that on every tick pinned a core at 110% to re-derive bytes
    /// that had not changed. A file whose size and mtime both match what we last
    /// saw cannot have new content, so the parse is reused and only the clock is
    /// re-applied.
    private nonisolated(unsafe) static var codexFactsCache: [String: (stamp: String, facts: CodexFileFacts)] = [:]
    private nonisolated static let codexFactsLock = NSLock()

    /// Whether this rollout has already been imported at exactly this
    /// modification date. Records the date as a side effect, so a caller that
    /// gets `false` is the one that must do the reading.
    private nonisolated(unsafe) static var importedCodexUsageAt: [String: Date] = [:]

    private nonisolated static func importedCodexUsage(_ url: URL, modifiedAt: Date) -> Bool {
        codexFactsLock.lock(); defer { codexFactsLock.unlock() }
        if importedCodexUsageAt[url.path] == modifiedAt { return true }
        importedCodexUsageAt[url.path] = modifiedAt
        return false
    }

    /// The newest event timestamp already taken from this rollout. Everything at
    /// or before it is in the ledger under an identifier the ledger would only
    /// deduplicate, so re-offering it is pure cost.
    private nonisolated(unsafe) static var importedCodexUsageThroughDate: [String: Date] = [:]

    private nonisolated static func importedCodexUsageThrough(_ url: URL) -> Date {
        codexFactsLock.lock(); defer { codexFactsLock.unlock() }
        return importedCodexUsageThroughDate[url.path] ?? .distantPast
    }

    private nonisolated static func noteCodexUsageImported(_ url: URL, through date: Date) {
        codexFactsLock.lock(); defer { codexFactsLock.unlock() }
        importedCodexUsageThroughDate[url.path] = date
    }

    private nonisolated static func codexFacts(_ url: URL, modifiedAt: Date) -> CodexFileFacts? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        let stamp = "\(modifiedAt.timeIntervalSince1970):\(size)"

        codexFactsLock.lock()
        let cached = codexFactsCache[url.path]
        codexFactsLock.unlock()
        if let cached, cached.stamp == stamp { return cached.facts }

        guard let head = read(url, limit: 64 * 1024, tail: false),
              let meta = lines(head).first(where: { $0["type"] as? String == "session_meta" })?["payload"] as? [String: Any],
              let identity = CodexTranscriptStatus.identity(in: meta) else { return nil }
        let tailData = read(url, limit: 1024 * 1024, tail: true) ?? Data()
        let tailEntries = lines(tailData)
        let context = CodexTranscriptContext.latest(in: tailData)
        // Both plan mode and the turn-terminal events are read by
        // `CodexTranscriptStatus`, which scopes completion to the newest turn
        // (a rollout keeps every earlier turn's `task_complete`) and matches
        // `turn_aborted` inside its `event_msg` envelope, where Codex actually
        // writes it.
        let signals = CodexTranscriptStatus.signals(in: tailEntries)
        let facts = CodexFileFacts(
            identity: identity,
            activity: CodexTranscriptStatus.activity(in: tailEntries),
            completed: signals.completed,
            aborted: signals.aborted,
            used: context?.used,
            window: context?.window ?? number(meta["context_window"]),
            model: string(meta["model"]) ?? tailEntries.reversed().compactMap { item in
                guard let payload = item["payload"] as? [String: Any] else { return nil }
                return string(payload["model"])
            }.first,
            cwd: string(meta["cwd"]),
            goal: CodexTranscriptStatus.goal(in: tailEntries))

        codexFactsLock.lock()
        codexFactsCache[url.path] = (stamp, facts)
        codexFactsLock.unlock()
        return facts
    }

    private nonisolated static func parseCodex(_ url: URL, modifiedAt: Date,
                                                cacheModifiedAt: Date, now: Date) -> CodexRecord? {
        guard let facts = codexFacts(url, modifiedAt: cacheModifiedAt) else { return nil }
        let identity = facts.identity
        let id = identity.id
        let used = facts.used
        let window = facts.window
        let model = facts.model
        // Only this part depends on the clock, so it is recomputed every tick
        // even on a cache hit: a turn that was working ten seconds ago may have
        // stalled since without the file changing at all.
        let resolvedStatus = facts.activity.resolved(terminal: AgentSessionTerminal.inferred(
            completed: facts.completed, aborted: facts.aborted,
            inactiveFor: max(0, now.timeIntervalSince(modifiedAt))))
        return .init(id: id, parent: identity.parentID, child: identity.isSubagent,
                     state: .init(id: id, source: .codex, status: resolvedStatus,
                                  contextUsed: used,
                                  contextWindow: used.map { _ in
                                      AgentModelContextWindow.window(
                                          reported: window,
                                          model: model, source: .codex, observedUsed: used)
                                  },
                                  projectName: projectName(for: facts.cwd), modelName: model,
                                  workingDirectory: facts.cwd, goal: facts.goal))
    }

    /// Everything in a Claude transcript derived from bytes rather than time.
    /// Keeping the parsed reading, rather than its final status, is important:
    /// an unchanged unfinished transcript can still become stalled.
    private struct ClaudeFileFacts {
        let id: String?
        let used: Int?
        let reading: AgentTranscriptReading
        let workingDirectory: String?
        let model: String?
        let planSummary: String?
    }

    private nonisolated(unsafe) static var claudeFactsCache: [String: (stamp: String, facts: ClaudeFileFacts, lastUsed: Date)] = [:]
    private nonisolated static let claudeFactsLock = NSLock()
    private nonisolated static let claudeFactsCacheCapacity = 512

    private nonisolated static func claudeFacts(_ url: URL, modifiedAt: Date) -> ClaudeFileFacts? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        let stamp = "\(modifiedAt.timeIntervalSince1970):\(size)"

        claudeFactsLock.lock()
        if let cached = claudeFactsCache[url.path], cached.stamp == stamp {
            claudeFactsCache[url.path] = (cached.stamp, cached.facts, Date())
            claudeFactsLock.unlock()
            return cached.facts
        }
        claudeFactsLock.unlock()

        guard let data = read(url, limit: 160 * 1024, tail: true) else { return nil }
        let entries = lines(data)
        var used: Int?
        for item in entries.reversed() {
            guard item["type"] as? String == "assistant",
                  let usage = (item["message"] as? [String: Any])?["usage"] as? [String: Any]
            else { continue }
            used = (number(usage["input_tokens"]) ?? 0)
                + (number(usage["cache_read_input_tokens"]) ?? 0)
                + (number(usage["cache_creation_input_tokens"]) ?? 0)
            break
        }
        let facts = ClaudeFileFacts(
            id: ClaudeTranscriptStatus.sessionID(in: entries),
            used: used,
            reading: ClaudeTranscriptStatus.reading(in: entries),
            workingDirectory: entries.reversed().compactMap { string($0["cwd"]) }.first,
            model: ClaudeTranscriptStatus.modelName(in: entries),
            planSummary: ClaudeTranscriptStatus.planSummary(in: entries)
        )
        claudeFactsLock.lock()
        claudeFactsCache[url.path] = (stamp, facts, Date())
        if claudeFactsCache.count > claudeFactsCacheCapacity {
            let stale = claudeFactsCache.sorted { $0.value.lastUsed < $1.value.lastUsed }
                .prefix(claudeFactsCache.count - claudeFactsCacheCapacity)
            stale.forEach { claudeFactsCache.removeValue(forKey: $0.key) }
        }
        claudeFactsLock.unlock()
        return facts
    }

    private struct ClaudeSessionSnapshot {
        let sessions: [AgentSessionState]
        let transcriptsFound: Int
    }

    private nonisolated static func claudeSessions(now: Date) -> ClaudeSessionSnapshot {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
        let files = recentFiles(root, now: now, predicate: { !$0.path.contains("/subagents/") })
            .sorted { $0.modifiedAt > $1.modifiedAt }
        let configuredModel = claudeConfiguredModel()
        return .init(sessions: files.compactMap { parseClaude($0.url, modifiedAt: $0.modifiedAt,
                                                              cacheModifiedAt: $0.fileModifiedAt, now: now,
                                                              configuredModel: configuredModel) },
                     transcriptsFound: files.count)
    }

    /// The `model` the user set in Claude Code's settings, e.g. `opus[1m]`.
    /// The transcript records only the API id (`claude-opus-…`), never the
    /// `[1m]` that opts a session into the 1M context window, so this is the
    /// one place that choice can be read back from.
    private nonisolated static func claudeConfiguredModel() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json", isDirectory: false)
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return string(object["model"])
    }

    /// The model id whose window applies: the configured one when it declares
    /// a larger window *and* names the same family the session is running
    /// (a session switched to another model with `/model` keeps its own).
    nonisolated static func claudeWindowModel(transcript model: String?, configured: String?) -> String? {
        guard let configured, configured.lowercased().contains("[1m]") else { return model }
        let family = configured.lowercased().replacingOccurrences(of: "[1m]", with: "")
            .split(separator: "-").first.map(String.init) ?? ""
        guard let model else { return configured }
        let id = model.lowercased()
        return family.isEmpty || id.contains(family) || family == "claude" ? configured : model
    }

    private nonisolated static func parseClaude(_ url: URL, modifiedAt: Date,
                                                 cacheModifiedAt: Date, now: Date,
                                                 configuredModel: String?) -> AgentSessionState? {
        // The newest entry carrying a session id, not literally the last line:
        // `file-history-snapshot` (and other bookkeeping records) have none and
        // are routinely appended last, which used to drop the session entirely.
        guard let facts = claudeFacts(url, modifiedAt: cacheModifiedAt), let id = facts.id else { return nil }
        let used = facts.used
        // Claude keeps each root transcript beside a directory named after that
        // session; its child transcripts live inside that directory's `subagents`.
        // The badge counts only children that are *still working*: the directory
        // keeps every child the session ever ran, so counting the folder reported
        // sub-agents in the past tense — "6" long after all six had finished.
        let subdir = url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        let children = recentFiles(subdir, now: now, predicate: { _ in true })
            .count { child in
                guard let childFacts = claudeFacts(child.url, modifiedAt: child.fileModifiedAt) else { return false }
                return !childFacts.reading
                    .resolved(inactiveFor: max(0, now.timeIntervalSince(child.modifiedAt)))
                    .isSettled
            }
        let resolvedStatus = facts.reading.resolved(inactiveFor: max(0, now.timeIntervalSince(modifiedAt)))
        let workingDirectory = facts.workingDirectory
        let model = facts.model
        // A Claude transcript never records its window, so it is derived from
        // the model id and the session's own occupancy rather than assumed.
        let window = used.map { _ in
            AgentModelContextWindow.window(for: claudeWindowModel(transcript: model, configured: configuredModel),
                                           source: .claude, observedUsed: used)
        }
        return .init(id: id, source: .claude, status: resolvedStatus,
                     contextUsed: used, contextWindow: window, subagentCount: children,
                     projectName: projectName(for: workingDirectory), modelName: model,
                     workingDirectory: workingDirectory,
                     planSummary: facts.planSummary)
    }

    /// Codex shards transcripts by calendar date. Looking in just those recent
    /// folders avoids repeatedly traversing the user's entire CLI history.
    /// Codex rollouts, by when they were last written.
    ///
    /// Delegates to `AgentTranscriptFiles` rather than computing which
    /// `YYYY/MM/DD` folders to open: a session created weeks ago and still
    /// running lives in an old folder with a current mtime, and the folder-span
    /// version could never see it. See that type for the full account.
    private nonisolated static func recentCodexFiles(_ root: URL, since: Date, now: Date) -> [AgentTranscriptFiles.Entry] {
        AgentTranscriptFiles.recent(in: root, since: since, now: now)
    }

    private nonisolated static func recentFiles(_ root: URL, now: Date, predicate: (URL) -> Bool) -> [AgentTranscriptFiles.Entry] {
        AgentTranscriptFiles.recent(
            in: root,
            since: now.addingTimeInterval(-AgentSessionObservation.activeFileWindow),
            now: now,
            matching: predicate
        )
    }
    private nonisolated static func read(_ url: URL, limit: Int, tail: Bool) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }; defer { try? handle.close() }
        if tail, let size = try? handle.seekToEnd(), size > UInt64(limit) { try? handle.seek(toOffset: size - UInt64(limit)) }
        return try? handle.readToEnd()
    }
    private nonisolated static func lines(_ data: Data) -> [[String: Any]] { String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } }
    private nonisolated static func string(_ value: Any?) -> String? { guard let value = value as? String else { return nil }; let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines); return trimmed.isEmpty ? nil : trimmed }
    private nonisolated static func projectName(for workingDirectory: String?) -> String? {
        guard let workingDirectory else { return nil }
        let name = (workingDirectory as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }
    private nonisolated static func number(_ value: Any?) -> Int? { if let value = value as? Int { return value }; return (value as? NSNumber)?.intValue }
}
