import Foundation

public struct DiskImageInstallPlan: Equatable, Sendable {
    public let source: URL
    public let destination: URL
    public let requiresConfirmation: Bool
}

/// Validates a mounted image's contents before an app-target executor is
/// allowed to copy, eject, or trash anything.
public enum DiskImageInstallPlanner {
    public static func plan(mountedItems: [URL], applicationsDirectory: URL = URL(fileURLWithPath: "/Applications", isDirectory: true)) -> DiskImageInstallPlan? {
        let apps = mountedItems.filter { $0.pathExtension.localizedCaseInsensitiveCompare("app") == .orderedSame }
        guard apps.count == 1, let app = apps.first else { return nil }
        return DiskImageInstallPlan(source: app,
                                    destination: applicationsDirectory.appendingPathComponent(app.lastPathComponent),
                                    requiresConfirmation: true)
    }
}
