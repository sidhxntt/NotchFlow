import Foundation

/// The user's Shortcuts, by name.
///
/// Read through the `shortcuts` CLI rather than any framework: there is no
/// public API to enumerate a user's shortcuts, and the CLI ships with macOS.
/// Running one costs a subprocess, which is fine for something a person clicked.
///
/// This is the general-purpose "everything the user has" API; the card itself
/// (`ShortcutsUtilityOverlayView`) narrows `names` down to a fixed favourites
/// list before showing anything.
@MainActor
final class ShortcutsCatalog: ObservableObject {
    @Published private(set) var names: [String] = []

    /// The card no longer shows this whole list — `ShortcutsUtilityOverlayView`
    /// filters it down to a fixed favourites set — so this only needs to be
    /// generous enough that a favourite further down the user's library isn't
    /// cut off before the filter ever sees it.
    nonisolated private static let limit = 200

    func load() async {
        guard names.isEmpty else { return }
        names = await Task.detached(priority: .utility) { Self.list() }.value
    }

    nonisolated private static func list() -> [String] {
        guard let output = run(arguments: ["list"]) else { return [] }
        var found: [String] = []
        for line in output.split(separator: "\n") {
            let name = line.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            found.append(name)
            if found.count == limit { break }
        }
        return found
    }

    /// A failure must reach the card; discarding stderr and the exit status made
    /// a misspelled shortcut indistinguishable from a successful run.
    static func run(_ name: String, completion: @escaping @MainActor (String?) -> Void) {
        Task.detached(priority: .userInitiated) {
            let failure = runFailure(arguments: ["run", name])
            await MainActor.run { completion(failure) }
        }
    }

    @discardableResult
    nonisolated private static func run(arguments: [String]) -> String? {
        let executable = URL(fileURLWithPath: "/usr/bin/shortcuts")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    nonisolated private static func runFailure(arguments: [String]) -> String? {
        let executable = URL(fileURLWithPath: "/usr/bin/shortcuts")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            return "Shortcuts is unavailable on this Mac."
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        guard (try? process.run()) != nil else { return "Couldn't start Shortcuts." }
        _ = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return nil }
        let message = String(data: errorData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return message?.isEmpty == false ? message : "Shortcuts couldn't run this shortcut."
    }
}
