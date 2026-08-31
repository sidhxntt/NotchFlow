import Foundation

/// Makes schema drift visible without treating a machine with no CLI history as
/// an error. Parsers deliberately skip unknown JSONL safely; this is the point
/// where that safe skip becomes actionable rather than silently empty UI.
public enum AgentTranscriptDiscovery {
    public static func message(transcriptsFound: Int, recognizedSessions: Int) -> String? {
        guard transcriptsFound > 0, recognizedSessions == 0 else { return nil }
        return "Found \(transcriptsFound) agent transcript\(transcriptsFound == 1 ? "" : "s"), but could not recognise their session data. Update your agent CLI or check diagnostics."
    }
}

/// Finds the CLI transcripts worth reading, by when they were last **written**.
///
/// ## Why this is not a directory-name calculation
///
/// Codex stores rollouts under `~/.codex/sessions/YYYY/MM/DD/`, sharded by the
/// day the session was *created*. The scanner used to exploit that: it derived a
/// span of day-folders from its freshness window and opened only those, which is
/// cheap and looks obviously correct.
///
/// It is not correct, because the two dates are unrelated. A session created on
/// the 12th and still running on the 31st lives in the folder for the 12th while
/// its file is being written to right now. A one-day freshness window opens
/// today and yesterday, so that session was invisible — not late, not stale,
/// *never seen* — no matter how active it was. Observed exactly that: a live
/// Codex session in `…/Products/rudder`, rollout mtime current to the second,
/// filed under `2026/08/12` and absent from the roster for nineteen days.
///
/// The freshness question is "when was this last written", so the answer has to
/// come from the file's modification date. Walking the tree and asking each file
/// is the only way to get that, and it is what the Claude side already does.
public enum AgentTranscriptFiles {
    public struct Entry: Equatable, Sendable {
        public let url: URL
        /// The filesystem's stable version marker. It is intentionally kept
        /// separate from `modifiedAt`: the latter may be clamped to `now` for
        /// freshness, and is therefore not safe to use as a parse-cache key.
        public let fileModifiedAt: Date
        public let modifiedAt: Date

        public init(url: URL, modifiedAt: Date, fileModifiedAt: Date? = nil) {
            self.url = url
            self.fileModifiedAt = fileModifiedAt ?? modifiedAt
            self.modifiedAt = modifiedAt
        }
    }

    private struct CacheKey: Equatable {
        let modifiedAt: Date
        let size: Int
    }

    private final class TimestampCache: @unchecked Sendable {
        private var values: [String: (key: CacheKey, timestamp: Date?)] = [:]
        private let lock = NSLock()

        func timestamp(for url: URL, key: CacheKey, loader: () -> Date?) -> Date? {
            lock.lock()
            if let cached = values[url.path], cached.key == key {
                lock.unlock()
                return cached.timestamp
            }
            lock.unlock()

            let timestamp = loader()
            lock.lock()
            values[url.path] = (key, timestamp)
            lock.unlock()
            return timestamp
        }
    }

    private static let timestamps = TimestampCache()
    private static let tailLimit = 64 * 1024

    /// Every `.jsonl` under `root`, at any depth, with an effective activity
    /// timestamp at or after `since`. The effective timestamp is the newest
    /// parseable record timestamp where one exists, otherwise the filesystem
    /// mtime. This matters for synced histories: mtime belongs to the source
    /// filesystem, whereas the JSONL record is evidence of when the agent last
    /// wrote. Future values are clamped so clock skew cannot keep a dead session
    /// fresh forever.
    ///
    /// - Parameter matching: an extra filter on the URL, for callers that want
    ///   only a filename prefix or want to exclude a subtree.
    public static func recent(in root: URL, since: Date, now: Date = Date(),
                              matching predicate: (URL) -> Bool = { _ in true }) -> [Entry] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return [] }

        var results: [Entry] = []
        for case let url as URL in walker {
            guard url.pathExtension == "jsonl", predicate(url),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let fileModifiedAt = values.contentModificationDate
            else { continue }
            let size = values.fileSize ?? 0
            let timestamp = timestamps.timestamp(for: url, key: .init(modifiedAt: fileModifiedAt, size: size)) {
                newestTimestamp(in: url)
            }
            let modifiedAt = effectiveTimestamp(fileModifiedAt: fileModifiedAt, recordTimestamp: timestamp, now: now)
            guard modifiedAt >= since else { continue }
            results.append(Entry(url: url, modifiedAt: modifiedAt, fileModifiedAt: fileModifiedAt))
        }
        return results.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private static func effectiveTimestamp(fileModifiedAt: Date, recordTimestamp: Date?, now: Date) -> Date {
        let mtime = min(fileModifiedAt, now)
        guard let recordTimestamp else { return mtime }
        return min(max(mtime, recordTimestamp), now)
    }

    private static func newestTimestamp(in url: URL) -> Date? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        if size > UInt64(tailLimit) {
            try? handle.seek(toOffset: size - UInt64(tailLimit))
        } else {
            try? handle.seek(toOffset: 0)
        }
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .reversed()
            .lazy
            .compactMap { line in
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
                return parseTimestamp(object["timestamp"]) ?? parseTimestamp((object["payload"] as? [String: Any])?["timestamp"])
            }
            .first
    }

    private static func parseTimestamp(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
