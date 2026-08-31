import Foundation

/// The protocol spoken by the already-installed `notch-codex-hook.py` hook for
/// interactive Terminal Codex sessions. Its response is intentionally a small
/// object, not JSON-RPC: the hook prints it directly to Codex's stdout.
public struct CodexTerminalHookRequest: Equatable, Sendable {
    public let approval: AgentApproval

    public static func decode(_ data: Data) -> CodexTerminalHookRequest? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["source"] as? String == "codex",
              object["action"] as? String == "gate",
              let sessionID = nonEmpty(object["session_id"])
                ?? nonEmpty(object["thread_id"])
                ?? nonEmpty(object["threadId"])
        else { return nil }

        let detail = nonEmpty(object["detail"])
        let tool = nonEmpty(object["tool_name"]) ?? "tool"
        return CodexTerminalHookRequest(
            approval: AgentApproval(
                id: "terminal-codex:\(sessionID):\(UUID().uuidString)",
                threadID: sessionID,
                itemID: tool,
                title: detail ?? "Run \(tool)",
                detail: nonEmpty(object["reason"]) ?? nonEmpty(object["cwd"]),
                workingDirectory: nonEmpty(object["cwd"]),
                source: .codex))
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public enum CodexTerminalHookDecision: Sendable { case approve, deny }

public enum CodexTerminalHookResponse {
    public static func line(for decision: CodexTerminalHookDecision) -> String {
        switch decision {
        case .approve:
            return "{\"behavior\":\"allow\"}"
        case .deny:
            return "{\"behavior\":\"deny\",\"message\":\"Denied by the user in NotchFlow.\"}"
        }
    }
}
