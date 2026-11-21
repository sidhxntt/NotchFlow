import Foundation
import AppKit

/// The **pi** dialect (`pi -p --mode json`). Structurally the closest to Command
/// Code's — one JSON object per line, tool calls as their own frames — but the
/// events are the framework's own (`docs/json.md`): a `session` header hands over
/// the id `pi --session` continues, `tool_execution_start` / `tool_execution_end`
/// bracket each call, `message_update.assistantMessageEvent` carries the token-level
/// `text_delta` / `thinking_delta`, and each assistant `message_end` closes a model
/// call with its real usage.
///
/// The one shape it lacks is a terminal *result* line: pi ends with `agent_end` +
/// `agent_settled` and no distilled report, so the report is assembled from the
/// assistant messages' own text — and a provider refusal arrives as a `message_end`
/// whose `stopReason` is `"error"`, carrying `errorMessage`, rather than as an error
/// event of its own.
final class PiAgentStreamState: AgentEventParser {
    private let lock = NSLock()
    private var buffer = Data()
    private var stderrTail = ""
    private var finalMessage = ""
    private var streamedText = ""
    private var failure: String?
    private var sawTerminal = false
    /// toolCallId → the log entry it opened, so `tool_execution_end` can attach the
    /// tool's output to the entry `tool_execution_start` created.
    private var openEntries: [String: UUID] = [:]
    /// toolCallId → tool name, so a completion knows what it completed.
    private var openTools: [String: String] = [:]
    /// The narration and the reasoning, grown from `message_update`'s
    /// token-level deltas; `message_end` hands over the authoritative text for
    /// the paragraph they built.
    private var stream = StreamingBlocks()

    func ingest(_ data: Data) -> AgentProgress? {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        var progress = AgentProgress()
        return drainLines(into: &progress) ? progress : nil
    }

