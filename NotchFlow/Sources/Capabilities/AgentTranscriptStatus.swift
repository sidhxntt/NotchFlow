import Foundation

/// What one scan of a CLI transcript concluded about a session: the activity it
/// was last seen doing, and whether that turn has since settled.
///
/// The two halves stay separate because they answer different questions and are
/// discovered by different evidence. `activity` is "plan mode or ordinary work",
/// read from mode transitions; `terminal` is "did this turn end, and how", read
/// from the tail of the log. `AgentSessionStatus.resolved(terminal:)` folds them
/// into the single status the Agent tab and the folded notch present.
public struct AgentTranscriptReading: Equatable, Sendable {
    public let activity: AgentSessionStatus
    public let terminal: AgentSessionTerminal?

    public init(activity: AgentSessionStatus, terminal: AgentSessionTerminal?) {
        self.activity = activity
        self.terminal = terminal
    }

    public var status: AgentSessionStatus { activity.resolved(terminal: terminal) }
}

/// Reads session status out of a Claude Code JSONL transcript.
///
/// Split out of the scanner and kept free of Foundation file APIs so every rule
/// below is exercised by unit tests against real recorded transcript shapes —
/// the previous inline version silently matched nothing and left every Claude
/// session reading "Working" forever.
public enum ClaudeTranscriptStatus {

    /// Only these entry kinds say anything about whether a turn is still under
    /// way. A Claude transcript interleaves a lot of bookkeeping — `attachment`,
    /// `ai-title`, `last-prompt`, `mode`, `permission-mode`,
    /// `file-history-snapshot`, `queue-operation` — and those records keep being
    /// appended *after* a turn has finished. Judging the turn by the literal
    /// last line therefore never sees the completion marker.
    private enum TurnSignal: Equatable {
        /// An assistant message that ended with a tool call: the tool result is
        /// still outstanding, so the turn is mid-flight.
        case assistantAwaitingTool
        /// An assistant message with no pending tool call — the model's answer.
        case assistantAnswer
        /// A prompt or a tool result. Either way the model owes a reply.
        case userTurn
        /// The user pressed escape. Recorded as a user message with this exact
        /// text, so it is only meaningful while it is the newest signal.
        case userInterrupted
        /// `system` / `turn_duration` or `stop_hook_summary`.
        case turnEnded
    }

    private static let interruptionMarker = "[Request interrupted by user]"

    public static func reading(in data: Data) -> AgentTranscriptReading {
        reading(in: entries(in: data))
    }

    public static func reading(in entries: [[String: Any]]) -> AgentTranscriptReading {
        AgentTranscriptReading(activity: activity(in: entries), terminal: terminal(in: entries))
    }

    /// The session id, taken from the newest entry that carries one. Not every
    /// record does — `file-history-snapshot` in particular has none, and it is
    /// frequently the very last line — so reading only the last entry drops the
    /// whole session from the roster.
    public static func sessionID(in entries: [[String: Any]]) -> String? {
        entries.reversed().lazy.compactMap { nonEmpty($0["sessionId"]) ?? nonEmpty($0["session_id"]) }.first
    }

    /// The model actually serving the session. `<synthetic>` is Claude Code's
    /// placeholder on locally generated messages and is not a model the user
    /// would recognise, so it never becomes the label.
    public static func modelName(in entries: [[String: Any]]) -> String? {
        entries.reversed().lazy.compactMap { item -> String? in
            let name = nonEmpty(item["model"])
                ?? (item["message"] as? [String: Any]).flatMap { nonEmpty($0["model"]) }
            guard let name, !name.hasPrefix("<") else { return nil }
            return name
        }.first
    }

