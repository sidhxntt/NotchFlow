import Foundation

struct UpdateReleaseAsset: Equatable, Sendable {
    let name: String
    let downloadURL: URL
}

struct UpdateToolResult: Sendable {
    let terminationStatus: Int32
    let standardOutput: String
    let standardError: String
}

protocol UpdateToolRunning: AnyObject {
    func run(_ executable: URL, arguments: [String]) throws -> UpdateToolResult
}

final class UpdateProcessRunner: UpdateToolRunning {
    func run(_ executable: URL, arguments: [String]) throws -> UpdateToolResult {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        return UpdateToolResult(
            terminationStatus: process.terminationStatus,
            standardOutput: String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            standardError: String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
}

enum UpdateArtifactVerificationError: Error, LocalizedError {
    case malformedReleaseTag
    case releaseChanged
    case releaseNotNewer
    case missingOrAmbiguousAsset
    case invalidDownloadURL
    case malformedBundle
    case invalidSignature
    case wrongSigner
    case wrongTeamIdentifier
    case gatekeeperRejected
    case wrongBundleIdentifier
    case wrongVersion
    case toolLaunchFailed(Error)

    var errorDescription: String? {
        switch self {
        case .malformedReleaseTag: return "The release tag is not an exact vX.Y.Z version."
        case .releaseChanged: return "The latest release changed after the update was offered."
        case .releaseNotNewer: return "The requested release is not newer than the running app."
        case .missingOrAmbiguousAsset: return "The release does not contain exactly one expected arm64 ZIP."
        case .invalidDownloadURL: return "The update asset does not have a trusted HTTPS download URL."
        case .malformedBundle: return "The update does not contain a readable app bundle."
        case .invalidSignature: return "The update's code signature is invalid."
        case .wrongSigner: return "The update is not signed with a Developer ID Application certificate."
        case .wrongTeamIdentifier: return "The update was signed by a different Apple developer team."
        case .gatekeeperRejected: return "Gatekeeper rejected the update."
        case .wrongBundleIdentifier: return "The update has the wrong bundle identifier."
        case .wrongVersion: return "The update version does not match the requested release."
        case .toolLaunchFailed(let error): return "A macOS verification tool could not run: \(error.localizedDescription)"
        }
    }
}

/// Validates the release identity before any caller is allowed to replace the
/// installed app. Signature and Gatekeeper checks intentionally precede reads
/// from Info.plist: metadata becomes trustworthy only after code validation.
struct UpdateArtifactVerifier {
    static let bundleIdentifier = "com.notchflow.app"
    static let canonicalArchitecture = "arm64"

    private let expectedBundleIdentifier: String
    private let expectedTeamIdentifier: String
    private let expectedVersion: String
    private let toolRunner: UpdateToolRunning

    init(
        expectedBundleIdentifier: String,
        expectedTeamIdentifier: String,
        expectedVersion: String,
        toolRunner: UpdateToolRunning = UpdateProcessRunner()
    ) {
        self.expectedBundleIdentifier = expectedBundleIdentifier
        self.expectedTeamIdentifier = expectedTeamIdentifier
        self.expectedVersion = expectedVersion
        self.toolRunner = toolRunner
    }

    static func releaseVersion(fromTag tag: String) throws -> String {
        let pattern = #"^v[0-9]+\.[0-9]+\.[0-9]+$"#
        let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)
        let expression = try NSRegularExpression(pattern: pattern)
        guard expression.firstMatch(in: tag, range: range)?.range == range else {
            throw UpdateArtifactVerificationError.malformedReleaseTag
        }
        return String(tag.dropFirst())
    }

    static func expectedZIPName(for releaseVersion: String) -> String {
        "NotchFlow-v\(releaseVersion)-\(canonicalArchitecture).zip"
    }

    static func expectedDMGName(for releaseVersion: String) -> String {
        "NotchFlow-v\(releaseVersion)-\(canonicalArchitecture).dmg"
    }

    static func validateRefetchedReleaseVersion(
        _ fetchedVersion: String,
        advertisedVersion: String,
        currentVersion: String
    ) throws {
        guard (try? releaseVersion(fromTag: "v\(fetchedVersion)")) == fetchedVersion,
              (try? releaseVersion(fromTag: "v\(advertisedVersion)")) == advertisedVersion,
              fetchedVersion == advertisedVersion
        else {
            throw UpdateArtifactVerificationError.releaseChanged
        }
        guard isVersion(fetchedVersion, newerThan: currentVersion) else {
            throw UpdateArtifactVerificationError.releaseNotNewer
        }
    }

    static func selectZIPAsset(
        from assets: [UpdateReleaseAsset],
        releaseVersion: String
    ) throws -> UpdateReleaseAsset {
        let expectedName = expectedZIPName(for: releaseVersion)
        let matches = assets.filter { $0.name == expectedName }
        guard matches.count == 1, let asset = matches.first else {
            throw UpdateArtifactVerificationError.missingOrAmbiguousAsset
        }
        guard asset.downloadURL.scheme?.lowercased() == "https",
              let host = asset.downloadURL.host?.lowercased(),
              host == "github.com" || host == "api.github.com"
        else {
            throw UpdateArtifactVerificationError.invalidDownloadURL
        }
        return asset
    }

    func verify(appAt appURL: URL) throws {
        var isDirectory: ObjCBool = false
        guard appURL.pathExtension == "app",
              FileManager.default.fileExists(atPath: appURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw UpdateArtifactVerificationError.malformedBundle
        }

        let signature = try run(
            URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--verify", "--deep", "--strict", "--verbose=2", appURL.path]
        )
        guard signature.terminationStatus == 0 else {
            throw UpdateArtifactVerificationError.invalidSignature
        }

        let details = try run(
            URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["-dvvv", appURL.path]
        )
        guard details.terminationStatus == 0 else {
            throw UpdateArtifactVerificationError.invalidSignature
        }
        let signingOutput = details.standardOutput + "\n" + details.standardError
        let lines = signingOutput.split(whereSeparator: \Character.isNewline).map(String.init)
        guard lines.contains(where: { $0.hasPrefix("Authority=Developer ID Application:") }) else {
            throw UpdateArtifactVerificationError.wrongSigner
        }
        guard lines.contains("TeamIdentifier=\(expectedTeamIdentifier)") else {
            throw UpdateArtifactVerificationError.wrongTeamIdentifier
        }

        let assessment = try run(
            URL(fileURLWithPath: "/usr/sbin/spctl"),
            arguments: ["--assess", "--type", "execute", "--verbose=2", appURL.path]
        )
        guard assessment.terminationStatus == 0 else {
            throw UpdateArtifactVerificationError.gatekeeperRejected
        }

        let infoURL = appURL.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        guard let data = try? Data(contentsOf: infoURL),
              let info = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                as? [String: Any]
        else {
            throw UpdateArtifactVerificationError.malformedBundle
        }
        guard info["CFBundleIdentifier"] as? String == expectedBundleIdentifier else {
            throw UpdateArtifactVerificationError.wrongBundleIdentifier
        }
        guard info["CFBundleShortVersionString"] as? String == expectedVersion,
              info["CFBundleVersion"] as? String == expectedVersion
        else {
            throw UpdateArtifactVerificationError.wrongVersion
        }
    }

    private func run(_ executable: URL, arguments: [String]) throws -> UpdateToolResult {
        do {
            return try toolRunner.run(executable, arguments: arguments)
        } catch {
            throw UpdateArtifactVerificationError.toolLaunchFailed(error)
        }
    }

    private static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        guard let candidateComponents = numericVersionComponents(candidate),
              let currentComponents = numericVersionComponents(current)
        else { return false }
        for index in 0..<max(candidateComponents.count, currentComponents.count) {
            let candidatePart = index < candidateComponents.count ? candidateComponents[index] : 0
            let currentPart = index < currentComponents.count ? currentComponents[index] : 0
            if candidatePart != currentPart { return candidatePart > currentPart }
        }
        return false
    }

    private static func numericVersionComponents(_ version: String) -> [Int]? {
        let pattern = #"^[0-9]+(?:\.[0-9]+){0,2}$"#
        guard version.range(of: pattern, options: .regularExpression) != nil else { return nil }
        let pieces = version.split(separator: ".")
        let components = pieces.compactMap { Int($0) }
        return components.count == pieces.count ? components : nil
    }
}
