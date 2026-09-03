// Regression + evaluation harness for the `search_history` tool — NOT part of the
// app target.
//
// Compiles the REAL tool and the REAL archive query straight from Sources/, so
// what's measured is exactly what ships:
//
//   swiftc -O scripts/history_eval/main.swift \
//       $(ls NotchFlow/Sources/*.swift | grep -v NotchFlowApp.swift) \
//       -o /tmp/history_eval && /tmp/history_eval
//
// (The whole source set goes in because `SearchHistoryTool` sits on the app's tool
// protocol and the query lives on `NotchModel`; the alternative — stubbing them —
// would test a copy rather than the shipping code. Only `NotchFlowApp.swift` is
// excluded, for its `@main`.)
//
// Part A — fixtures, every case anchored to a FIXED "now" (Sun 2026-07-26 15:00
// local) via the tool's injectable clock, so expected windows never drift with
// wall-clock time.
// Part B — the user's REAL history.json, if present: what a handful of natural
// questions actually retrieve, plus size and latency of the digest the model reads.

import Foundation

typealias Item = NotchModel.HistoryItem
typealias Turn = NotchModel.Turn

// MARK: - Fixed anchor

let cal = Calendar.current
/// Sunday, July 26 2026, 15:00 local.
let anchor: Date = {
    var c = DateComponents()
    c.year = 2026; c.month = 7; c.day = 26; c.hour = 15; c.minute = 0
    return cal.date(from: c)!
}()

/// A local wall-clock instant, as an offset in days from the anchor's day.
func day(_ offset: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    let base = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: anchor))!
    return cal.date(bySettingHour: hour, minute: minute, second: 0, of: base)!
}

// MARK: - Fixtures
//
// Shaped after a real archive: mostly Ask rows with generated titles, a handful of
// captures, a couple of agent runs (one failed), and the two rows that must never
// surface (the in-flight question, and the thread on screen).

let currentThreadID = UUID()

func ask(_ t: Date, title: String?, q: String, a: String, turns: [Turn]? = nil,
         id: UUID = UUID()) -> Item {
    Item(id: id, q: q, a: a, t: t, turns: turns, title: title, source: .ask)
}

func capture(_ t: Date, _ line: String, _ source: Item.Source) -> Item {
    Item(q: line, a: "", t: t, turns: [], source: source)
}

func agent(_ t: Date, title: String, prompt: String, outcome: String?) -> Item {
    var item = Item(q: prompt, a: "done", t: t, turns: [], title: title, source: .agent)
    item.agentOutcome = outcome
    return item
}

var fixtures: [Item] = [
    // ── today (Sun 2026-07-26)
    ask(day(0, 14, 30), title: "Acme pricing", q: "What does Acme's standard plan cost?",
        a: "The standard plan starts at $21.59 per month."),
    capture(day(0, 11, 5), "Meeting notes\nFirst design draft due Tuesday", .note),   // multi-line
    agent(day(0, 9, 40), title: "Fix hint flicker", prompt: "Fix the hint flicker while typing",
          outcome: "failure"),
    // ── yesterday (Sat 2026-07-25) — 23:50 is the end-of-day boundary case
    ask(day(-1, 23, 50), title: "Redis connection pool leak", q: "Why does the connection count keep rising?",
        a: "The pool may not be returning connections; check the close call in finally.",
        turns: [Turn(role: "user", text: "Why does the connection count keep rising?"),
                Turn(role: "assistant", text: "The connection pool may not be returning connections."),
                Turn(role: "user", text: "How can I confirm Redis is responsible?"),
                Turn(role: "assistant", text: "Inspect the CLIENT LIST age distribution.")]),
    capture(day(-1, 8, 15), "Discussed rent with landlord; reply due at month end", .note),
    capture(day(-1, 7, 0), "Pay rent", .reminder),
    // ── 6 days back (Mon 2026-07-20) — outside a 7-day window's far edge is day -6
    ask(day(-6, 16, 20), title: nil, q: "Define diligence", a: "Careful and persistent work or effort."),
    agent(day(-6, 10, 0), title: "Landing-page font weight", prompt: "Make the landing-page heading lighter",
          outcome: "success"),
    // ── 40 days back, for "the whole archive" vs a window
    capture(day(-40, 12, 0), "Old note, already archived", .note),
]

