import Foundation
import AppKit

/// The **Command Code** dialect (`cmd -p --output-format json`). The richest of the
/// four: every agent event is forwarded as its own `{"type":"event","event":{…}}`
/// frame, so the full work trail is available — `tool_running` opens an entry,
/// `tool_completed` attaches its output, `model_request_*` names the model and the
/// turn's token usage, `run_start` hands over the session id `cmd --resume`
/// continues. The stream closes with one `{"type":"result",…}` line whose
/// `finalText` is authoritative for the report and whose `subtype` decides
/// success/failure.
final class CommandCodeAgentStreamState: AgentEventParser {
    private let lock = NSLock()
    private var buffer = Data()
    private var stderrTail = ""
    private var finalMessage = ""
    private var streamedText = ""
    private var failure: String?
    private var sawTerminal = false
    /// toolCallId → the log entry it opened, so `tool_completed` can attach the
    /// tool's output to the entry `tool_running` created.
    private var openEntries: [String: UUID] = [:]
    /// toolCallId → tool name, so a completion knows what it completed (an error or
    /// denial event may not carry the name).
    private var openTools: [String: String] = [:]
    /// The narration and the reasoning, grown from their `*_delta` events. A tool
    /// call ends the current paragraph (see `tool_running`), so the trail reads as
    /// prose · work · prose rather than one running block.
    private var stream = StreamingBlocks()
    /// The single plan row, rewritten in place on every `todo_write`.
    private var planEntry: UUID?

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
            case "event":
                guard let event = obj["event"] as? [String: Any] else { continue }
                if ingest(event: event, into: &progress) { any = true }
            case "result":
                sawTerminal = true
                if let sid = obj["sessionId"] as? String, !sid.isEmpty {
                    progress.sessionID = sid
                    any = true
                }
                if let usage = obj["usage"] as? [String: Any],
                   let input = usage["inputTokens"] as? Int, input > 0 {
                    progress.contextUsed = input
                    any = true
                }
                if let text = obj["finalText"] as? String, !text.isEmpty {
                    finalMessage = text
                }
                if (obj["subtype"] as? String) == "error" {
                    failure = (obj["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                        ?? "unknown error"
                }
                // `finalText` is authoritative — it replaces the paragraph the
                // deltas built (creating it, if the run streamed none), so the
                // trail's last narration is exactly the answer shown beneath it.
                let report = finalMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                if !report.isEmpty {
                    stream.replace(report, slot: StreamingBlocks.narration,
                                   kind: .plain, into: &progress)
                    any = true
                }
                stream.closeAll()
            default:
                break
            }
        }
        return any
    }

    /// One `AgentEvent` frame. Returns whether it moved anything user-visible.
    private func ingest(event: [String: Any], into progress: inout AgentProgress) -> Bool {
        guard let type = event["type"] as? String else { return false }
        switch type {
        case "run_start":
            // The handle `cmd --resume` continues from — emitted up front, so a
            // follow-up stays possible even if the round is later interrupted.
            guard let sid = event["sessionId"] as? String, !sid.isEmpty else { return false }
            progress.sessionID = sid
            return true
        case "model_request_start":
            guard let model = event["model"] as? String, !model.isEmpty else { return false }
            progress.model = model
            return true
        case "model_request_end":
            // `inputTokens` is the request's full prompt = what the turn occupied of
            // the context window (the same semantic codex's `input_tokens` carries).
            guard let usage = event["usage"] as? [String: Any],
                  let input = usage["inputTokens"] as? Int, input > 0 else { return false }
            progress.contextUsed = input
            // One event per model call — summing them gives the run's real token
            // cost for Stats. (camelCase keys here; this dialect is its own.)
            TokenMeter.shared.record(input: input,
                                     output: usage["outputTokens"] as? Int ?? 0,
                                     provider: "Command Code")
            return true
        case "text_delta":
            guard let delta = event["delta"] as? String, !delta.isEmpty else { return false }
            streamedText += delta
            // The paragraph grows in the trail as it's written, and its tail
            // rolls through the ticker so the collapsed card shows motion
            // between tool calls.
            stream.close(StreamingBlocks.thinking)
            stream.append(delta, slot: StreamingBlocks.narration,
                          kind: .plain, into: &progress)
            progress.activity = stream.ticker(StreamingBlocks.narration)
            return true
        case "thinking_start", "thinking_delta":
            if let delta = event["delta"] as? String, !delta.isEmpty {
                stream.close(StreamingBlocks.narration)
                stream.append(delta, slot: StreamingBlocks.thinking,
                              kind: .thinking, into: &progress)
            }
            progress.activity = L("agent.thinking")
            return true
        case "tool_running":
            guard let id = event["toolCallId"] as? String,
                  let name = event["toolName"] as? String else { return false }
            openTools[id] = name
            // A tool call closes whatever prose was being written: the next
            // paragraph is a new thought, not a continuation of this one.
            stream.closeAll()
            // The plan is ONE row, rewritten wherever it first appeared.
            let items = name == "todo_write" ? Self.todos(in: event) : []
            if !items.isEmpty {
                let encoded = AgentTodo.encode(items)
                if let planEntry {
                    progress.rewrites.append((planEntry, AgentTodo.title(items), encoded))
                } else {
                    let entry = AgentLogEntry(id: UUID(), title: AgentTodo.title(items),
                                              mono: false, detail: encoded, kind: .todo)
                    planEntry = entry.id
                    progress.entries.append(entry)
                }
                return true
            }
            let title = Self.title(tool: name, description: event["description"] as? String)
            progress.activity = String(title.prefix(80))
            if openEntries[id] == nil {
                // A write / edit carries the text it's about to apply — draw it.
                let patch = Self.patch(tool: name, input: event["input"])
                let entry = AgentLogEntry(
                    id: UUID(),
                    title: AgentDiff.title(String(title.prefix(200)), patch: patch),
                    mono: Self.isMono(tool: name),
                    detail: patch.isEmpty ? nil : patch,
                    kind: patch.isEmpty ? .plain : .diff)
                openEntries[id] = entry.id
                progress.entries.append(entry)
            }
            return true
        case "tool_completed":
            guard let id = event["toolCallId"] as? String else { return false }
            let name = (event["toolName"] as? String) ?? openTools[id] ?? ""
            openTools[id] = nil
            // A write / edit is a changed file — what the run's summary counts.
            if ["write_file", "edit_file"].contains(name), let path = Self.path(in: event) {
                progress.changedFiles.append((path as NSString).lastPathComponent)
            }
            guard let entryID = openEntries.removeValue(forKey: id) else { return true }
            progress.completedEntries.append(entryID)
            let output = Self.text(inResultOf: event["result"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !output.isEmpty {
                progress.details.append((entryID, String(output.suffix(2000)), false))
            }
            return true
        case "tool_errored", "tool_denied":
            guard let id = event["toolCallId"] as? String else { return false }
            openTools[id] = nil
            guard let entryID = openEntries.removeValue(forKey: id) else { return true }
            progress.completedEntries.append(entryID)
            guard let detail = event["error"] as? String, !detail.isEmpty else { return true }
            // A failed call replaces whatever the row was showing — including a
            // patch drawn from arguments the tool then refused.
            progress.details.append((entryID, String(detail.suffix(2000)), true))
            return true
        case "run_error":
            sawTerminal = true
            failure = (event["error"] as? String)
                ?? ((event["error"] as? [String: Any])?["message"] as? String)
                ?? "unknown error"
            return false
        default:
            return false   // turn_start / message_update / subagent_* / …
        }
    }

    /// The work-trail title for a tool call. The CLI composes its own one-line
    /// `description` for each call ("Read src/App.swift", "npm test") — that is the
    /// best label available; the tool name is the fallback when it sends none.
    private static func title(tool: String, description: String?) -> String {
        let d = (description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard d.isEmpty else {
            return ["shell_command", "powershell"].contains(tool) ? "$ " + d : d
        }
        return tool
    }

    /// Terminal-ish entries (commands, files, searches) render monospaced; the
    /// conversational tools read as prose. Mirrors the codex/claude parsers.
    private static func isMono(tool: String) -> Bool {
        !["ask_user_question", "todo_write", "enter_plan_mode", "exit_plan_mode"]
            .contains(tool)
    }

    /// The patch a write/edit is about to apply, when the call's input carries the
    /// before/after text. Command Code's tool arguments follow the same shape
    /// Claude's do; an input we can't read leaves the row a plain line.
    private static func patch(tool: String, input: Any?) -> String {
        guard ["edit_file", "write_file"].contains(tool),
              let input = input as? [String: Any] else { return "" }
        func str(_ dict: [String: Any], _ keys: [String]) -> String {
            for k in keys { if let v = dict[k] as? String, !v.isEmpty { return v } }
            return ""
        }
        let oldKeys = ["old_string", "oldText", "old_text", "old"]
        let newKeys = ["new_string", "newText", "new_text", "new"]
        // A batched edit (an `edits` array) is the shape both pi and Claude's
        // MultiEdit use; a single replacement sits at the top level.
        if let edits = input["edits"] as? [[String: Any]], !edits.isEmpty {
            return AgentDiff.combined(edits.map {
                AgentDiff.replacement(old: str($0, oldKeys), new: str($0, newKeys))
            })
        }
        let old = str(input, oldKeys)
        let new = str(input, newKeys)
        if !old.isEmpty || !new.isEmpty { return AgentDiff.replacement(old: old, new: new) }
        return AgentDiff.addition(str(input, ["content", "text"]))
    }

    /// The plan items a `todo_write` call carries, whichever of the two key
    /// shapes it uses.
    private static func todos(in event: [String: Any]) -> [(text: String, status: AgentTodo.Status)] {
        guard let input = event["input"] as? [String: Any] else { return [] }
        let raw = (input["todos"] as? [[String: Any]]) ?? (input["items"] as? [[String: Any]]) ?? []
        return raw.compactMap { item in
            guard let text = (item["content"] as? String) ?? (item["text"] as? String),
                  !text.isEmpty else { return nil }
            switch item["status"] as? String {
            case "completed":   return (text, .done)
            case "in_progress": return (text, .active)
            default:
                return (text, (item["completed"] as? Bool) == true ? .done : .pending)
            }
        }
    }

    /// The file a write/edit touched, from the call's own input when the event
    /// carries it back.
    private static func path(in event: [String: Any]) -> String? {
        guard let input = event["input"] as? [String: Any],
              let p = (input["file_path"] as? String) ?? (input["path"] as? String),
              !p.isEmpty
        else { return nil }
        return p
    }

    /// Flatten a tool result's content blocks (`[{"type":"text","text":…}]`) into one
    /// string; a bare string result passes through.
    private static func text(inResultOf result: Any?) -> String {
        if let s = result as? String { return s }
        guard let blocks = result as? [[String: Any]] else { return "" }
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
        // The result line is the LAST line, so a stream killed mid-flush leaves it
        // unterminated in the buffer — terminate it and give it one final parse.
        if !buffer.isEmpty {
            buffer.append(0x0A)
            var residue = AgentProgress()
            _ = drainLines(into: &residue)
        }
        // A run cut short before its result line still has whatever it streamed.
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
