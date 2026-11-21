import Foundation
import AppKit

/// The **grok** dialect (`grok --prompt-file … --output-format streaming-json`).
/// Deliberately the thinnest of the three parsers, because grok's headless
/// streaming-json surfaces only `text` (answer deltas), `thought` (reasoning
/// deltas) and a terminal `end` — NO per-tool events, even when the run edits
/// files or runs commands (verified). So there is no fine-grained work trail to
/// build: the ticker shows the report streaming (or "Thinking…" during
/// reasoning), and the whole report lands as one narration entry at `end`. The
/// full per-command / per-file trail would need grok's ACP mode (`grok agent
/// stdio`), a bidirectional JSON-RPC protocol incompatible with this subsystem's
/// file-tailing, survive-app-quit design. The `end` event carries `sessionId`
/// (what `grok --resume` continues) and `stopReason`; no token usage is emitted,
/// so the context meter stays blank for grok.
final class GrokAgentStreamState: AgentEventParser {
    private let lock = NSLock()
    private var buffer = Data()
    private var stderrTail = ""
    private var finalMessage = ""
    private var failure: String?
    private var sawTerminal = false
    /// The report and the reasoning, grown from their deltas. grok has no tool
    /// events at all, so the narration slot stays open for the whole run — its
    /// entry is therefore always the complete report, which is what lets the
    /// detail page drop it in favour of the answer printed beneath.
    private var stream = StreamingBlocks()

    func ingest(_ data: Data) -> AgentProgress? {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        var progress = AgentProgress()
        return drainLines(into: &progress) ? progress : nil
    }

    /// Parse every complete (newline-terminated) line into `progress`. Caller
    /// holds the lock.
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
            case "text":
                if let t = obj["data"] as? String, !t.isEmpty {
                    finalMessage += t
                    // The report grows in the trail as it's written, and its tail
                    // rolls through the ticker so the collapsed card shows motion
                    // even without a tool trail.
                    stream.append(t, slot: StreamingBlocks.narration,
                                  kind: .plain, into: &progress)
                    progress.activity = stream.ticker(StreamingBlocks.narration)
                    any = true
                }
            case "thought":
                // Reasoning deltas ride the same `data` field the answer does.
                // They grow the folded "Thinking" row in the trail only — the
                // ticker holds the calm phrase (see the codex parser).
                if let t = obj["data"] as? String, !t.isEmpty {
                    stream.append(t, slot: StreamingBlocks.thinking,
                                  kind: .thinking, into: &progress)
                }
                progress.activity = L("agent.thinking")
                any = true
            case "end":
                sawTerminal = true
                if let sid = obj["sessionId"] as? String, !sid.isEmpty {
                    progress.sessionID = sid
                    any = true
                }
                // The turn's token accounting, when the `end` event carries it:
                // `input_tokens` is the request's full prompt = what the turn
                // occupied of the context window (same semantic as codex's).
                if let usage = obj["usage"] as? [String: Any],
                   let input = usage["input_tokens"] as? Int, input > 0 {
                    progress.contextUsed = input
                    TokenMeter.shared.record(input: input,
                                             output: usage["output_tokens"] as? Int ?? 0,
                                             provider: "Grok")
                    any = true
                }
                let report = finalMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                // A terminal stopReason that names an error, with no report, is a
                // failure worth surfacing.
                if report.isEmpty, let reason = obj["stopReason"] as? String {
                    let r = reason.lowercased()
                    if r.contains("error") || r.contains("refus") || r.contains("cancel") {
                        failure = reason
                    }
                }
                // The report is already in the trail — the deltas above built it.
                stream.closeAll()
            case "error":
                sawTerminal = true
                failure = (obj["message"] as? String)
                    ?? (obj["data"] as? String)
                    ?? (obj["error"] as? String)
                    ?? "unknown error"
            default:
                break   // any other event types
            }
        }
        return any
    }

    func appendStderr(_ data: Data) {
        guard let s = String(data: data, encoding: .utf8) else { return }
        lock.lock(); defer { lock.unlock() }
        stderrTail += s
        if stderrTail.count > 2000 { stderrTail = String(stderrTail.suffix(2000)) }
    }

    func finish() -> AgentSnapshot {
        lock.lock(); defer { lock.unlock() }
        // A last line the stream never newline-terminated (the `end` event, if
        // the process was killed mid-flush) still gets one parse.
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