// The in-flight question: parked in `history` the instant it's submitted. Must
// never come back as a past activity.
var inFlight = ask(day(0, 15, 0), title: nil, q: "What is my main work today?", a: "")
inFlight.pending = true
fixtures.append(inFlight)

// The thread currently on screen: already in the wire context verbatim.
fixtures.append(ask(day(0, 14, 55), title: "Current turn", q: "How does this work?", a: "Like this.",
                    id: currentThreadID))

/// The tool under test, anchored and pointed at a given archive.
func tool(_ items: [Item], currentThread: UUID? = currentThreadID) -> SearchHistoryTool {
    SearchHistoryTool(
        lookup: { query in
            NotchModel.archiveDigest(query, in: items, currentThread: currentThread)
        },
        now: { anchor })
}

// MARK: - Assertions

var passed = 0
var failed = 0
var caseIndex = 0

/// Run one case: `input` is the tool call's arguments exactly as a model would
/// send them. `expect` gets the rendered digest and returns nil on success or the
/// reason it failed.
func check(_ name: String, _ input: [String: Any], items: [Item] = fixtures,
           currentThread: UUID? = currentThreadID,
           _ expect: (String) -> String?) async {
    caseIndex += 1
    let out = (try? await tool(items, currentThread: currentThread).execute(input)) ?? "<threw>"
    if let reason = expect(out) {
        failed += 1
        print("  ✗ \(caseIndex). \(name)\n      \(reason)")
        // The digest is what the model reads — print it on failure, indented.
        for line in out.split(separator: "\n", omittingEmptySubsequences: false) {
            print("      | \(line)")
        }
    } else {
        passed += 1
        print("  ✓ \(caseIndex). \(name)")
    }
}

/// How many entry lines the digest lists (rows are numbered "N. [kind] …").
func entryCount(_ digest: String) -> Int {
    digest.split(separator: "\n").filter { line in
        guard let dot = line.firstIndex(of: ".") else { return false }
        return Int(line[line.startIndex..<dot]) != nil
    }.count
}

func requireCount(_ digest: String, _ n: Int) -> String? {
    let got = entryCount(digest)
    return got == n ? nil : "expected \(n) entries, got \(got)"
}

func requireContains(_ digest: String, _ needles: [String]) -> String? {
    for needle in needles where !digest.contains(needle) {
        return "missing “\(needle)”"
    }
    return nil
}

func requireAbsent(_ digest: String, _ needles: [String]) -> String? {
    for needle in needles where digest.contains(needle) {
        return "should not contain “\(needle)”"
    }
    return nil
}

// MARK: - Part A · fixtures

print("=== Part A · fixtures (anchor Sun 2026-07-26 15:00) ===\n")

await check("no arguments → whole archive, newest first", [:]) { d in
    requireCount(d, 9)
        // The two withheld rows.
        ?? requireAbsent(d, ["What is my main work today?", "Current turn"])
        ?? requireContains(d, ["newest first", "Acme pricing", "Old note, already archived"])
        // Newest first: today's Ask must precede yesterday's.
        ?? (d.range(of: "Acme pricing")!.lowerBound < d.range(of: "Redis connection pool leak")!.lowerBound
            ? nil : "rows are not newest-first")
}

await check("days:1 → today only", ["days": 1]) { d in
    requireCount(d, 3)
        ?? requireContains(d, ["Acme pricing", "Meeting notes", "Fix hint flicker"])
        ?? requireAbsent(d, ["Redis connection pool leak"])
}

await check("since:\"today\" → same as days:1", ["since": "today"]) { d in
    requireCount(d, 3) ?? requireContains(d, ["2026-07-26"])
}

