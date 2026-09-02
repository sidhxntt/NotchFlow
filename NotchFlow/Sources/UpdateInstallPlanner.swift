import Foundation

struct UpdateInstallPreflight {
    var isWritable: (URL) -> Bool
    var isReadOnlyVolume: (URL) -> Bool

    static let live = UpdateInstallPreflight(
        isWritable: { FileManager.default.isWritableFile(atPath: $0.path) },
        isReadOnlyVolume: {
            (try? $0.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? true
        }
    )
}

enum UpdateInstallError: Error, LocalizedError {
    case destinationMissing
    case crossVolumeCandidate
    case replacementFailed(Error)
    case rollbackFailed(replacement: Error, rollback: Error)

    var errorDescription: String? {
        switch self {
        case .destinationMissing: return "The running app could not be found at its install location."
        case .crossVolumeCandidate: return "The update was not staged on the installed app's volume."
        case .replacementFailed(let error): return "The update could not replace the installed app: \(error.localizedDescription)"
        case .rollbackFailed(let replacement, let rollback):
            return "The update failed (\(replacement.localizedDescription)) and the previous app could not be restored (\(rollback.localizedDescription))."
        }
    }
}

/// Chooses between an in-place, same-volume update and the safe manual-DMG
/// route. It also owns the narrow replacement transaction so verification is
/// always completed before the installed bundle is moved.
struct UpdateInstallPlanner {
    enum ManualReason: Equatable, Sendable {
        case mountedVolume
        case translocated
        case readOnlyVolume
        case notWritable
    }

    enum Outcome: Equatable, Sendable {
        case automatic(destination: URL, stagingParent: URL)
        case manualDMG(URL, ManualReason)
    }

    static func plan(
        runningBundleURL: URL,
        manualDMGURL: URL,
        preflight: UpdateInstallPreflight = .live
    ) -> Outcome {
        let destination = runningBundleURL.standardizedFileURL
        let components = destination.pathComponents

        if components.contains("AppTranslocation") {
            return .manualDMG(manualDMGURL, .translocated)
        }
        if components.count > 1, components[1] == "Volumes" {
            return .manualDMG(manualDMGURL, .mountedVolume)
        }

        let parent = destination.deletingLastPathComponent()
        if preflight.isReadOnlyVolume(parent) {
            return .manualDMG(manualDMGURL, .readOnlyVolume)
        }
        guard preflight.isWritable(parent), preflight.isWritable(destination) else {
            return .manualDMG(manualDMGURL, .notWritable)
        }
        return .automatic(destination: destination, stagingParent: parent)
    }

    static func makeStagingDirectory(
        in stagingParent: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory = stagingParent.appendingPathComponent(
            ".NotchFlow-update-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    static func replaceInstalledBundle(
        with candidate: URL,
        at destination: URL,
        fileManager: FileManager = .default,
        verifier: (URL) throws -> Void
    ) throws {
        // This call must remain the first operation that can fail based on the
        // candidate. In particular, do not move/remove the destination first.
        try verifier(candidate)

        guard fileManager.fileExists(atPath: destination.path) else {
            throw UpdateInstallError.destinationMissing
        }
        guard try volumeIdentifier(for: candidate) == volumeIdentifier(for: destination.deletingLastPathComponent()) else {
            throw UpdateInstallError.crossVolumeCandidate
        }

        let backup = destination.deletingLastPathComponent().appendingPathComponent(
            ".NotchFlow-previous-\(UUID().uuidString).app",
            isDirectory: true
        )
        try fileManager.moveItem(at: destination, to: backup)
        do {
            try fileManager.moveItem(at: candidate, to: destination)
        } catch let replacement {
            do {
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.moveItem(at: backup, to: destination)
            } catch let rollback {
                throw UpdateInstallError.rollbackFailed(replacement: replacement, rollback: rollback)
            }
            throw UpdateInstallError.replacementFailed(replacement)
        }
        try? fileManager.removeItem(at: backup)
    }

    private static func volumeIdentifier(for url: URL) throws -> AnyHashable {
        let values = try url.resourceValues(forKeys: [.volumeIdentifierKey])
        guard let identifier = values.volumeIdentifier as? AnyHashable else {
            throw UpdateInstallError.crossVolumeCandidate
        }
        return identifier
    }
}
