import Foundation

/// The protocol spoken by the already-installed `notchflow-codex-hook.py` hook for
/// interactive Terminal Codex sessions. Its response is intentionally a small
/// object, not JSON-RPC: the hook prints it directly to Codex's stdout.
public struct CodexTerminalHookRequest: Equatable, Sendable {
    public let approval: AgentApproval

    public static func decode(_ data: Data) -> CodexTerminalHookRequest? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let source = object["source"] as? String,
              ["codex", "claude"].contains(source),
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
                // NotchFlow's installed Claude hook speaks this same socket
                // protocol. Treating it as unknown made the listener close its
                // connection immediately, which fails the hook open before a
                // user could ever see a card.
                source: source == "claude" ? .claude : .codex))
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

/// Finds the part of a user-owned Claude configuration that the app can repair
/// without disturbing any other hooks. Only an explicitly quoted, stale
/// NotchFlow hook path is changed; unfamiliar command shapes remain visible for
/// manual review instead of being guessed at.
public enum HookConfigurationRepair {
    public static func staleClaudeCommands(in value: Any, expectedScriptPath: String) -> [String] {
        commandStrings(in: value).filter {
            $0.contains("NotchFlow") && $0.contains("claude-hook.py") && !$0.contains(expectedScriptPath)
        }
    }

    public static func repairingStaleClaudeCommands(in value: Any,
                                                     expectedScriptPath: String) -> (value: Any, replacements: Int) {
        switch value {
        case let dictionary as [String: Any]:
            var replacements = 0
            var repaired: [String: Any] = [:]
            for (key, child) in dictionary {
                if key == "command", let command = child as? String,
                   let updated = replacingQuotedClaudeHookPath(in: command,
                                                               expectedScriptPath: expectedScriptPath) {
                    repaired[key] = updated
                    replacements += 1
                } else {
                    let childResult = repairingStaleClaudeCommands(in: child,
                                                                    expectedScriptPath: expectedScriptPath)
                    repaired[key] = childResult.value
                    replacements += childResult.replacements
                }
            }
            return (repaired, replacements)
        case let array as [Any]:
            var replacements = 0
            let repaired = array.map { child -> Any in
                let childResult = repairingStaleClaudeCommands(in: child,
                                                                expectedScriptPath: expectedScriptPath)
                replacements += childResult.replacements
                return childResult.value
            }
            return (repaired, replacements)
        default:
            return (value, 0)
        }
    }

    private static func commandStrings(in value: Any) -> [String] {
        switch value {
        case let dictionary as [String: Any]:
            return dictionary.flatMap { key, child in
                if key == "command", let command = child as? String { return [command] }
                return commandStrings(in: child)
            }
        case let array as [Any]:
            return array.flatMap(commandStrings(in:))
        default:
            return []
        }
    }

    /// A user config may chain any shell syntax around a hook. Quoting is the
    /// unambiguous boundary macOS paths with spaces need; without it the app
    /// deliberately leaves the command alone and asks the user to review it.
    private static func replacingQuotedClaudeHookPath(in command: String,
                                                       expectedScriptPath: String) -> String? {
        guard command.contains("NotchFlow"), command.contains("claude-hook.py"),
              !command.contains(expectedScriptPath),
              let notchFlow = command.range(of: "NotchFlow"),
              let hook = command.range(of: "claude-hook.py", range: notchFlow.lowerBound..<command.endIndex),
              let quoteStart = command[..<notchFlow.lowerBound].lastIndex(where: { $0 == "'" || $0 == "\"" })
        else { return nil }

        let quote = command[quoteStart]
        let afterHook = hook.upperBound..<command.endIndex
        guard let quoteEnd = command.range(of: String(quote), range: afterHook)?.lowerBound else { return nil }

        var repaired = command
        repaired.replaceSubrange(quoteStart...quoteEnd, with: "\(quote)\(expectedScriptPath)\(quote)")
        return repaired
    }
}
