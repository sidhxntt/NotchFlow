import Foundation
import AppKit

/// One step in an agent run's work trail: a tool call the agent made — the
/// input line ("$ npm test", "Editing Foo.swift", "Searching …") plus, once the tool's
/// result event lands, its output. Narration the agent emits between tool calls
/// is an entry too (`mono == false`). Feeds the task card's expandable detail
/// view; the one-line `activity` ticker stays the collapsed summary.
struct AgentLogEntry: Identifiable, Equatable, Codable {
    /// How the row is drawn. `plain` is the historical shape — a command, a file,
    /// a paragraph of narration; the rest earn a rendering of their own, and each
    /// owns its `detail` (a tool result never overwrites it — see `applyProgress`).
    enum Kind: String, Codable {
        case plain
        /// The model's own reasoning, folded away behind a "Thinking" line.
        case thinking
        /// `detail` holds a patch — drawn line-coloured (`AgentDiff`).
        case diff
        /// `detail` holds an encoded checklist — drawn as one (`AgentTodo`).
        case todo
    }

    let id: UUID
    /// The input side: command / file / query / narration text. A streaming
    /// block GROWS this in place as its deltas land, hence `var`.
    var title: String
    /// Terminal-ish entries (commands, files, queries) render monospaced;
    /// narration reads as prose.
    let mono: Bool
    /// The output side, attached when the tool's result arrives. Capped at parse.
    var detail: String? = nil
    var kind: Kind = .plain

    init(id: UUID, title: String, mono: Bool,
         detail: String? = nil, kind: Kind = .plain) {
        self.id = id
        self.title = title
        self.mono = mono
        self.detail = detail
        self.kind = kind
    }

    /// Hand-written purely for `kind`: synthesized decoding ignores a property's
    /// default value and throws on a missing key, so every record archived before
    /// this field existed would fail to decode. Absent → `.plain`, which is what
    /// those rows were.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id     = try c.decode(UUID.self, forKey: .id)
        title  = try c.decode(String.self, forKey: .title)
        mono   = try c.decode(Bool.self, forKey: .mono)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        kind   = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .plain
    }
}

extension Array where Element == AgentLogEntry {
    /// The work trail with its trailing narration entry dropped when that entry
    /// only repeats the `answer` rendered directly beneath it.
    ///
    /// The agent's final assistant message is captured twice by design: the stream
    /// parser can't tell mid-run which text block is the last, so every narration
    /// block becomes a trail entry AND the last one also becomes the round's answer
    /// (`finalMessage`). Any view that stacks the trail above the answer therefore
    /// printed the report twice. Drop it here, where both
    /// halves are known. Only a non-mono (narration) tail entry is eligible — a tool
    /// row (`mono`) is never the answer — and only when the answer begins with its
    /// (prefix-capped, whitespace-trimmed) title. Pass an empty `answer` (e.g. while
    /// the round still streams and no report shows yet) to keep the trail whole.
    func droppingTrailingAnswer(_ answer: String) -> [AgentLogEntry] {
        // Only a NARRATION tail can be the answer: a tool row (`mono`) never is,
        // and neither is a folded reasoning block or a plan, whose text could
        // otherwise coincidentally prefix-match and vanish.
        guard let last, !last.mono, last.kind == .plain else { return self }
        let title = last.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !body.isEmpty, body.hasPrefix(title) else { return self }
        return Array(dropLast())
    }
}

/// The patch a file-editing tool call is about to apply, built from the call's
/// OWN arguments (every CLI hands over the before/after text; none of them ship
/// a rendered diff). One `-`/`+` line per changed line, context dropped — the
/// work trail wants "what changed", not a reviewable hunk.
///
/// Deliberately not a real LCS diff: an Edit's `old_string`/`new_string` are
/// already the minimal region the model chose to rewrite, so line-for-line is
/// both honest and cheap. The row's own title carries the ± counts.
enum AgentDiff {
    /// Cap per patch — a whole-file `Write` can be thousands of lines, and the
    /// row is a peek, not the file.
    private static let lineCap = 400

    /// A replacement: every old line as `-`, every new line as `+`.
    static func replacement(old: String, new: String) -> String {
        lines(old, "-") + (old.isEmpty || new.isEmpty ? "" : "\n") + lines(new, "+")
    }

    /// A whole-file write: every line as `+`.
    static func addition(_ content: String) -> String { lines(content, "+") }

    /// Several replacements in one call (claude's `MultiEdit`), blank-separated.
    static func combined(_ patches: [String]) -> String {
        patches.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private static func lines(_ text: String, _ sign: String) -> String {
        guard !text.isEmpty else { return "" }
        let all = text.components(separatedBy: "\n")
        let kept = all.prefix(lineCap).map { sign + $0 }
        guard all.count > lineCap else { return kept.joined(separator: "\n") }
        return (kept + ["… \(all.count - lineCap) more lines"]).joined(separator: "\n")
    }

    /// `(+added, −removed)` for a patch this type built — what the row's title
    /// reports beside the file name.
    static func counts(_ patch: String) -> (added: Int, removed: Int) {
        var added = 0, removed = 0
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+") { added += 1 }
            else if line.hasPrefix("-") { removed += 1 }
        }
        return (added, removed)
    }

    /// "Editing Foo.swift  +12 −3" — the row title for a patch. An empty patch
    /// (a tool whose arguments didn't carry the text) keeps the bare title.
    static func title(_ base: String, patch: String) -> String {
        let (added, removed) = counts(patch)
        guard added + removed > 0 else { return base }
        var suffix = ""
        if added > 0 { suffix += "  +\(added)" }
        if removed > 0 { suffix += (added > 0 ? " " : "  ") + "−\(removed)" }
        return base + suffix
    }
}

/// The agent's own plan (claude's `TodoWrite`, codex's `todo_list`, Command
/// Code's `todo_write`), encoded into one string so it can ride an entry's
/// `detail` without widening `AgentLogEntry`'s archive shape: one item per line,
/// `[x]` done · `[>]` in progress · `[ ]` pending.
enum AgentTodo {
    enum Status: String { case done = "x", active = ">", pending = " " }

    static func encode(_ items: [(text: String, status: Status)]) -> String {
        items
            .map { "[\($0.status.rawValue)] " + $0.text.replacingOccurrences(of: "\n", with: " ") }
            .joined(separator: "\n")
    }

    static func decode(_ encoded: String) -> [(text: String, status: Status)] {
        encoded.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard line.count > 4, line.hasPrefix("[") else { return nil }
            let mark = line[line.index(line.startIndex, offsetBy: 1)]
            let status = Status(rawValue: String(mark)) ?? .pending
            return (String(line.dropFirst(4)), status)
        }
    }

    /// "Plan · 2/7" — the row's headline, so a folded plan still reports progress.
    static func title(_ items: [(text: String, status: Status)]) -> String {
        L("agent.trail.plan", items.filter { $0.status == .done }.count, items.count)
    }
}