    /// The plan the session is presenting, from the newest `ExitPlanMode` call.
    ///
    /// The marker hook cannot supply this — it reads `command`/`file_path`/
    /// `description` off the tool input, and `ExitPlanMode` has none of those —
    /// so the transcript is the only source. It also means the plan shows for
    /// externally started sessions, which no hook covers.
    ///
    /// Codex has no equivalent: its plan mode leaves only a `collaboration_mode`
    /// flag, and `thread_goal_updated.objective` is the user's own prompt rather
    /// than anything the agent proposed.
    public static func planSummary(in entries: [[String: Any]]) -> String? {
        for item in entries.reversed() {
            guard item["type"] as? String == "assistant",
                  let message = item["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            for block in content.reversed()
            where block["type"] as? String == "tool_use" && block["name"] as? String == "ExitPlanMode" {
                guard let input = block["input"] as? [String: Any],
                      let plan = input["plan"] as? String else { continue }
                return condense(plan)
            }
        }
        return nil
    }

    /// A plan is multi-line markdown and the card has two lines. Strip the
    /// syntax that carries no meaning once the structure is gone — headings,
    /// bullets, numbering — and flow the remaining prose into one sentence-like
    /// line, so the row shows the plan's substance rather than a lone "## Plan".
    static func condense(_ plan: String, limit: Int = 220) -> String? {
        let flowed = plan
            .split(separator: "\n")
            .map { line -> String in
                var text = line.trimmingCharacters(in: .whitespaces)
                while let first = text.first, "#>-*•".contains(first) {
                    text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
                }
                // A leading "1." / "2)" is list syntax in exactly the same way.
                if let dot = text.firstIndex(where: { $0 == "." || $0 == ")" }),
                   text[text.startIndex..<dot].allSatisfy(\.isNumber),
                   dot > text.startIndex {
                    text = String(text[text.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
                }
                return text
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")

        guard !flowed.isEmpty else { return nil }
        guard flowed.count > limit else { return flowed }
        return String(flowed.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Plan mode, from the transitions Claude Code actually records.
    ///
    /// Claude has no `enter_plan_mode` tool: entering plan mode is a
    /// `{"type":"permission-mode","permissionMode":"plan"}` record, and leaving
    /// it is the next `permission-mode` record naming a different mode. The
    /// `ExitPlanMode` **tool call** (PascalCase — there is no `exit_plan_mode`)
    /// is the other way a plan finishes, when the user accepts the plan.
    private static func activity(in entries: [[String: Any]]) -> AgentSessionStatus {
        var planning = false
        var state: AgentSessionStatus = .working

        for item in entries {
            switch item["type"] as? String {
            case "permission-mode":
                let mode = nonEmpty(item["permissionMode"]) ?? nonEmpty(item["permission_mode"])
                if mode == "plan" {
                    planning = true
                    state = .planning
                } else if planning {
                    // Plan mode switched off: a finished plan, which keeps its
                    // own completed presentation (a yellow check) rather than
                    // collapsing into an ordinary green completion.
                    planning = false
                    state = .planReady
                }
            case "assistant":
                guard toolNames(in: item).contains("ExitPlanMode") else { continue }
                planning = false
                state = .planReady
            default:
                continue
            }
        }
        return state
    }

    /// Whether the newest turn has settled. Read from the last entry that says
    /// anything about the turn, ignoring the bookkeeping records appended after
    /// it.
    private static func terminal(in entries: [[String: Any]]) -> AgentSessionTerminal? {
        guard let signal = entries.reversed().lazy.compactMap(turnSignal).first else { return nil }
        return AgentSessionTerminal.inferred(
            completed: signal == .turnEnded || signal == .assistantAnswer,
            aborted: signal == .userInterrupted,
            inactiveFor: 0)
    }

    private static func turnSignal(_ item: [String: Any]) -> TurnSignal? {
        switch item["type"] as? String {
        case "assistant":
            return toolNames(in: item).isEmpty ? .assistantAnswer : .assistantAwaitingTool
        case "user":
            return containsInterruption(item) ? .userInterrupted : .userTurn
        case "system":
            let subtype = item["subtype"] as? String
            return ["turn_duration", "stop_hook_summary"].contains(subtype ?? "") ? .turnEnded : nil
        default:
            return nil
        }
    }

    private static func toolNames(in item: [String: Any]) -> [String] {
        guard let message = item["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return [] }
        return content.compactMap { block in
            block["type"] as? String == "tool_use" ? block["name"] as? String : nil
        }
    }

    private static func containsInterruption(_ item: [String: Any]) -> Bool {
        guard let message = item["message"] as? [String: Any] else { return false }
        if let text = message["content"] as? String { return text.contains(interruptionMarker) }
        guard let content = message["content"] as? [[String: Any]] else { return false }
        return content.contains { block in
            (block["text"] as? String)?.contains(interruptionMarker) == true
        }
    }

    public static func entries(in data: Data) -> [[String: Any]] {
        String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Reads turn-terminal events out of a Codex rollout transcript.
///
/// Codex nests both events one level down, inside an `event_msg` envelope:
/// `{"type":"event_msg","payload":{"type":"turn_aborted", …}}`. Matching them on
/// the envelope's own `type` — as the scanner previously did for `turn_aborted`
/// — never fires, so a cancelled Codex turn could not reach the Closed state.
/// Who a Codex rollout belongs to: its own id, and its parent when it is a
/// spawned sub-agent rather than a session the user started.
public struct CodexSessionIdentity: Equatable, Sendable {
    public let id: String
    public let parentID: String?
    public let isSubagent: Bool

    public init(id: String, parentID: String?, isSubagent: Bool) {
        self.id = id
        self.parentID = parentID
        self.isSubagent = isSubagent
    }
}

public enum CodexTranscriptStatus {

    /// Reads a rollout's identity out of its `session_meta` payload.
    ///
    /// Two traps here, both of which the scanner previously fell into and both
    /// of which fail silently rather than loudly.
    ///
    /// **`source` is not a flag.** On a sub-agent rollout it is a nested object,
    /// `{"subagent": {"thread_spawn": {"parent_thread_id": …, "depth": 1, …}}}`,
    /// and on a user-started one it is the bare string `"cli"`, `"vscode"` or
    /// `"exec"`. Reading it as `Bool` therefore matched nothing at all — 0 of 192
    /// real rollouts — which left the session hierarchy permanently empty: no
    /// sub-agent badge ever appeared, and a child's approval never joined its
    /// parent's row. `thread_source` is the direct answer where present.
    ///
    /// **`session_id` is not the rollout's own id.** On a sub-agent it holds the
    /// *parent's* id, while `id` holds the child's. Preferring `session_id`
    /// therefore gave every concurrent sibling the same identifier, which
    /// collides in the roster's `ForEach`. `id` is the session's own in both
    /// shapes, so it is the one to trust.
    public static func identity(in meta: [String: Any]) -> CodexSessionIdentity? {
        guard let id = nonEmpty(meta["id"]) ?? nonEmpty(meta["session_id"]) else { return nil }

        let spawn = (meta["source"] as? [String: Any])?["subagent"] as? [String: Any]
        let isSubagent = nonEmpty(meta["thread_source"]) == "subagent" || spawn != nil

        // The top-level link is present on every real child, but the same value
        // is repeated inside the spawn record; read both so a rollout that
        // carries only the nested form still joins its parent.
        let parentID = nonEmpty(meta["parent_thread_id"])
            ?? (spawn?["thread_spawn"] as? [String: Any]).flatMap { nonEmpty($0["parent_thread_id"]) }
            ?? (isSubagent ? nonEmpty(meta["session_id"]).flatMap { $0 == id ? nil : $0 } : nil)

        return CodexSessionIdentity(id: id, parentID: parentID, isSubagent: isSubagent)
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Only the newest turn counts. A rollout keeps every previous turn's
    /// `task_complete`, so scanning the whole tail would report a freshly
    /// started turn as already finished.
    public static func activeTurn(in entries: [[String: Any]]) -> [[String: Any]] {
        guard let start = entries.lastIndex(where: { $0["type"] as? String == "turn_context" })
        else { return entries }
        return Array(entries[start...])
    }

    public static func terminal(in entries: [[String: Any]]) -> AgentSessionTerminal? {
        let turn = activeTurn(in: entries)
        return AgentSessionTerminal.inferred(
            completed: turn.contains { event($0, is: "task_complete") },
            aborted: turn.contains { event($0, is: "turn_aborted") },
            inactiveFor: 0)
    }

    /// Plan mode, from the newest two distinct `collaboration_mode` values.
    public static func activity(in entries: [[String: Any]]) -> AgentSessionStatus {
        let modes = entries.compactMap { item -> String? in
            guard item["type"] as? String == "turn_context",
                  let payload = item["payload"] as? [String: Any],
                  let collaboration = payload["collaboration_mode"] as? [String: Any] else { return nil }
            return collaboration["mode"] as? String
        }
        if modes.last == "plan" { return .planning }
        if modes.last != nil, modes.dropLast().last == "plan" { return .planReady }
        return .working
    }

    public static func reading(in entries: [[String: Any]]) -> AgentTranscriptReading {
        AgentTranscriptReading(activity: activity(in: entries), terminal: terminal(in: entries))
    }

    private static func event(_ item: [String: Any], is kind: String) -> Bool {
        guard item["type"] as? String == "event_msg",
              let payload = item["payload"] as? [String: Any] else { return false }
        return payload["type"] as? String == kind
    }
}
