import SwiftUI
import AppKit
import Combine
import PDFKit
import ImageIO

// MARK: - Agent work trail

/// The transcript of an agent run's work, in the CLI apps' own display grammar:
/// narration the agent wrote between tool calls reads as prose; the tool calls
/// BETWEEN two narrations fold into one summary row ("4 commands · 2 file
/// edits") that expands to the individual calls — each of which expands again
/// to the output it captured. Folded by default so a busy run reads as a story,
/// not a wall of terminal lines. Shared by the live agent detail page and a
/// reopened run's record, so the two read identically.
struct AgentWorkTrailView: View {
    let entries: [AgentLogEntry]
    /// Materialize rows lazily (only those near the viewport). The LIVE detail
    /// page turns this on: its trail holds the full log (capped at 300 entries)
    /// and pins to the bottom, so eagerly laying out hundreds of rows — every
    /// one a button with its own chevron — on the tap that opens the page was
    /// a visible stall the chat thread never had; and every ~250ms progress
    /// tick re-ran that full-stack layout while the page stayed up. Lazy, the
    /// mount and each tick only touch the screenful by the tail. Records keep
    /// the eager stack (default): their logs are one settled round's slice
    /// inside a thread whose scroll already manages its own geometry.
    var isLazy: Bool = false
    /// Whether this trail belongs to a round still in flight. Only its LAST
    /// block is exempt from the long-paragraph fold: a block that is still
    /// being written must not collapse under the reader mid-sentence.
    var live: Bool = false

    /// One display unit of the trail: a prose paragraph, a fold of reasoning, a
    /// plan, a follow-up prompt marker, or a run of consecutive tool calls
    /// (folded together). Identified by its first entry's id, which stays stable
    /// while a live run grows the trailing group — so the group's expand state
    /// survives streaming.
    private enum Block: Identifiable {
        case prose(AgentLogEntry)
        case thinking(AgentLogEntry)
        case todo(AgentLogEntry)
        case marker(AgentLogEntry)
        case tools([AgentLogEntry])

        var id: UUID {
            switch self {
            case .prose(let e), .marker(let e), .thinking(let e), .todo(let e): return e.id
            case .tools(let run):                                              return run[0].id
            }
        }
    }

    /// Fold consecutive mono entries into `.tools` runs, keeping everything else
    /// as its own block, in order.
    private var blocks: [Block] {
        var out: [Block] = []
        var run: [AgentLogEntry] = []
        func flush() {
            guard !run.isEmpty else { return }
            out.append(.tools(run)); run = []
        }
        for entry in entries {
            if entry.mono {
                run.append(entry)
                continue
            }
            flush()
            switch entry.kind {
            case .thinking: out.append(.thinking(entry))
            case .todo:     out.append(.todo(entry))
            default:        out.append(entry.title.hasPrefix("› ") ? .marker(entry) : .prose(entry))
            }
        }
        flush()
        return out
    }

    var body: some View {
        if isLazy {
            LazyVStack(alignment: .leading, spacing: 7) { rows }
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 7) { rows }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The trail rows themselves — one ForEach, shared by the lazy and eager
    /// containers above. (Lazy containers preserve per-row @State — a group
    /// expanded, an output unfolded — for rows that scroll offscreen, so the
    /// two containers behave identically beyond when layout happens.)
    private var rows: some View {
        let all = blocks
        return ForEach(Array(all.enumerated()), id: \.element.id) { i, block in
            switch block {
            case .tools(let run):
                if run.count == 1 {
                    // A lone call carries its own headline ("$ npm test",
                    // "Editing Foo.swift") — a summary would only hide it.
                    AgentTrailToolRow(entry: run[0])
                } else {
                    AgentTrailGroupRow(entries: run)
                }
            case .marker(let entry):
                // A follow-up round's prompt marker — present only in the
                // live trail (the record files the prompt as its own user
                // turn instead). It IS a question the user asked, so it wears
                // the same bubble every other prompt on the page wears: the
                // marker used to carry its own tighter shell, which made the
                // in-flight round look unlike the settled ones above it and
                // made the bubble visibly jump the moment the round settled
                // and re-rendered as a real turn.
                UserQuestionBubble(text: String(entry.title.dropFirst(2)))
                    .padding(.vertical, 3)
            case .thinking(let entry):
                AgentTrailThinkingRow(text: entry.title)
            case .todo(let entry):
                AgentTrailPlanRow(entry: entry)
            case .prose(let entry):
                // Narration is the agent's own words — set exactly like an
                // answer (same MarkdownBlocks, same 15pt base), one shade
                // quieter so the final report still leads. The block still being
                // written (the live trail's last) never folds.
                AgentTrailProse(text: entry.title,
                                foldable: !(live && i == all.count - 1))
            }
        }
    }
}

/// A paragraph of the agent's narration. Long ones fold to a readable height
/// with a "show all" line rather than being cut at parse time — the trail used
/// to keep only the first 500 characters of a block, and everything past that
/// was simply gone from the record.
private struct AgentTrailProse: View {
    let text: String
    /// False for the block still streaming: folding it would collapse the
    /// paragraph under the reader as it grows.
    var foldable: Bool = true