    /// Parse every complete (newline-terminated) line into `progress`. Caller holds
    /// the lock.
    private func drainLines(into progress: inout AgentProgress) -> Bool {
        var any = false
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = obj["type"] as? String
            else { continue }
            switch type {
            case "session":
                // The header line, first out of every run — the handle
                // `pi --session` continues from, available before any work starts
                // so a follow-up stays possible even if the round is interrupted.
                guard let sid = obj["id"] as? String, !sid.isEmpty else { continue }
                progress.sessionID = sid
                any = true
            case "message_start":
                guard let message = obj["message"] as? [String: Any],
                      message["role"] as? String == "assistant",
                      let model = message["model"] as? String, !model.isEmpty
                else { continue }
                // Reported as the app's own id space (`<pi-provider>/<model>`), so
                // the chip matches the row that armed it.
                if let provider = message["provider"] as? String, !provider.isEmpty {
                    progress.model = "\(provider)/\(model)"
                } else {
                    progress.model = model
                }
                any = true
            case "message_update":
                guard let event = obj["assistantMessageEvent"] as? [String: Any],
                      let kind = event["type"] as? String
                else { continue }
                switch kind {
                case "text_delta":
                    guard let delta = event["delta"] as? String, !delta.isEmpty else { continue }
                    streamedText += delta
                    // The paragraph grows in the trail as it's written, and its
                    // tail rolls through the ticker so the collapsed card shows
                    // motion between tool calls.
                    stream.close(StreamingBlocks.thinking)
                    stream.append(delta, slot: StreamingBlocks.narration,
                                  kind: .plain, into: &progress)
                    progress.activity = stream.ticker(StreamingBlocks.narration)
                    any = true
                case "thinking_start", "thinking_delta":
                    if let delta = event["delta"] as? String, !delta.isEmpty {
                        stream.close(StreamingBlocks.narration)
                        stream.append(delta, slot: StreamingBlocks.thinking,
                                      kind: .thinking, into: &progress)
                    }
                    progress.activity = L("agent.thinking")
                    any = true
                default:
                    continue   // toolcall_start / text_end / thinking_end / …
                }
            case "message_end":
                guard let message = obj["message"] as? [String: Any],
                      message["role"] as? String == "assistant"
                else { continue }
                // One `message_end` per model call, carrying that call's real usage.
                // `input` is the request's full prompt = what the turn occupied of
                // the context window (the semantic codex's `input_tokens` carries).
                if let usage = message["usage"] as? [String: Any] {
                    let input = usage["input"] as? Int ?? 0
                    let cacheRead = usage["cacheRead"] as? Int ?? 0
                    // pi reports cache hits separately from fresh input, but both
                    // occupy the window — the sum is what the meter should show.
                    if input + cacheRead > 0 {
                        progress.contextUsed = input + cacheRead
                        any = true
                    }
                    TokenMeter.shared.record(input: input,
                                             output: usage["output"] as? Int ?? 0,
                                             provider: "Pi")
                }
                // The report is the assistant's own text, whichever call produced
                // it — and it's authoritative for the paragraph the deltas built,
                // so it replaces that entry rather than adding a second copy.
                if let text = Self.text(in: message["content"]), !text.isEmpty {
                    finalMessage = text
                    stream.replace(text, slot: StreamingBlocks.narration,
                                   kind: .plain, into: &progress)
                    any = true
                }
                stream.closeAll()
                if message["stopReason"] as? String == "error" {
                    sawTerminal = true
                    failure = (message["errorMessage"] as? String)
                        .flatMap { $0.isEmpty ? nil : $0 } ?? "unknown error"
                }
            case "tool_execution_start":
                guard let id = obj["toolCallId"] as? String,
                      let name = obj["toolName"] as? String else { continue }
                openTools[id] = name
                // A tool call closes whatever prose was being written: the next
                // paragraph is a new thought, not a continuation of this one.
                stream.closeAll()
                let title = Self.title(tool: name, args: obj["args"] as? [String: Any])
                progress.activity = String(title.prefix(80))
                if openEntries[id] == nil {
                    // A write / edit carries the text it's about to apply — draw it.
                    let patch = Self.patch(tool: name, args: obj["args"])
                    let entry = AgentLogEntry(
                        id: UUID(),
                        title: AgentDiff.title(String(title.prefix(200)), patch: patch),
                        mono: true,
                        detail: patch.isEmpty ? nil : patch,
                        kind: patch.isEmpty ? .plain : .diff)
                    openEntries[id] = entry.id
                    progress.entries.append(entry)
                }
                any = true
            case "tool_execution_end":
                guard let id = obj["toolCallId"] as? String else { continue }
                let name = (obj["toolName"] as? String) ?? openTools[id] ?? ""
                openTools[id] = nil
                // A write / edit is a changed file — what the run's summary counts.
                if ["write", "edit"].contains(name), let path = Self.path(in: obj["args"]) {
                    progress.changedFiles.append((path as NSString).lastPathComponent)
                }
                any = true
                guard let entryID = openEntries.removeValue(forKey: id) else { continue }
                progress.completedEntries.append(entryID)
                let output = Self.text(inResultOf: obj["result"])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !output.isEmpty {
                    progress.details.append((entryID, String(output.suffix(2000)), false))
                }
            case "agent_end", "agent_settled":
                // pi's terminal pair. There is no distilled result line, so the
                // report is whatever the assistant last said — already in the
                // trail, put there by the deltas and corrected at `message_end`.
                sawTerminal = true
                if finalMessage.isEmpty { finalMessage = streamedText }
                stream.closeAll()
            default:
                break   // agent_start / turn_start / turn_end / queue_update / …
            }
        }
        return any
    }

    /// The work-trail title for a tool call. pi sends no prose `description` (its own
    /// UI renders each tool's arguments), so the title is composed from the one
    /// argument that names what the call is doing — the command, the path, the
    /// pattern — falling back to the bare tool name.
    private static func title(tool: String, args: [String: Any]?) -> String {
        func arg(_ keys: [String]) -> String? {
            for k in keys {
                if let v = args?[k] as? String,
                   !v.trimmingCharacters(in: .whitespaces).isEmpty { return v }
            }
            return nil
        }
        switch tool {
        case "bash":
            return "$ " + (arg(["command"]) ?? "")
        case "read", "write", "edit", "ls":
            return [tool, arg(["path", "file_path"])].compactMap { $0 }.joined(separator: " ")
        case "grep", "find":
            return [tool, arg(["pattern", "query", "regex"])]
                .compactMap { $0 }.joined(separator: " ")
        default:
            return tool
        }
    }

    /// The patch a write/edit is about to apply, from the call's own arguments.
    /// pi's `edit` carries an ARRAY of replacements (`edits: [{oldText, newText}]`,
    /// verified against the installed build) and `write` the whole file; key
    /// names are probed rather than assumed, and an unreadable shape leaves the
    /// row a plain line rather than a wrong patch.
    private static func patch(tool: String, args: Any?) -> String {
        guard ["write", "edit"].contains(tool),
              let args = args as? [String: Any] else { return "" }
        func str(_ dict: [String: Any], _ keys: [String]) -> String {
            for k in keys { if let v = dict[k] as? String, !v.isEmpty { return v } }
            return ""
        }
        let oldKeys = ["oldText", "old_string", "old_text", "old"]
        let newKeys = ["newText", "new_string", "new_text", "new"]
        if let edits = args["edits"] as? [[String: Any]], !edits.isEmpty {
            return AgentDiff.combined(edits.map {
                AgentDiff.replacement(old: str($0, oldKeys), new: str($0, newKeys))
            })
        }
        let old = str(args, oldKeys)
        let new = str(args, newKeys)
        if !old.isEmpty || !new.isEmpty { return AgentDiff.replacement(old: old, new: new) }
        return AgentDiff.addition(str(args, ["content", "text"]))
    }

    /// The file a write/edit touched, from the call's own arguments.
    private static func path(in args: Any?) -> String? {
        guard let args = args as? [String: Any],
              let p = (args["path"] as? String) ?? (args["file_path"] as? String),
              !p.isEmpty
        else { return nil }
        return p
    }

    /// Flatten an assistant message's content blocks into its answer text, dropping
    /// the `thinking` and `toolCall` blocks that share the array.
    private static func text(in content: Any?) -> String? {
        guard let blocks = content as? [[String: Any]] else { return nil }
        let parts = blocks.compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }
        return parts.isEmpty ? nil : parts.joined()
    }

    /// Flatten a tool result's content blocks (`{"content":[{"type":"text",…}]}`) into
    /// one string; a bare string result passes through.
    private static func text(inResultOf result: Any?) -> String {
        if let s = result as? String { return s }
        let blocks = (result as? [String: Any])?["content"] as? [[String: Any]]
            ?? result as? [[String: Any]]
        guard let blocks else { return "" }
        return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    func appendStderr(_ data: Data) {
        guard let s = String(data: data, encoding: .utf8) else { return }
        lock.lock(); defer { lock.unlock() }
        stderrTail += s
        if stderrTail.count > 2000 { stderrTail = String(stderrTail.suffix(2000)) }
    }

    func finish() -> AgentSnapshot {
        lock.lock(); defer { lock.unlock() }
        // A stream killed mid-flush leaves its last line unterminated in the buffer —
        // terminate it and give it one final parse.
        if !buffer.isEmpty {
            buffer.append(0x0A)
            var residue = AgentProgress()
            _ = drainLines(into: &residue)
        }
        // A run cut short before its terminal pair still has whatever it streamed.
        if finalMessage.isEmpty { finalMessage = streamedText }
        let tail = stderrTail
            .split(separator: "\n")
            .map(String.init)
            .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            ?? ""
        return AgentSnapshot(finalMessage: finalMessage, failure: failure,
                             stderrTail: tail, sawTerminal: sawTerminal)
    }
}
