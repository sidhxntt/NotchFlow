import Foundation
import AppKit

@MainActor
extension AgentTaskManager {
    /// NotchFlow observes the CLIs' persisted JSONL streams instead of owning
    /// their permission buttons. Do the same for active Codex/Claude sessions:
    /// a tool with no matching result after the reference delay is surfaced to
    /// the dedicated Agent tab.
    func scanExternalApprovalSessions() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots: [(URL, AgentEngine)] = [
            (home.appendingPathComponent(".codex/sessions"), .codex),
            (home.appendingPathComponent(".claude/projects"), .claude),
        ]
        let cutoff = Date().addingTimeInterval(-300)
        let fm = FileManager.default

        for (root, engine) in roots where fm.fileExists(atPath: root.path) {
            let enumerator = fm.enumerator(at: root,
                                           includingPropertiesForKeys: [.contentModificationDateKey],
                                           options: [.skipsHiddenFiles])
            while let file = enumerator?.nextObject() as? URL {
                guard file.pathExtension == "jsonl",
                      let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                      (values.contentModificationDate ?? .distantPast) >= cutoff else { continue }
                ingestExternalSession(file: file, engine: engine)
            }
        }
        refreshExternalApprovals()
    }

    private func ingestExternalSession(file: URL, engine: AgentEngine) {
        let path = file.path
        guard let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        let offset = externalReadOffsets[path] ?? 0
        let size = (try? handle.seekToEnd()) ?? 0
        guard size >= offset else {
            externalReadOffsets[path] = 0
            return
        }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? nil
        externalReadOffsets[path] = size
        guard let data, !data.isEmpty,
              let text = String(data: data, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            ingestExternalEvent(json, from: file, engine: engine)
        }
    }

    private func ingestExternalEvent(_ json: [String: Any], from file: URL, engine: AgentEngine) {
        let path = file.path
        let type = json["type"] as? String
        let payload = json["payload"] as? [String: Any]
        if type == "session_meta", let payload {
            let folder = URL(fileURLWithPath: payload["cwd"] as? String ?? file.deletingLastPathComponent().path)
            externalSessionInfo[path] = (folder, (payload["id"] as? String) ?? (payload["session_id"] as? String))
            return
        }
        let info = externalSessionInfo[path] ?? (file.deletingLastPathComponent(), nil)

        func start(_ id: String, _ tool: String) {
            let normalizedTool: String
            if engine == .codex {
                switch tool.lowercased() {
                case "exec", "shell", "commandexecution", "command_execution":
                    normalizedTool = "Bash"
                case "apply_patch", "write_file":
                    normalizedTool = "Edit"
                default:
                    normalizedTool = tool
                }
            } else {
                normalizedTool = tool
            }
            guard AgentPermissionPolicy.needsTerminalHandoff(forToolName: normalizedTool,
                                                             elapsed: AgentPermissionPolicy.delay) else { return }
            externalTrackedTools["\(path)#\(id)"] = ExternalTrackedTool(engine: engine,
                                                                            toolName: normalizedTool,
                                                                            folder: info.folder,
                                                                            sessionID: info.sessionID,
                                                                            startedAt: Date())
        }
        func finish(_ id: String) { externalTrackedTools.removeValue(forKey: "\(path)#\(id)") }

        if engine == .codex, let payload {
            if type == "response_item", let itemType = payload["type"] as? String {
                if itemType == "function_call", let id = (payload["call_id"] as? String) ?? (payload["id"] as? String) {
                    start(id, payload["name"] as? String ?? "Bash")
                } else if itemType == "function_call_output", let id = payload["call_id"] as? String {
                    finish(id)
                } else if itemType == "custom_tool_call", let id = (payload["call_id"] as? String) ?? (payload["id"] as? String) {
                    // A custom tool call is recorded as \"completed\" as soon as Codex
                    // submits it for approval. The subsequent custom_tool_call_output is
                    // the authoritative completion event.
                    start(id, payload["name"] as? String ?? "Bash")
                } else if itemType == "custom_tool_call_output", let id = payload["call_id"] as? String {
                    finish(id)
                }
            }
            if type == "event_msg", let item = payload["item"] as? [String: Any],
               let id = item["id"] as? String {
                if payload["type"] as? String == "item_completed" { finish(id) }
                else if payload["type"] as? String == "item_started",
                        item["type"] as? String == "CommandExecution" { start(id, "Bash") }
            }
        }

        if engine == .claude, let message = json["message"] as? [String: Any],
           let content = message["content"] as? [[String: Any]] {
            for item in content {
                if item["type"] as? String == "tool_use", let id = item["id"] as? String {
                    start(id, item["name"] as? String ?? "")
                } else if item["type"] as? String == "tool_result", let id = item["tool_use_id"] as? String {
                    finish(id)
                }
            }
        }
    }

    private func refreshExternalApprovals() {
        let now = Date()
        externalApprovals = externalTrackedTools.compactMap { key, tool in
            guard AgentPermissionPolicy.needsTerminalHandoff(forToolName: tool.toolName,
                                                             elapsed: max(0, now.timeIntervalSince(tool.startedAt))) else { return nil }
            return ExternalApproval(id: key, engine: tool.engine, toolName: tool.toolName,
                                    folder: tool.folder, sessionID: tool.sessionID, startedAt: tool.startedAt)
        }.sorted { $0.startedAt > $1.startedAt }
    }

    #if DEBUG
    /// TEMP debug: seed N settled agent cards so the immersive Recent list renders
    /// its agent status rows without a live CLI. Remove after diagnosing.
    func _debugSeedSettled(_ n: Int) {
        let engine = AgentEngine.available.first ?? .codex
        for i in 0..<n {
            var t = AgentTask(engine: engine,
                              folder: URL(fileURLWithPath: "/tmp/demo-project"),
                              prompt: "Demo agent task \(i + 1) — implement the thing",
                              startedAt: Date())
            t.finishedAt = Date()
            t.outcome = .success
            t.result = "done"
            t.exchanges = [.init(prompt: "Demo agent task \(i + 1)", answer: "done")]
            tasks.append(t)
        }
    }

    /// TEMP debug: seed one LIVE (running) card — a fixed activity line and a
    /// clock already minutes in — so the running status row and the resting
    /// notch's busy ears can be screenshotted without a real CLI run. Never
    /// persisted (running tasks only archive on settle); a normal relaunch
    /// clears it. Used by the `NOTCH_DEMO_AGENT_RUN` env path in `AppDelegate`.
    func _debugSeedRunning(prompt: String, activity: String, elapsed: TimeInterval,
                           logLines: Int = 0) {
        let engine = AgentEngine.available.first ?? .codex
        var t = AgentTask(engine: engine,
                          folder: URL(fileURLWithPath: "/tmp/demo-project"),
                          prompt: prompt,
                          startedAt: Date().addingTimeInterval(-elapsed))
        t.activity = activity
        // Optional dense work trail (NOTCH_DEMO_AGENT_LOG=<n>) so the live
        // detail page can be exercised/screenshotted at realistic size — a
        // repeating prose → commands → edit pattern, some rows with output.
        if logLines > 0 {
            t.log = (0..<logLines).map { i in
                switch i % 6 {
                case 0: return AgentLogEntry(id: UUID(), title: "Looking at the failing test to understand the assertion before touching the implementation.", mono: false)
                case 1: return AgentLogEntry(id: UUID(), title: "$ swift test --filter NotchModelTests", mono: true,
                                             detail: "Test Suite 'NotchModelTests' passed.\n Executed 12 tests, with 0 failures.")
                case 2: return AgentLogEntry(id: UUID(), title: "Read NotchModel.swift", mono: true)
                case 3: return AgentLogEntry(id: UUID(), title: "Editing NotchModel.swift", mono: true)
                case 4: return AgentLogEntry(id: UUID(), title: "$ git diff --stat", mono: true,
                                             detail: " NotchModel.swift | 24 ++++++++-----\n 1 file changed")
                default: return AgentLogEntry(id: UUID(), title: "Searching hover collapse", mono: true)
                }
            }
        }
        tasks.append(t)
    }
    #endif

    func taskIndex(_ id: UUID) -> Int? {
        tasks.firstIndex { $0.id == id }
    }
}
