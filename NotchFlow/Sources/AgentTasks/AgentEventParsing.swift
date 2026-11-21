import Foundation
import AppKit

// MARK: - Stream parsing (thread-safe)

/// One batch of progress parsed out of newly-arrived JSONL data.
struct AgentProgress {
    var activity: String?
    /// The model id the CLI reports for this session, once it says so.
    var model: String?
    /// The CLI's conversation handle (claude session_id / codex thread_id).
    var sessionID: String?
    /// Context-window occupancy after the latest turn, and the window size,
    /// when the round's usage events carry them.
    var contextUsed: Int?
    var contextWindow: Int?
    var changedFiles: [String] = []
    /// New work-trail entries, in stream order.
    var entries: [AgentLogEntry] = []
    /// Text appended to an entry ALREADY in the trail — the token deltas of a
    /// block that is still being written (`StreamingBlocks`).
    var appends: [(id: UUID, text: String)] = []
    /// Whole-text replacement for an entry already in the trail: the CLI's own
    /// authoritative copy of a block its deltas built, a dialect that sends
    /// cumulative snapshots instead of deltas, or a plan being rewritten.
    var rewrites: [(id: UUID, title: String, detail: String?)] = []
    /// Late-arriving outputs for earlier entries, keyed by entry id. `isError`
    /// marks a tool that FAILED — the one case allowed to overwrite a row that
    /// owns its own detail (a diff we drew from arguments the tool then
    /// rejected must not keep reading as an applied edit).
    var details: [(id: UUID, detail: String, isError: Bool)] = []
    /// Tool completion is meaningful even when it produced no stdout. Keeping
    /// it separately prevents a quiet successful command from being mistaken
    /// for an unresolved permission prompt five seconds later.
    var completedEntries: [UUID] = []
}

/// The delta-to-entry bookkeeping every engine needs once it streams: the first
/// chunk of a block opens a work-trail entry, later chunks grow it in place, and
/// the CLI's own whole copy (when one arrives) replaces what the chunks built.
///
/// `slot` is the engine's own block index — Anthropic's `content_block` index
/// for claude, the two constants below for the single-channel dialects, which
/// only ever have one narration and one reasoning block open at a time.
struct StreamingBlocks {
    static let narration = 0
    static let thinking = 1

    private var open: [Int: UUID] = [:]
    /// Everything each open slot has accumulated — the ticker's source, and what
    /// tells `replace` whether there's anything to correct.
    private var text: [Int: String] = [:]

    func isOpen(_ slot: Int) -> Bool { open[slot] != nil }
    func accumulated(_ slot: Int) -> String { text[slot] ?? "" }

    /// One delta. Opens the slot's entry on first sight, appends after.
    mutating func append(_ delta: String, slot: Int, kind: AgentLogEntry.Kind,
                         into progress: inout AgentProgress) {
        guard !delta.isEmpty else { return }
        text[slot, default: ""] += delta
        if let id = open[slot] {
            progress.appends.append((id, delta))
        } else {
            let entry = AgentLogEntry(id: UUID(), title: delta, mono: false, kind: kind)
            open[slot] = entry.id
            progress.entries.append(entry)
        }
    }

    /// The slot's whole text at once — the shape codex sends (cumulative
    /// snapshots rather than deltas) and the correction claude's `assistant`
    /// event carries for a block its `stream_event`s already built. Opens the
    /// entry if nothing streamed, so a CLI that emits no deltas at all still
    /// lands one entry per block.
    mutating func replace(_ whole: String, slot: Int, kind: AgentLogEntry.Kind,
                          into progress: inout AgentProgress) {
        guard !whole.isEmpty else { return }
        text[slot] = whole
        if let id = open[slot] {
            progress.rewrites.append((id, whole, nil))
        } else {
            let entry = AgentLogEntry(id: UUID(), title: whole, mono: false, kind: kind)
            open[slot] = entry.id
            progress.entries.append(entry)
        }
    }

    /// Seal a slot — the next delta starts a fresh entry.
    mutating func close(_ slot: Int) {
        open[slot] = nil
        text[slot] = nil
    }

    mutating func closeAll() {
        open.removeAll()
        text.removeAll()
    }

    /// The rolling one-line ticker for a slot: the tail of what it has written,
    /// so the collapsed card shows the words arriving rather than a static
    /// "Thinking…". Falls back to that phrase before the first token lands.
    func ticker(_ slot: Int) -> String {
        let flat = accumulated(slot)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return flat.isEmpty ? L("agent.thinking") : String(flat.suffix(80))
    }
}

/// A finished run's distilled output.
struct AgentSnapshot {
    let finalMessage: String
    let failure: String?
    let stderrTail: String
    /// Whether the stream reached its own terminal event (claude's `result`,
    /// codex's `turn.completed`/`turn.failed`/`error`). False means the
    /// process died before concluding — recovery uses this to tell a finished
    /// run from one that was killed out from under the app.
    let sawTerminal: Bool
}

/// What the manager needs from an engine's JSONL dialect: progress while running,
/// a snapshot at the end. One conforming parser per `AgentEngine`.
protocol AgentEventParser: AnyObject {
    func ingest(_ data: Data) -> AgentProgress?
    func appendStderr(_ data: Data)
    func finish() -> AgentSnapshot
}
