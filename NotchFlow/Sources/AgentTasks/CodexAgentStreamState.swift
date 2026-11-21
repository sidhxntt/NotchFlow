import Foundation
import AppKit

/// The **codex** dialect (`codex exec --json`). Line-buffers stdout and distills
/// it into progress + a final snapshot. Lock-guarded: the readability and
/// termination handlers fire on different queues. Mirrors `StreamState` in
/// `CodexCLIService`, but where the chat only wants `agent_message` text, the
/// agent wants the *work trail* too: commands run, files changed, the report.
final class CodexAgentStreamState: AgentEventParser {
    private let lock = NSLock()
    private var buffer = Data()
    private var stderrTail = ""
    private var finalMessage = ""
    private var failure: String?
    private var sawTerminal = false
    /// codex item id → the log entry it opened, so `item.completed` can attach
    /// the command's output to the entry `item.started` created.
    private var openEntries: [String: UUID] = [:]
    /// The report and the reasoning as they're written. codex sends each
    /// `item.updated` with the block's text SO FAR (a snapshot, not a delta), so
    /// these ride `replace` rather than `append`.
    private var stream = StreamingBlocks()
    /// The single plan row, rewritten in place every time codex re-emits its
    /// todo list — a trail that grew one row per revision buried the work.
    private var planEntry: UUID?

    /// Append `data`, parse complete JSONL lines, and return the progress they
    /// carry (nil when nothing user-visible changed).
    func ingest(_ data: Data) -> AgentProgress? {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        var progress = AgentProgress()
        return drainLines(into: &progress) ? progress : nil
    }

