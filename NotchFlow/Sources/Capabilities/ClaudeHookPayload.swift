import Foundation

/// One Claude Code `PreToolUse` hook payload, decoded into exactly the fields the
/// notch card needs to ask an honest question.
///
/// Claude Code has no long-lived approval channel like Codex's app-server. Its
/// permission extension point is a **hook**: for every matched tool call the CLI
/// spawns a short-lived command, hands it this JSON on stdin, and takes the
/// command's stdout as the decision. `ClaudeHookBridge` runs the socket that the
/// hook process talks to; everything in this file is the pure part — JSON in,
/// approval model out — so it can be tested without a socket.
///
/// Shape verified against Claude Code 2.1.226:
/// ```json
/// { "session_id": "…", "transcript_path": "…", "cwd": "/private/tmp/x",
///   "prompt_id": "…", "permission_mode": "acceptEdits",
///   "hook_event_name": "PreToolUse", "tool_name": "Bash",
///   "tool_input": { "command": "echo hi", "description": "Echo" },
///   "tool_use_id": "toolu_01…" }
/// ```
public struct ClaudeHookRequest: Equatable, Sendable {
    /// The per-session queue key — Claude's `session_id`, the analog of a Codex
    /// `threadId`.
    public let sessionID: String
    /// Identifies this one tool call; the id the decision is routed back on.
    public let toolUseID: String
    public let toolName: String
    /// Claude places sub-agent transcripts below the owning root session's
    /// directory. Retaining this path lets a child permission join that root's
    /// one safe FIFO approval row instead of appearing as a separate agent.
    public let transcriptPath: String?
    public let cwd: String?
    /// `tool_input.command` — Bash only.
    public let command: String?
    /// `tool_input.description` — Bash's own one-line summary, when present.
    public let commandDescription: String?
    /// `tool_input.file_path` / `notebook_path` — the edit/write tools.
    public let filePath: String?

    public init(sessionID: String, toolUseID: String, toolName: String,
                transcriptPath: String? = nil,
                cwd: String? = nil, command: String? = nil,
                commandDescription: String? = nil, filePath: String? = nil) {
        self.sessionID = sessionID
        self.toolUseID = toolUseID
        self.toolName = toolName
        self.transcriptPath = transcriptPath
        self.cwd = cwd
        self.command = command
        self.commandDescription = commandDescription
        self.filePath = filePath
    }

    /// Decode one hook payload. Returns nil for anything that isn't a usable
    /// `PreToolUse` request — a payload with no session or no tool_use_id cannot
    /// be queued OR answered, so there is nothing honest to show for it.
    public static func decode(_ data: Data) -> ClaudeHookRequest? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return decode(object)
    }

    public static func decode(_ object: [String: Any]) -> ClaudeHookRequest? {
        guard let sessionID = nonEmpty(object["session_id"])
                ?? nonEmpty(object["sessionId"])
                ?? nonEmpty(object["thread_id"])
                ?? nonEmpty(object["threadId"]),
              let toolUseID = nonEmpty(object["tool_use_id"])
                ?? nonEmpty(object["toolUseId"]),
              let toolName = nonEmpty(object["tool_name"])
        else { return nil }
        // Only PreToolUse asks a question. Any other event reaching the socket is
        // a misconfiguration, and answering it with a permission decision would
        // be nonsense.
        if let event = nonEmpty(object["hook_event_name"]), event != "PreToolUse" { return nil }

        let input = object["tool_input"] as? [String: Any] ?? [:]
        return ClaudeHookRequest(
            sessionID: sessionID,
            toolUseID: toolUseID,
            toolName: toolName,
            transcriptPath: nonEmpty(object["transcript_path"]),
            cwd: nonEmpty(object["cwd"]),
            command: nonEmpty(input["command"]),
            commandDescription: nonEmpty(input["description"]),
            filePath: nonEmpty(input["file_path"]) ?? nonEmpty(input["notebook_path"])
        )
    }

    /// A child transcript is stored at `<root-id>/subagents/<child>.jsonl`.
    /// A root transcript (or an unfamiliar future path) stays independent —
    /// merging uncertain sessions would be less safe than showing an extra row.
    public var rootSessionID: String {
        guard let transcriptPath, !transcriptPath.isEmpty else { return sessionID }
        let transcript = URL(fileURLWithPath: transcriptPath)
        let subagentsDirectory = transcript.deletingLastPathComponent()
        guard subagentsDirectory.lastPathComponent == "subagents" else { return sessionID }
        let rootID = subagentsDirectory.deletingLastPathComponent().lastPathComponent
        return rootID.isEmpty ? sessionID : rootID
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The card's headline. For Bash this is the command **verbatim** (whitespace
    /// collapsed so a heredoc doesn't blow the one-line row out) — the user is
    /// being asked to authorize that exact string, so a paraphrase would be a
    /// lie. For the file tools it is the verb plus the file's own name; the full
    /// path rides `detail` underneath.
    public var title: String {
        if let command, !command.isEmpty { return Self.collapseWhitespace(command) }
        if let filePath {
            let name = (filePath as NSString).lastPathComponent
            switch toolName {
            case "Write":        return "Write \(name)"
            case "Edit":         return "Edit \(name)"
            case "NotebookEdit": return "Edit notebook \(name)"
            default:             return "\(toolName) \(name)"
            }
        }
        return "Run \(toolName)"
    }

    /// The orange sub-line: the model's own description of a command, or the full
    /// path an edit targets, falling back to where the session is working.
    public var detail: String? {
        if command != nil { return commandDescription ?? cwd }
        if let filePath { return filePath }
        return commandDescription ?? cwd
    }

    /// The queue entry for this request. `id` defaults to the `tool_use_id`, which
    /// is unique per tool call; `idOverride` exists only for the pathological case
    /// where one is somehow already pending (see `ClaudeHookBridge`), because the
    /// queue dedupes on id and a silently-dropped request would hang its hook.
    public func approval(idOverride: String? = nil) -> AgentApproval {
        AgentApproval(id: idOverride ?? toolUseID,
                      threadID: sessionID,
                      itemID: toolUseID,
                      title: title,
                      detail: detail,
                      workingDirectory: cwd,
                      source: .claude,
                      sessionGroupID: rootSessionID)
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// The two answers a `PreToolUse` hook may give. Verified against Claude Code
/// 2.1.226: `deny` blocks the call ("Command blocked. Host denied: <reason>"),
/// `allow` runs it without any further prompt.
public enum ClaudeHookDecision: String, Sendable {
    case allow
    case deny
}

/// Builds the single line of stdout the hook process prints as its decision.
public enum ClaudeHookResponse {
    /// The exact contract Claude Code reads back:
    /// `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":…,"permissionDecisionReason":…}}`
    /// The reason is surfaced to the model verbatim, so it says who decided.
    public static func line(_ decision: ClaudeHookDecision, reason: String) -> String {
        let payload: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": decision.rawValue,
                "permissionDecisionReason": reason
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            // Unreachable for this fixed shape, but a hook that prints nothing
            // fails OPEN rather than wedging the run — the same posture as the
            // hook script's own error paths.
            return ""
        }
        return json
    }

    public static func line(for decision: ClaudeHookDecision) -> String {
        line(decision, reason: decision == .allow
             ? "Approved by the user in NotchFlow."
             : "Denied by the user in NotchFlow.")
    }
}
