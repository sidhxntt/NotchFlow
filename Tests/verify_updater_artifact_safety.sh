#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/UpdaterArtifactSafetyTests.swift" <<'SWIFT'
import Foundation

private let expectedBundleID = "com.notchflow.app"
private let expectedTeamID = "NQ55M2U74M"
private let expectedVersion = "1.2.3"

private enum TestFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case .assertion(let message): return message
        }
    }
}

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw TestFailure.assertion(message) }
}

private func requireThrows(_ message: String, _ operation: () throws -> Void) throws {
    do {
        try operation()
        throw TestFailure.assertion(message)
    } catch is TestFailure {
        throw TestFailure.assertion(message)
    } catch {
        return
    }
}

private func makeApp(
    at url: URL,
    bundleID: String = expectedBundleID,
    version: String = expectedVersion,
    marker: String
) throws {
    let contents = url.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let info: [String: Any] = [
        "CFBundleIdentifier": bundleID,
        "CFBundleShortVersionString": version,
        "CFBundleVersion": version,
        "CFBundlePackageType": "APPL"
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try data.write(to: contents.appendingPathComponent("Info.plist"))
    try Data(marker.utf8).write(to: contents.appendingPathComponent("marker"))
}

private func marker(in app: URL) throws -> String {
    try String(contentsOf: app.appendingPathComponent("Contents/marker"), encoding: .utf8)
}

private final class FakeToolRunner: UpdateToolRunning {
    var calls: [(String, [String])] = []
    var signatureStatus: Int32 = 0
    var gatekeeperStatus: Int32 = 0
    var teamIdentifier = expectedTeamID
    var authority = "Developer ID Application: NotchFlow (\(expectedTeamID))"

    func run(_ executable: URL, arguments: [String]) throws -> UpdateToolResult {
        calls.append((executable.path, arguments))
        if executable.path == "/usr/bin/codesign", arguments.first == "--verify" {
            return UpdateToolResult(terminationStatus: signatureStatus, standardOutput: "", standardError: "")
        }
        if executable.path == "/usr/bin/codesign" {
            return UpdateToolResult(
                terminationStatus: 0,
                standardOutput: "",
                standardError: "Authority=\(authority)\nTeamIdentifier=\(teamIdentifier)\n"
            )
        }
        if executable.path == "/usr/sbin/spctl" {
            return UpdateToolResult(
                terminationStatus: gatekeeperStatus,
                standardOutput: "",
                standardError: gatekeeperStatus == 0 ? "accepted" : "rejected"
            )
        }
        throw TestFailure.assertion("Unexpected tool: \(executable.path)")
    }
}

private func verifier(runner: FakeToolRunner) -> UpdateArtifactVerifier {
    UpdateArtifactVerifier(
        expectedBundleIdentifier: expectedBundleID,
        expectedTeamIdentifier: expectedTeamID,
        expectedVersion: expectedVersion,
        toolRunner: runner
    )
}

private func testExactReleaseSelection() throws {
    try require(try UpdateArtifactVerifier.releaseVersion(fromTag: "v1.2.3") == "1.2.3", "valid release tag was not parsed")
    for malformed in ["1.2.3", "v1.2", "v1.2.3-beta", "v1.2.3/../../bad"] {
        try requireThrows("malformed tag was accepted: \(malformed)") {
            _ = try UpdateArtifactVerifier.releaseVersion(fromTag: malformed)
        }
    }

    let wanted = UpdateReleaseAsset(
        name: "NotchFlow-v1.2.3-arm64.zip",
        downloadURL: URL(string: "https://github.com/sidhxntt/NotchFlow/releases/download/v1.2.3/NotchFlow-v1.2.3-arm64.zip")!
    )
    let assets = [
        UpdateReleaseAsset(name: "NotchFlow-v1.2.3.zip", downloadURL: URL(string: "https://example.invalid/no.zip")!),
        UpdateReleaseAsset(name: "NotchFlow-v1.2.4-arm64.zip", downloadURL: URL(string: "https://example.invalid/wrong.zip")!),
        UpdateReleaseAsset(name: "renamed-NotchFlow-v1.2.3-arm64.zip", downloadURL: URL(string: "https://example.invalid/suffix.zip")!),
        wanted
    ]
    try require(try UpdateArtifactVerifier.selectZIPAsset(from: assets, releaseVersion: expectedVersion) == wanted, "did not select only the exact arm64 ZIP")
    try requireThrows("a suffix-matching ZIP was accepted") {
        _ = try UpdateArtifactVerifier.selectZIPAsset(from: Array(assets.dropLast()), releaseVersion: expectedVersion)
    }
    try requireThrows("duplicate exact ZIP assets were accepted") {
        _ = try UpdateArtifactVerifier.selectZIPAsset(from: [wanted, wanted], releaseVersion: expectedVersion)
    }
    try requireThrows("matching ZIP from an untrusted host was accepted") {
        _ = try UpdateArtifactVerifier.selectZIPAsset(
            from: [UpdateReleaseAsset(name: wanted.name, downloadURL: URL(string: "https://attacker.invalid/update.zip")!)],
            releaseVersion: expectedVersion
        )
    }
}

private func testRefetchedReleaseMustMatchAdvertisedVersion() throws {
    try requireThrows("a newer latest release replaced the version the user clicked") {
        try UpdateArtifactVerifier.validateRefetchedReleaseVersion(
            "1.2.4",
            advertisedVersion: "1.2.3",
            currentVersion: "1.2.2"
        )
    }
    try requireThrows("a refetched release that is no longer newer was accepted") {
        try UpdateArtifactVerifier.validateRefetchedReleaseVersion(
            "1.2.3",
            advertisedVersion: "1.2.3",
            currentVersion: "1.2.3"
        )
    }
    try requireThrows("an older refetched release was accepted") {
        try UpdateArtifactVerifier.validateRefetchedReleaseVersion(
            "1.2.1",
            advertisedVersion: "1.2.1",
            currentVersion: "1.2.2"
        )
    }
    try requireThrows("an unparseable running version was treated as older") {
        try UpdateArtifactVerifier.validateRefetchedReleaseVersion(
            "1.2.3",
            advertisedVersion: "1.2.3",
            currentVersion: "999999999999999999999999999999"
        )
    }
    try UpdateArtifactVerifier.validateRefetchedReleaseVersion(
        "1.2.3",
        advertisedVersion: "1.2.3",
        currentVersion: "1.2.2"
    )
}

private func assertRejectedCandidateLeavesOldApp(
    root: URL,
    name: String,
    runner: FakeToolRunner,
    bundleID: String = expectedBundleID,
    version: String = expectedVersion
) throws {
    let destination = root.appendingPathComponent("\(name)-installed.app")
    let candidate = root.appendingPathComponent("\(name)-candidate.app")
    try makeApp(at: destination, marker: "old")
    try makeApp(at: candidate, bundleID: bundleID, version: version, marker: "new")

    try requireThrows("\(name) candidate unexpectedly replaced the app") {
        try UpdateInstallPlanner.replaceInstalledBundle(
            with: candidate,
            at: destination,
            verifier: { try verifier(runner: runner).verify(appAt: $0) }
        )
    }
    try require(try marker(in: destination) == "old", "\(name) failure mutated the installed app")
}

private func testVerificationAndNoPrematureMutation(root: URL) throws {
    try assertRejectedCandidateLeavesOldApp(root: root, name: "wrong-bundle", runner: FakeToolRunner(), bundleID: "com.attacker.app")
    try assertRejectedCandidateLeavesOldApp(root: root, name: "wrong-version", runner: FakeToolRunner(), version: "9.9.9")

    let wrongTeam = FakeToolRunner()
    wrongTeam.teamIdentifier = "AAAAAAAAAA"
    try assertRejectedCandidateLeavesOldApp(root: root, name: "wrong-team", runner: wrongTeam)

    let wrongSigner = FakeToolRunner()
    wrongSigner.authority = "Apple Development: Someone Else (\(expectedTeamID))"
    try assertRejectedCandidateLeavesOldApp(root: root, name: "wrong-signer", runner: wrongSigner)

    let invalidSignature = FakeToolRunner()
    invalidSignature.signatureStatus = 1
    try assertRejectedCandidateLeavesOldApp(root: root, name: "invalid-signature", runner: invalidSignature)
    try require(invalidSignature.calls.count == 1, "metadata or Gatekeeper was consulted after signature verification failed")

    let gatekeeperRejected = FakeToolRunner()
    gatekeeperRejected.gatekeeperStatus = 1
    try assertRejectedCandidateLeavesOldApp(root: root, name: "gatekeeper", runner: gatekeeperRejected)

    let malformedDestination = root.appendingPathComponent("malformed-installed.app")
    let malformedCandidate = root.appendingPathComponent("malformed-candidate.app")
    try makeApp(at: malformedDestination, marker: "old")
    try FileManager.default.createDirectory(at: malformedCandidate, withIntermediateDirectories: true)
    let malformedRunner = FakeToolRunner()
    try requireThrows("malformed app was accepted") {
        try UpdateInstallPlanner.replaceInstalledBundle(
            with: malformedCandidate,
            at: malformedDestination,
            verifier: { try verifier(runner: malformedRunner).verify(appAt: $0) }
        )
    }
    try require(try marker(in: malformedDestination) == "old", "malformed archive mutated the installed app")

    let destination = root.appendingPathComponent("success-installed.app")
    let candidate = root.appendingPathComponent("success-candidate.app")
    try makeApp(at: destination, marker: "old")
    try makeApp(at: candidate, marker: "new")
    let successRunner = FakeToolRunner()
    try UpdateInstallPlanner.replaceInstalledBundle(
        with: candidate,
        at: destination,
        verifier: { try verifier(runner: successRunner).verify(appAt: $0) }
    )
    try require(try marker(in: destination) == "new", "verified candidate was not installed")
    try require(!successRunner.calls.contains(where: { $0.0 == "/usr/bin/xattr" }), "updater attempted to strip quarantine")
}

private func testInstallPlanning(root: URL) throws {
    let manualURL = URL(string: "https://github.com/sidhxntt/NotchFlow/releases/latest")!

    switch UpdateInstallPlanner.plan(
        runningBundleURL: URL(fileURLWithPath: "/Volumes/NotchFlow/NotchFlow.app"),
        manualDMGURL: manualURL
    ) {
    case .manualDMG(let url, .mountedVolume): try require(url == manualURL, "mounted-volume fallback URL changed")
    default: throw TestFailure.assertion("mounted app was offered automatic replacement")
    }

    switch UpdateInstallPlanner.plan(
        runningBundleURL: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/NotchFlow.app"),
        manualDMGURL: manualURL
    ) {
    case .manualDMG(_, .translocated): break
    default: throw TestFailure.assertion("translocated app was offered automatic replacement")
    }

    let app = root.appendingPathComponent("automatic/NotchFlow.app")
    try makeApp(at: app, marker: "old")
    switch UpdateInstallPlanner.plan(runningBundleURL: app, manualDMGURL: manualURL) {
    case .automatic(let destination, let stagingParent):
        try require(destination == app, "automatic destination changed")
        try require(stagingParent == app.deletingLastPathComponent(), "staging is not on the destination volume")
    default:
        throw TestFailure.assertion("writable installed app did not produce an automatic plan")
    }

    var preflight = UpdateInstallPreflight.live
    preflight.isWritable = { _ in false }
    switch UpdateInstallPlanner.plan(runningBundleURL: app, manualDMGURL: manualURL, preflight: preflight) {
    case .manualDMG(_, .notWritable): break
    default: throw TestFailure.assertion("unwritable app was offered automatic replacement")
    }

    preflight = .live
    preflight.isReadOnlyVolume = { _ in true }
    switch UpdateInstallPlanner.plan(runningBundleURL: app, manualDMGURL: manualURL, preflight: preflight) {
    case .manualDMG(_, .readOnlyVolume): break
    default: throw TestFailure.assertion("read-only volume was offered automatic replacement")
    }
}

@main
private struct UpdaterArtifactSafetyTests {
    static func main() throws {
        try testExactReleaseSelection()
        try testRefetchedReleaseMustMatchAdvertisedVersion()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("updater-artifact-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try testVerificationAndNoPrematureMutation(root: root)
        try testInstallPlanning(root: root)
        print("Updater artifact safety checks passed")
    }
}
SWIFT

SWIFT_MODULECACHE_PATH="$TMP/module-cache" \
CLANG_MODULE_CACHE_PATH="$TMP/module-cache" \
swiftc \
  "$ROOT/NotchFlow/Sources/UpdateArtifactVerifier.swift" \
  "$ROOT/NotchFlow/Sources/UpdateInstallPlanner.swift" \
  "$TMP/UpdaterArtifactSafetyTests.swift" \
  -o "$TMP/updater-artifact-safety-tests"

"$TMP/updater-artifact-safety-tests"