await check("yesterday, whole day (23:50 row must survive)",
            ["since": "yesterday", "until": "yesterday"]) { d in
    requireCount(d, 3)
        ?? requireContains(d, ["Redis connection pool leak", "Discussed rent", "Pay rent"])
        ?? requireAbsent(d, ["Acme pricing"])
}

await check("until:\"today\" includes all of today (00:00 boundary)",
            ["until": "today"]) { d in
    requireCount(d, 9) ?? requireContains(d, ["Acme pricing"])
}

await check("explicit ISO window 07-20 → 07-21", ["since": "2026-07-20", "until": "2026-07-21"]) { d in
    requireCount(d, 2)
        ?? requireContains(d, ["diligence", "Landing-page font weight", "2026-07-20 → 2026-07-21"])
}

await check("kind:note", ["kind": "note"]) { d in
    requireCount(d, 3)
        ?? requireContains(d, ["kind note", "[note]"])
        ?? requireAbsent(d, ["[ask]", "[reminder]", "[agent"])
}

await check("kind:reminder", ["kind": "reminder"]) { d in
    requireCount(d, 1) ?? requireContains(d, ["Pay rent"])
}

await check("keyword in a NOTE's body (Recent's filter can't do this)",
            ["query": "landlord"]) { d in
    requireCount(d, 1) ?? requireContains(d, ["Discussed rent", "matching"])
}

await check("keyword in an ANSWER, not the title", ["query": "finally"]) { d in
    requireCount(d, 1) ?? requireContains(d, ["Redis connection pool leak"])
}

await check("keyword deep in a multi-turn thread", ["query": "CLIENT LIST"]) { d in
    requireCount(d, 1) ?? requireContains(d, ["Redis connection pool leak"])
}

await check("no match → explicit \"nothing recorded\", no invention",
            ["query": "zzz-nonexistent"]) { d in
    requireCount(d, 0)
        ?? requireContains(d, ["No entries found", "do not invent"])
}

await check("agent rows carry their outcome", ["kind": "agent"]) { d in
    requireCount(d, 2)
        ?? requireContains(d, ["[agent·failure]", "[agent·success]"])
}

await check("limit:2 caps the list AND admits it is a slice", ["limit": 2]) { d in
    requireCount(d, 2)
        ?? requireContains(d, ["Acme pricing",
                               "The 2 most recent of 9 matching entries",
                               "only the newest slice"])
}

await check("a complete list does NOT claim to be a slice", ["days": 1]) { d in
    requireAbsent(d, ["most recent of", "only the newest slice"])
        ?? requireContains(d, ["3 entries"])
}

await check("limit:999 clamps to 60 (not an error)", ["limit": 999]) { d in
    requireCount(d, 9)
}

await check("backwards window is read as the window meant",
            ["since": "today", "until": "2026-07-20"]) { d in
    requireCount(d, 8)
        ?? requireContains(d, ["2026-07-20 → 2026-07-26"])
        ?? requireAbsent(d, ["Old note, already archived"])
}

await check("multi-line note is flattened onto one line", ["kind": "note", "days": 1]) { d in
    requireContains(d, ["Meeting notes First design draft due Tuesday"])
        ?? requireCount(d, 1)
}

await check("full ISO timestamp is tolerated as a day",
            ["since": "2026-07-26T00:00:00Z"]) { d in
    requireCount(d, 3)
}

await check("integer argument arriving as a string", ["days": "1", "limit": "2"]) { d in
    requireCount(d, 2)
}

await check("unknown kind is ignored rather than matching nothing",
            ["kind": "screenshot"]) { d in
    requireCount(d, 9)
}

await check("an Ask with no generated title doesn't repeat itself",
            ["query": "diligence"]) { d in
    // Headline IS the question here, so no "asked:" echo line.
    requireCount(d, 1) ?? requireAbsent(d, ["asked: Define diligence"])
}

await check("an Ask WITH a title also shows the literal question",
            ["query": "Acme"]) { d in
    requireContains(d, ["Acme pricing", "asked: What does Acme's standard plan cost?"])
}

await check("empty archive reads as nothing recorded, not as an error",
            [:], items: []) { d in
    requireContains(d, ["No entries found"])
}