    @State private var expanded = false

    /// Past this many characters a paragraph is long enough that folding it
    /// helps more than it hides. ~12 lines at the trail's measure.
    private static let foldOver = 1_100
    private static let foldedHeight: CGFloat = 168

    private var folded: Bool { foldable && !expanded && text.count > Self.foldOver }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            MarkdownBlocks(source: text, baseFont: 15, color: Tokens.text2)
                .frame(maxHeight: folded ? Self.foldedHeight : nil, alignment: .top)
                .clipped()
                // The cut edge tapers instead of guillotining a line in half, so
                // the fold reads as "there's more" rather than as damage.
                .mask(alignment: .top) {
                    if folded {
                        LinearGradient(stops: [.init(color: .black, location: 0.72),
                                               .init(color: .clear, location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                    } else {
                        Color.black
                    }
                }
            if foldable, text.count > Self.foldOver {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        expanded.toggle()
                    }
                } label: {
                    Text(L(expanded ? "agent.trail.less" : "agent.trail.more"))
                        .font(.sf(12, weight: .medium))
                        .foregroundStyle(Tokens.text4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// The model's own reasoning, folded away behind one quiet line. Collapsed by
/// default on purpose, and folded HERE only: raw reasoning used to roll through
/// the activity ticker too, which put sliding half-sentences on the panel's one
/// live line. The trail stays a record of what was DONE and the thinking is
/// there when you go looking for it.
private struct AgentTrailThinkingRow: View {
    let text: String

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    expanded.toggle()
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(L("agent.trail.thinking"))
                        .font(.sf(13))
                        .italic()
                        .foregroundStyle(Tokens.text4)
                    Image(systemName: "chevron.right")
                        .font(.sf(7.5, weight: .semibold))
                        .foregroundStyle(Tokens.text4)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Text(text)
                    .font(.sf(13))
                    .foregroundStyle(Tokens.text4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // The same indented rail a folded tool group unfolds into,
                    // so "contents of the line above" reads the same everywhere.
                    .padding(.leading, 9)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 0.75)
                            .fill(.white.opacity(0.08))
                            .frame(width: 1.5)
                    }
            }
        }
    }
}

/// The agent's own plan — one row that the parsers rewrite in place as items
/// tick over, rather than a new row per revision. Always open: a plan is the one
/// thing in the trail you want to see without asking.
private struct AgentTrailPlanRow: View {
    let entry: AgentLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(entry.title)
                .font(.sf(12, weight: .medium))
                .foregroundStyle(Tokens.text4)
            ForEach(Array(AgentTodo.decode(entry.detail ?? "").enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: Self.glyph(item.status))
                        .font(.sf(10, weight: .semibold))
                        .foregroundStyle(item.status == .done ? Tokens.text3 : Tokens.text4)
                        .frame(width: 11)
                    Text(item.text)
                        .font(.sf(13))
                        .foregroundStyle(item.status == .pending ? Tokens.text4 : Tokens.text2)
                        .strikethrough(item.status == .done, color: Tokens.text4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.white.opacity(0.06), lineWidth: 0.5)
                )
        )
    }

    private static func glyph(_ status: AgentTodo.Status) -> String {
        switch status {
        case .done:    return "checkmark.circle.fill"
        case .active:  return "circle.dotted"
        case .pending: return "circle"
        }
    }
}

