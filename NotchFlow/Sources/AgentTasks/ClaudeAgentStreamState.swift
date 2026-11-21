import Foundation
import AppKit

/// The **claude** dialect (`claude -p --output-format stream-json`). Assistant
/// events carry content blocks — `text` (narration; the last one is the
/// candidate report) and `tool_use` (the work trail: Bash commands, Edit/Write
/// file changes, web lookups). The final `result` event is authoritative for
/// both the report text and failure.
final class ClaudeAgentStreamState: AgentEventParser {
    private let lock = NSLock()
    private var buffer = Data()
    private var stderrTail = ""
    private var finalMessage = ""
    private var failure: String?
    private var sawTerminal = false
    /// tool_use id → the log entry it opened, so the matching `tool_result`
    /// (a later `user` event) can attach the tool's output to it.
    private var openEntries: [String: UUID] = [:]
    /// The message currently streaming, one slot per Anthropic `content_block`
    /// index — so `--include-partial-messages` grows the paragraph in place and
    /// the closing `assistant` event corrects it rather than printing it twice.
    private var stream = StreamingBlocks()
    /// What each streaming block index is (text vs thinking), learned from
    /// `content_block_start` and needed by its deltas.
    private var blockKinds: [Int: AgentLogEntry.Kind] = [:]
    /// The single plan row, rewritten in place on every `TodoWrite`.
    private var planEntry: UUID?

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
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = obj["type"] as? String
            else { continue }
            switch type {
            case "stream_event":
                // The token-level half of the stream (`--include-partial-messages`).
                // Raw Anthropic SSE: `content_block_start` says what block index
                // N is, its deltas grow it, and the `assistant` event below hands
                // over the authoritative whole text once the message closes.
                guard let event = obj["event"] as? [String: Any],
                      let kind = event["type"] as? String else { continue }
                switch kind {
                case "message_start":
                    // A fresh index space. Anything still open belonged to a
                    // message that never reported — keep what it streamed, just
                    // stop writing into it.
                    stream.closeAll()
                    blockKinds.removeAll()
                case "content_block_start":
                    let index = event["index"] as? Int ?? 0
                    switch (event["content_block"] as? [String: Any])?["type"] as? String {
                    case "text":     blockKinds[index] = .plain
                    case "thinking": blockKinds[index] = .thinking
                    default:         blockKinds[index] = nil   // tool_use: not streamed
                    }
                case "content_block_delta":
                    let index = event["index"] as? Int ?? 0
                    guard let delta = event["delta"] as? [String: Any] else { continue }
                    let text: String?
                    switch delta["type"] as? String {
                    case "text_delta":     text = delta["text"] as? String
                    case "thinking_delta": text = delta["thinking"] as? String
                    default:               text = nil     // signature / input_json
                    }
                    guard let text, !text.isEmpty else { continue }
                    stream.append(text, slot: index,
                                  kind: blockKinds[index] ?? .plain, into: &progress)
                    progress.activity = stream.ticker(index)
                    any = true
                default:
                    break   // content_block_stop / message_delta / message_stop
                }
            case "assistant":
                guard let message = obj["message"] as? [String: Any],
                      let content = message["content"] as? [[String: Any]] else { continue }
                // Each API call reports its own usage — a live context-window
                // read while the run streams (the result event refines it), and
                // the run's real token cost for Stats. Only the per-call events
                // are metered; the closing `result` total covers the same calls
                // and would double them.
                if let usage = message["usage"] as? [String: Any] {
                    AnthropicUsage.record(usage, provider: "Claude")
                    if let used = Self.contextTokens(usage) {
                        progress.contextUsed = used
                        any = true
                    }
                }
                for (index, block) in content.enumerated() {
                    switch block["type"] as? String {
                    case "text":
                        // Interim narration; the last text before the result is
                        // the fallback report if the result event lacks one.
                        // Each is also a narration entry in the work trail —
                        // `replace` CORRECTS the one the deltas above already
                        // built (or creates it, on a CLI that streams no
                        // partials), so the paragraph is never printed twice.
                        if let text = block["text"] as? String, !text.isEmpty {
                            finalMessage = text
                            stream.replace(text, slot: index, kind: .plain, into: &progress)
                            any = true
                        }
                    case "thinking":
                        if let text = block["thinking"] as? String, !text.isEmpty {
                            stream.replace(text, slot: index, kind: .thinking, into: &progress)
                            any = true
                        }
                    case "tool_use":
                        guard let name = block["name"] as? String else { continue }
                        let input = block["input"] as? [String: Any] ?? [:]
                        // The plan is not a row in the trail — it's ONE row that
                        // keeps being rewritten, wherever it first appeared.
                        if name == "TodoWrite" {
                            let items = Self.todos(input["todos"])
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
                            // Deliberately NOT registered in `openEntries`: the
                            // tool's "Todos have been modified" result would
                            // overwrite the checklist we just encoded.
                            any = true
                            continue
                        }
                        // Every tool call gets a work-trail entry; the handful
                        // below also drive the collapsed activity ticker and the
                        // changed-files summary, same as before.
                        var entryTitle = name
                        var entryKind = AgentLogEntry.Kind.plain
                        var entryDetail: String? = nil
                        switch name {
                        case "Bash":
                            if let cmd = input["command"] as? String, !cmd.isEmpty {
                                progress.activity = "$ " + String(cmd.prefix(80))
                                entryTitle = "$ " + String(cmd.prefix(200))
                                any = true
                            }
                        case "Edit", "Write", "MultiEdit", "NotebookEdit":
                            if let path = input["file_path"] as? String {
                                let file = (path as NSString).lastPathComponent
                                progress.changedFiles.append(file)
                                // The call's own arguments ARE the patch — the
                                // before/after text the model chose to write.
                                // Drawn here rather than waiting for the tool
                                // result, which only says "the file was updated".
                                let patch = Self.patch(tool: name, input: input)
                                let base = (name == "Write" ? "Creating " : "Editing ") + file
                                progress.activity = base
                                entryTitle = AgentDiff.title(base, patch: patch)
                                if !patch.isEmpty {
                                    entryKind = .diff
                                    entryDetail = patch
                                }
                                any = true
                            }
                        case "WebSearch":
                            if let query = input["query"] as? String, !query.isEmpty {
                                progress.activity = "Searching " + String(query.prefix(60))
                                entryTitle = "Searching " + String(query.prefix(200))
                                any = true
                            }
                        case "WebFetch":
                            if let url = input["url"] as? String, !url.isEmpty {
                                progress.activity = "Reading " + String(url.prefix(60))
                                entryTitle = "Reading " + String(url.prefix(200))
                                any = true
                            }
                        case "Read", "Grep", "Glob":
                            // Quieter reads — not on the ticker, but part of the
                            // trail. Title = tool + its primary input.
                            let arg = (input["file_path"] as? String)
                                .map { ($0 as NSString).lastPathComponent }
                                ?? (input["pattern"] as? String)
                                ?? ""
                            entryTitle = arg.isEmpty ? name : "\(name) \(String(arg.prefix(120)))"
                        default:
                            break
                        }
                        let entry = AgentLogEntry(id: UUID(), title: entryTitle, mono: true,
                                                  detail: entryDetail, kind: entryKind)
                        if let useID = block["id"] as? String { openEntries[useID] = entry.id }
                        progress.entries.append(entry)
                        any = true
                    default:
                        break
                    }
                }
                // The message is closed: every block it streamed has now been
                // corrected by its authoritative copy above, so the next
                // message's blocks start fresh slots.
                stream.closeAll()
                blockKinds.removeAll()
            case "user":
                // Tool results ride back as `user` events — attach each output
                // to the entry its tool_use opened.
                guard let message = obj["message"] as? [String: Any],
                      let content = message["content"] as? [[String: Any]] else { continue }
                for block in content where block["type"] as? String == "tool_result" {
                    guard let useID = block["tool_use_id"] as? String,
                          let entryID = openEntries.removeValue(forKey: useID) else { continue }
                    progress.completedEntries.append(entryID)
                    let text = Self.resultText(block["content"])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        progress.details.append((entryID, String(text.prefix(2000)),
                                                 (block["is_error"] as? Bool) == true))
                        any = true
                    }
                }
            case "system":
                // The init event names the model the session resolved to (a full
                // id like `claude-opus-4-8-…`, even when the run rode the user's
                // CLI default) — the detail's info line reports it. It also
                // carries the session id follow-ups resume; --resume forks a
                // fresh id per round, so every round re-captures it here.
                if obj["subtype"] as? String == "init" {
                    if let model = obj["model"] as? String, !model.isEmpty {
                        progress.model = model
                        any = true
                    }
                    if let session = obj["session_id"] as? String, !session.isEmpty {
                        progress.sessionID = session
                        any = true
                    }
                }
            case "result":
                sawTerminal = true
                if (obj["is_error"] as? Bool) == true {
                    failure = (obj["result"] as? String)
                        ?? (obj["subtype"] as? String)
                        ?? "unknown error"
                } else if let text = obj["result"] as? String, !text.isEmpty {
                    finalMessage = text
                }
                // The run's authoritative token accounting: `usage` totals the
                // final request, `modelUsage` names each model's window.
                if let usage = obj["usage"] as? [String: Any],
                   let used = Self.contextTokens(usage) {
                    progress.contextUsed = used
                    any = true
                }
                if let modelUsage = obj["modelUsage"] as? [String: Any] {
                    let window = modelUsage.values
                        .compactMap { ($0 as? [String: Any])?["contextWindow"] as? Int }
                        .max()
                    if let window, window > 0 {
                        progress.contextWindow = window
                        any = true
                    }
                }
            default:
                break   // stream_event, rate_limit_event, …
            }
        }
        return any
    }

    /// Context-window occupancy from an Anthropic `usage` dict: the request's
    /// fresh input plus everything read/written through the prompt cache —
    /// i.e. the conversation the model actually saw this turn.
    private static func contextTokens(_ usage: [String: Any]) -> Int? {
        guard let input = usage["input_tokens"] as? Int else { return nil }
        let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
        let cacheCreation = usage["cache_creation_input_tokens"] as? Int ?? 0
        return input + cacheRead + cacheCreation
    }

    /// The patch a file-editing call is about to apply, from its own arguments.
    /// Empty when the tool carries no before/after text (an argument shape we
    /// don't know), in which case the row stays a plain "Editing …" line.
    private static func patch(tool: String, input: [String: Any]) -> String {
        switch tool {
        case "Edit":
            let old = input["old_string"] as? String ?? ""
            let new = input["new_string"] as? String ?? ""
            guard !old.isEmpty || !new.isEmpty else { return "" }
            return AgentDiff.replacement(old: old, new: new)
        case "MultiEdit":
            let edits = input["edits"] as? [[String: Any]] ?? []
            return AgentDiff.combined(edits.map {
                AgentDiff.replacement(old: $0["old_string"] as? String ?? "",
                                      new: $0["new_string"] as? String ?? "")
            })
        case "Write":
            return AgentDiff.addition(input["content"] as? String ?? "")
        case "NotebookEdit":
            return AgentDiff.addition(input["new_source"] as? String ?? "")
        default:
            return ""
        }
    }

    /// `TodoWrite`'s `todos` array → the plan row's items.
    private static func todos(_ raw: Any?) -> [(text: String, status: AgentTodo.Status)] {
        (raw as? [[String: Any]] ?? []).compactMap { item in
            guard let text = (item["content"] as? String) ?? (item["activeForm"] as? String),
                  !text.isEmpty else { return nil }
            switch item["status"] as? String {
            case "completed":   return (text, .done)
            case "in_progress": return (text, .active)
            default:            return (text, .pending)
            }
        }
    }

    /// A tool_result's `content` is either a plain string or an array of blocks
    /// (text blocks for tool output, image blocks for screenshots). Distill the
    /// text.
    private static func resultText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks
            .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined(separator: "\n")
    }

    func appendStderr(_ data: Data) {
        guard let s = String(data: data, encoding: .utf8) else { return }
        lock.lock(); defer { lock.unlock() }
        stderrTail += s
        if stderrTail.count > 2000 { stderrTail = String(stderrTail.suffix(2000)) }
    }

    func finish() -> AgentSnapshot {
        lock.lock(); defer { lock.unlock() }
        // Same residue flush as the codex parser: a final unterminated line is
        // exactly where the `result` event would be.
        if !buffer.isEmpty {
            buffer.append(0x0A)
            var residue = AgentProgress()
            _ = drainLines(into: &residue)
        }
        let tail = stderrTail
            .split(separator: "\n")
            .map(String.init)
            .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            ?? ""
        return AgentSnapshot(finalMessage: finalMessage, failure: failure,
                             stderrTail: tail, sawTerminal: sawTerminal)
    }
}