// Budget: 400 long rows, all inside the window.
let fatArchive: [Item] = (0..<400).map { i in
    ask(day(0, 12, i % 60),
        title: "Very long title " + String(repeating: "filler text ", count: 40) + " #\(i)",
        q: String(repeating: "Very long question content ", count: 40),
        a: "answer")
}

await check("budget: output stays under the 6000-char cap and says what it dropped",
            ["limit": 60], items: fatArchive, currentThread: nil) { d in
    if d.count > 6000 { return "digest is \(d.count) chars, over the 6000 cap" }
    return requireContains(d, ["omitted to stay within budget", "narrow the date window"])
        // Both truncations at once (60-row cap of 400 matches, then the budget):
        // the model must hear about both, not just the one that fired last.
        ?? requireContains(d, ["The 60 most recent of 400 matching entries"])
}

await check("per-row caps keep one pathological row from eating the digest",
            ["limit": 1], items: fatArchive, currentThread: nil) { d in
    // headlineCap 220 + bodyCap 160 + framing, comfortably under a KB.
    d.count < 900 ? nil : "single row rendered \(d.count) chars"
}

print("\n  Part A: \(passed)/\(passed + failed) passed"
      + (failed == 0 ? "" : "  ← \(failed) FAILED"))

// MARK: - Part B · the real archive

print("\n=== Part B · real archive ===\n")

let realURL = FileManager.default.urls(for: .applicationSupportDirectory,
                                       in: .userDomainMask).first!
    .appendingPathComponent("Notch/history.json")

if let data = try? Data(contentsOf: realURL),
   let items = try? JSONDecoder().decode([Item].self, from: data) {
    let days = Set(items.map { cal.startOfDay(for: $0.t) })
    let kinds = Dictionary(grouping: items, by: \.source.rawValue).mapValues(\.count)
    print("  \(items.count) rows, \(days.count) distinct days, kinds \(kinds.sorted { $0.key < $1.key })")
    if let newest = items.map(\.t).max(), let oldest = items.map(\.t).min() {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        print("  span \(f.string(from: oldest)) → \(f.string(from: newest))\n")
    }

    // Anchor Part B at the archive's own newest day, so "today"/"yesterday" land on
    // rows that exist regardless of when this harness is run.
    let newestDay = items.map(\.t).max() ?? anchor
    let realTool = SearchHistoryTool(
        lookup: { q in NotchModel.archiveDigest(q, in: items, currentThread: nil) },
        now: { newestDay })
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
    print("  (anchored at the archive's newest day, \(f.string(from: newestDay)))\n")

    let probes: [(String, [String: Any])] = [
        ("What did I do today?",          ["days": 1]),
        ("What did I do yesterday?",      ["since": "yesterday", "until": "yesterday"]),
        ("What kept me busy this week?",  ["days": 7]),
        ("What did I save?",              ["kind": "note"]),
        ("What did the agent do?",        ["kind": "agent", "days": 7]),
        ("What did I ask about Notch?",   ["query": "notch"]),
        ("Did I mention a release?",      ["query": "release"]),
        ("Entire archive (no arguments)", [:]),
    ]

    for (label, input) in probes {
        let start = DispatchTime.now()
        let digest = (try? await realTool.execute(input)) ?? "<threw>"
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
        let rows = entryCount(digest)
        // Character count is a useful rough proxy for the context budget.
        print(String(format: "  %-26@ → %2d rows, %4d chars, %.1fms",
                     label as NSString, rows, digest.count, ms))
    }

    // Show one digest in full — the "what did I do today" case, which is the whole
    // point of the feature.
    print("\n  ── the digest the model actually reads for “What did I do today?”:\n")
    let sample = (try? await realTool.execute(["days": 1])) ?? ""
    for line in sample.split(separator: "\n", omittingEmptySubsequences: false) {
        print("  | \(line)")
    }
} else {
    print("  (no readable history.json at \(realURL.path) — Part B skipped)")
}

print("")
exit(failed == 0 ? 0 : 1)
