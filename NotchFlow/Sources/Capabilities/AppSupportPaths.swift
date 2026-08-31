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