    /// Parse every complete (newline-terminated) line in `buffer` into
    /// `progress`. Caller holds the lock.
    private func drainLines(into progress: inout AgentProgress) -> Bool {
        var any = false
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            else { continue }
            // Whichever event carries it (the thread/session one, depending on
            // the codex build), the model the session resolved to — including
            // when the run rode the user's own CLI default and we passed no flag.
            if progress.model == nil,
               let model = (obj["model"] as? String)
                ?? ((obj["msg"] as? [String: Any])?["model"] as? String) {
                progress.model = model
                any = true
            }
            guard let type = obj["type"] as? String else { continue }
            switch type {
            case "thread.started":
                // The conversation handle `codex exec resume` continues from.
                if let threadID = obj["thread_id"] as? String, !threadID.isEmpty {
                    progress.sessionID = threadID
                    any = true
                }
            case "turn.completed":
                sawTerminal = true
                // Per-turn token accounting. `input_tokens` is the request's
                // full prompt (cached_input_tokens is a subset of it, not
                // additive) = what the turn occupied of the context window, and
                // with the output side the turn's real cost for Stats.
                if let usage = obj["usage"] as? [String: Any],
                   let input = usage["input_tokens"] as? Int {
                    progress.contextUsed = input
                    TokenMeter.shared.record(input: input,
                                             output: usage["output_tokens"] as? Int ?? 0,
                                             provider: "Codex")
                    any = true
                }
                // Opportunistic: some codex builds name the window too.
                if let window = (obj["model_context_window"] as? Int)
                    ?? ((obj["usage"] as? [String: Any])?["model_context_window"] as? Int),
                   window > 0 {
                    progress.contextWindow = window
                    any = true
                }
            case "item.started", "item.updated", "item.completed":
                guard let item = obj["item"] as? [String: Any],
                      let itemType = item["type"] as? String else { continue }
                let itemID = item["id"] as? String
                switch itemType {
                case "agent_message":
                    // Codex may emit interim messages; the last one is the report.
                    // Each is also a narration entry in the work trail — grown in
                    // place from the `item.updated` snapshots so the paragraph is
                    // seen being written, then sealed by `item.completed`.
                    let text = item["text"] as? String ?? ""
                    if !text.isEmpty {
                        stream.close(StreamingBlocks.thinking)
                        finalMessage = text
                        stream.replace(text, slot: StreamingBlocks.narration,
                                       kind: .plain, into: &progress)
                        progress.activity = stream.ticker(StreamingBlocks.narration)
                        any = true
                    }
                    if type == "item.completed" { stream.close(StreamingBlocks.narration) }
                case "command_execution":
                    if let cmd = item["command"] as? String, !cmd.isEmpty {
                        progress.activity = "$ " + String(cmd.prefix(80))
                        any = true
                        // One log entry per item, opened on first sight; the
                        // completed event attaches the command's output to it.
                        if let itemID, openEntries[itemID] == nil {
                            let entry = AgentLogEntry(
                                id: UUID(), title: "$ " + String(cmd.prefix(200)), mono: true)
                            openEntries[itemID] = entry.id
                            progress.entries.append(entry)
                        }
                        if type == "item.completed", let itemID,
                           let entryID = openEntries.removeValue(forKey: itemID) {
                            progress.completedEntries.append(entryID)
                            let out = (item["aggregated_output"] as? String ?? "")
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            if !out.isEmpty {
                                progress.details.append((entryID, String(out.suffix(2000)), false))
                            }
                        }
                    }
                case "file_change":
                    // `changes: [{path, kind}]` — collect names for the summary
                    // and surface the latest as the activity line. The completed
                    // event's final list is what goes in the work trail. codex
                    // sends no before/after text (so no patch to draw), but it
                    // does say WHICH of the three things it did — the verb is
                    // the honest half of a diff we can show.
                    if let changes = item["changes"] as? [[String: Any]] {
                        for change in changes {
                            guard let path = change["path"] as? String else { continue }
                            let name = (path as NSString).lastPathComponent
                            let title = Self.verb(change["kind"] as? String) + name
                            progress.changedFiles.append(name)
                            progress.activity = title
                            any = true
                            if type == "item.completed" {
                                progress.entries.append(AgentLogEntry(
                                    id: UUID(), title: title, mono: true))
                            }
                        }
                    }
                case "todo_list":
                    // The plan, re-emitted in full on every revision — one row,
                    // rewritten in place (see `planEntry`).
                    let items = (item["items"] as? [[String: Any]] ?? []).compactMap {
                        i -> (text: String, status: AgentTodo.Status)? in
                        guard let text = (i["text"] as? String) ?? (i["title"] as? String),
                              !text.isEmpty else { return nil }
                        return (text, (i["completed"] as? Bool) == true ? .done : .pending)
                    }
                    guard !items.isEmpty else { continue }
                    let encoded = AgentTodo.encode(items)
                    if let planEntry {
                        progress.rewrites.append((planEntry, AgentTodo.title(items), encoded))
                    } else {
                        let entry = AgentLogEntry(id: UUID(), title: AgentTodo.title(items),
                                                  mono: false, detail: encoded, kind: .todo)
                        planEntry = entry.id
                        progress.entries.append(entry)
                    }
                    any = true
                case "web_search":
                    if let query = item["query"] as? String, !query.isEmpty {
                        progress.activity = "Searching " + String(query.prefix(60))
                        any = true
                        if let itemID, openEntries[itemID] == nil {
                            let entry = AgentLogEntry(
                                id: UUID(), title: "Searching " + String(query.prefix(200)), mono: true)
                            openEntries[itemID] = entry.id
                            progress.entries.append(entry)
                        }
                    }
                case "reasoning":
                    // The reasoning summary codex writes between tool calls.
                    // It goes in the trail, folded behind a "Thinking" line —
                    // and nowhere else: the ticker stays the calm "Thinking…"
                    // rather than sliding raw half-sentences of reasoning past
                    // the reader.
                    let text = (item["text"] as? String)
                        ?? (item["summary"] as? [String])?.joined(separator: "\n")
                        ?? ""
                    if !text.isEmpty {
                        stream.close(StreamingBlocks.narration)
                        stream.replace(text, slot: StreamingBlocks.thinking,
                                       kind: .thinking, into: &progress)
                    }
                    progress.activity = L("agent.thinking")
                    any = true
                    if type == "item.completed" { stream.close(StreamingBlocks.thinking) }
                default:
                    break
                }
            case "error":
                sawTerminal = true
                if let msg = obj["message"] as? String { failure = msg }
            case "turn.failed":
                sawTerminal = true
                if let err = obj["error"] as? [String: Any],
                   let msg = err["message"] as? String { failure = msg }
            default:
                break
            }
        }
        return any
    }

    /// The row's verb for a `file_change` kind — the one thing codex tells us
    /// about the shape of the edit. Unknown kinds read as an edit.
    private static func verb(_ kind: String?) -> String {
        switch kind?.lowercased() {
        case "add", "added", "create", "created": return "Creating "
        case "delete", "deleted", "remove", "removed": return "Deleting "
        default: return "Editing "
        }
    }

    func appendStderr(_ data: Data) {
        guard let s = String(data: data, encoding: .utf8) else { return }
        lock.lock(); defer { lock.unlock() }
        stderrTail += s
        if stderrTail.count > 2000 { stderrTail = String(stderrTail.suffix(2000)) }
    }

    func finish() -> AgentSnapshot {
        lock.lock(); defer { lock.unlock() }
        // A last line the stream never newline-terminated would sit in the
        // buffer unparsed — and the LAST line is exactly where the result event
        // lives. Terminate it and give it one final parse (into a discarded
        // progress: only the snapshot fields matter now).
        if !buffer.isEmpty {
            buffer.append(0x0A)
            var residue = AgentProgress()
            _ = drainLines(into: &residue)
        }
        let lines = stderrTail
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let last = lines.last ?? ""
        // clap ends parse failures with this generic hint. Keep the actual
        // `error: ...` line instead, so a future CLI incompatibility is visible.
        let tail = last.hasPrefix("For more information, try")
            ? (lines.last(where: { $0.hasPrefix("error:") }) ?? last)
            : last
        return AgentSnapshot(finalMessage: finalMessage, failure: failure,
                             stderrTail: tail, sawTerminal: sawTerminal)
    }
}