/// A folded run of consecutive tool calls: one quiet summary line ("4 commands
/// · 2 file edits ›") that expands to the individual calls, each still its own
/// `AgentTrailToolRow`. This is what keeps a busy stretch of work one line
/// tall until the reader actually asks for it.
private struct AgentTrailGroupRow: View {
    let entries: [AgentLogEntry]

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    expanded.toggle()
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Self.summary(entries))
                        .font(.sf(13))
                        .foregroundStyle(Tokens.text4)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.sf(7.5, weight: .semibold))
                        .foregroundStyle(Tokens.text4)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(entries) { AgentTrailToolRow(entry: $0) }
                }
                // Indented under the summary, with a hairline rail so the
                // unfolded run reads as the summary's own contents.
                .padding(.leading, 9)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 0.75)
                        .fill(.white.opacity(0.08))
                        .frame(width: 1.5)
                }
            }
        }
    }

    /// "4 commands · 2 file edits · 1 search" — counts by the title prefixes the
    /// parsers write ("$ ", "Editing/Creating/Deleting ", "Searching ",
    /// "Read/Reading/Grep/Glob"), anything else counted as a plain tool call.
    private static func summary(_ entries: [AgentLogEntry]) -> String {
        var commands = 0, edits = 0, searches = 0, reads = 0, others = 0
        for e in entries {
            if e.title.hasPrefix("$ ") { commands += 1 }
            else if e.title.hasPrefix("Editing ") || e.title.hasPrefix("Creating ")
                     || e.title.hasPrefix("Deleting ") { edits += 1 }
            else if e.title.hasPrefix("Searching ") { searches += 1 }
            else if e.title.hasPrefix("Read") || e.title.hasPrefix("Grep")
                     || e.title.hasPrefix("Glob") { reads += 1 }
            else { others += 1 }
        }
        var parts: [String] = []
        if commands > 0 { parts.append(commands == 1 ? L("agent.trail.cmd.one") : L("agent.trail.cmd.many", commands)) }
        if edits > 0    { parts.append(edits == 1 ? L("agent.trail.edit.one") : L("agent.trail.edit.many", edits)) }
        if reads > 0    { parts.append(reads == 1 ? L("agent.trail.read.one") : L("agent.trail.read.many", reads)) }
        if searches > 0 { parts.append(searches == 1 ? L("agent.trail.search.one") : L("agent.trail.search.many", searches)) }
        if others > 0   { parts.append(others == 1 ? L("agent.trail.tool.one") : L("agent.trail.tool.many", others)) }
        return parts.joined(separator: " · ")
    }
}

/// One tool call in the trail: the input line in mono, with a disclosure
/// chevron when the tool's output was captured — tapping unfolds the output in
/// a quiet code-block card. Rows without output are inert (nothing to unfold).
private struct AgentTrailToolRow: View {
    let entry: AgentLogEntry

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                guard entry.detail != nil else { return }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    expanded.toggle()
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // Mono at 12 = the code rung under the 13pt secondary body,
                    // the same base−1 step markdown code blocks use.
                    Text(entry.title)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Tokens.text4)
                        .lineLimit(expanded ? nil : 1)
                        .fixedSize(horizontal: false, vertical: true)
                    if entry.detail != nil {
                        Image(systemName: "chevron.right")
                            .font(.sf(7.5, weight: .semibold))
                            .foregroundStyle(Tokens.text4)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded, let detail = entry.detail {
                Group {
                    if entry.kind == .diff {
                        AgentDiffBody(patch: detail)
                    } else {
                        Text(detail)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Tokens.text3)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.white.opacity(0.03))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(.white.opacity(0.06), lineWidth: 0.5)
                        )
                )
            }
        }
    }
}

/// The patch behind a file-editing row: added lines green, removed lines red,
/// everything else quiet. Built from the tool call's own before/after text
/// (`AgentDiff`), which is why a row can show what changed the moment the call
/// is made rather than after the tool answers "the file was updated".
private struct AgentDiffBody: View {
    let patch: String

    /// Muted enough to sit on the panel's glass without shouting, saturated
    /// enough to read as +/− at a glance.
    private static let added = Color(red: 0.45, green: 0.80, blue: 0.55)
    private static let removed = Color(red: 0.95, green: 0.48, blue: 0.45)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(patch.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : String(line))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Self.tint(line))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private static func tint(_ line: Substring) -> Color {
        if line.hasPrefix("+") { return added }
        if line.hasPrefix("-") { return removed }
        return Tokens.text4
    }
}
