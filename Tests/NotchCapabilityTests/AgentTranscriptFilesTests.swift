import Foundation
import Testing
@testable import NotchCapabilities

/// Builds a Codex-shaped tree: `<root>/YYYY/MM/DD/rollout-….jsonl`.
private func makeTree() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("nf-transcripts-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// `FileManager.enumerator` hands back `/private/var/…` while the URL we built
/// says `/var/…` — the same file through macOS's own symlink. Compare resolved.
private func resolved(_ urls: [URL]) -> [String] {
    urls.map { $0.resolvingSymlinksInPath().path }
}

private func write(_ root: URL, day: String, name: String, modifiedAt: Date,
                   contents: String = "{}") throws -> URL {
    let dir = root.appendingPathComponent(day, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try Data(contents.utf8).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
    return url
}

@Test("an in-file event timestamp wins over a stale synced mtime")
func transcriptTimestampWinsOverSyncedMtime() throws {
    // Sync clients can preserve the source machine's mtime while delivering a
    // transcript that was written moments ago. Dropping this file means a live
    // session disappears until a later local write happens to touch it.
    let root = try makeTree()
    defer { try? FileManager.default.removeItem(at: root) }

    let now = Date(timeIntervalSince1970: 1_788_177_600)
    let live = try write(root, day: "2026/08/12", name: "rollout-synced.jsonl",
                         modifiedAt: now.addingTimeInterval(-86_400),
                         contents: "{\"timestamp\":\"2026-08-31T11:59:55Z\",\"type\":\"event_msg\"}\n")

    let found = AgentTranscriptFiles.recent(in: root, since: now.addingTimeInterval(-60), now: now)

    #expect(resolved(found.map(\.url)) == resolved([live]))
}

@Test("a future transcript timestamp cannot make a session permanently fresh")
func futureTimestampIsClampedToScanTime() throws {
    let root = try makeTree()
    defer { try? FileManager.default.removeItem(at: root) }

    let now = Date(timeIntervalSince1970: 1_788_177_600)
    let future = try write(root, day: "2026/08/31", name: "rollout-future.jsonl",
                           modifiedAt: now.addingTimeInterval(86_400),
                           contents: "{\"timestamp\":\"2026-09-01T10:00:00Z\"}\n")

    let found = AgentTranscriptFiles.recent(in: root, since: now, now: now)

    #expect(found.map(\.url).map { $0.resolvingSymlinksInPath().path } == resolved([future]))
    #expect(found.first?.modifiedAt == now)
    #expect(found.first?.fileModifiedAt == now.addingTimeInterval(86_400))
}

@Test("a session created weeks ago but written to right now is still found")
func oldFolderFreshFileIsFound() throws {
    // The rudder regression, exactly: a live Codex session whose rollout was
    // created 19 days ago sits in that day's folder with a current mtime. The
    // old day-span walk opened only today and yesterday and never saw it.
    let root = try makeTree()
    defer { try? FileManager.default.removeItem(at: root) }

    let now = Date()
    let stale = try write(root, day: "2026/08/12", name: "rollout-old-idle.jsonl",
                          modifiedAt: now.addingTimeInterval(-40 * 24 * 60 * 60))
    let live = try write(root, day: "2026/08/12", name: "rollout-old-but-live.jsonl",
                         modifiedAt: now.addingTimeInterval(-30))

    let found = AgentTranscriptFiles.recent(in: root, since: now.addingTimeInterval(-24 * 60 * 60))

    #expect(resolved(found.map(\.url)) == resolved([live]))
    #expect(!resolved(found.map(\.url)).contains(resolved([stale])[0]))
}

@Test("recency is judged on the file, never on its folder name")
func folderNameIsIrrelevant() throws {
    let root = try makeTree()
    defer { try? FileManager.default.removeItem(at: root) }

    let now = Date()
    // A file in *today's* folder that has not been touched in a week must not
    // qualify just because its directory is named today.
    _ = try write(root, day: "2026/08/31", name: "rollout-today-but-stale.jsonl",
                  modifiedAt: now.addingTimeInterval(-7 * 24 * 60 * 60))

    #expect(AgentTranscriptFiles.recent(in: root, since: now.addingTimeInterval(-3600)).isEmpty)
}

@Test("the walk reaches arbitrary depth, not a fixed number of folder levels")
func walkIsDepthAgnostic() throws {
    let root = try makeTree()
    defer { try? FileManager.default.removeItem(at: root) }

    let now = Date()
    let deep = try write(root, day: "2026/08/12/extra/nesting", name: "rollout-deep.jsonl",
                         modifiedAt: now)

    #expect(resolved(AgentTranscriptFiles.recent(in: root, since: now.addingTimeInterval(-60))
                .map(\.url)) == resolved([deep]))
}

@Test("the predicate can exclude a subtree, and non-jsonl files never match")
func predicateAndExtensionFilter() throws {
    let root = try makeTree()
    defer { try? FileManager.default.removeItem(at: root) }

    let now = Date()
    let wanted = try write(root, day: "2026/08/31", name: "rollout-a.jsonl", modifiedAt: now)
    _ = try write(root, day: "2026/08/31/subagents", name: "rollout-child.jsonl", modifiedAt: now)
    _ = try write(root, day: "2026/08/31", name: "notes.txt", modifiedAt: now)

    let found = AgentTranscriptFiles.recent(in: root, since: now.addingTimeInterval(-60)) {
        !$0.path.contains("/subagents/")
    }

    #expect(resolved(found.map(\.url)) == resolved([wanted]))
}

@Test("a missing root yields nothing rather than throwing")
func missingRootIsEmpty() {
    let absent = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")

    #expect(AgentTranscriptFiles.recent(in: absent, since: .distantPast).isEmpty)
}

@Test("unrecognised transcript schemas are surfaced rather than looking empty")
func transcriptSchemaDriftIsDiagnosed() {
    #expect(AgentTranscriptDiscovery.message(transcriptsFound: 4, recognizedSessions: 0)
            == "Found 4 agent transcripts, but could not recognise their session data. Update your agent CLI or check diagnostics.")
    #expect(AgentTranscriptDiscovery.message(transcriptsFound: 4, recognizedSessions: 1) == nil)
    #expect(AgentTranscriptDiscovery.message(transcriptsFound: 0, recognizedSessions: 0) == nil)
}
