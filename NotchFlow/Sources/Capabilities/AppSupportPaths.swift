import Foundation

/// Where NotchFlow keeps its own files under Application Support.
///
/// One place that names the directory, so the File Tray's copies of dropped
/// files, the local diagnostics log and the fitted intent heads can't drift onto
/// three different paths.
public enum AppSupportPaths {
    public static let directoryName = "NotchFlow"

    /// `~/Library/Application Support/NotchFlow`. Nil only when Application
    /// Support itself cannot be resolved. Callers create what they need — this
    /// hands back a location, not a guarantee that anything exists yet.
    public static var appDirectory: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    /// The File Tray's own subdirectory.
    public static var fileTrayDirectory: URL? {
        appDirectory?.appendingPathComponent("FileTray", isDirectory: true)
    }

    /// Where `IntentEngine` caches its fitted classifier heads.
    public static var intentHeadsDirectory: URL? {
        appDirectory?.appendingPathComponent("IntentHeads", isDirectory: true)
    }
}

/// A tiny append-only JSONL journal. Token events are valuable only while they
/// are recent, but a growing `[Event]` encoded back into UserDefaults on every
/// import makes a cold start pay for the whole archive repeatedly. A newline is
/// the commit boundary: a crash can leave one incomplete last record, never
/// invalidate the durable records before it.
public struct TokenLedger: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func records() throws -> [Data] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        // Only newline-terminated records are committed. A partial trailing
        // write is deliberately ignored and will be replaced by later appends.
        var lines = data.split(separator: UInt8(0x0A), omittingEmptySubsequences: true)
        if data.last != 0x0A, !lines.isEmpty {
            lines.removeLast()
        }
        return lines.map { Data($0) }
    }

    public func append(_ record: Data) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        handle.write(record)
        handle.write(Data([0x0A]))
        try handle.synchronize()
    }

    public func replace(with records: [Data]) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var data = Data()
        for record in records {
            data.append(record)
            data.append(0x0A)
        }
        try data.write(to: url, options: .atomic)
    }
}
