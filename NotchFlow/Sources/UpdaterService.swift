import AppKit
import SwiftUI

/// In-app self-updater. It accepts only the exact arm64 ZIP for an exact vX.Y.Z
/// release, validates the Developer ID identity and Gatekeeper assessment, then
/// performs a same-volume replacement with rollback.
///
/// Quietness is the contract: checks are silent and failures are swallowed —
/// the only signals are the dot on the settings gear and the Version row in
/// settings. An update cue must never interrupt hover-ask-leave.
///
/// Quarantine is never removed. macOS remains part of the trust decision for
/// both installer and updater downloads.
@MainActor
final class UpdaterService: ObservableObject {
    static let shared = UpdaterService()

    /// Where the update story currently is — drives the Version row and the gear dot.
    enum Phase: Equatable {
        case unknown            // never checked (or check failed): show just the version
        case upToDate           // checked; this build is the latest
        case available(String)  // a newer version (e.g. "1.0.2") is published
        case updating           // download/swap in flight
        case failed             // an attempted update failed; offer the releases page
    }

    @Published private(set) var phase: Phase = .unknown

    /// A user-initiated "Check for updates" in flight, and its momentary result.
    /// Separate from `phase` so the manual button can show a spinner and a brief
    /// "up to date" confirmation without touching the silent auto-check contract
    /// (which stays quiet — no "up to date" chrome unless the user asked).
    enum ManualCheck: Equatable {
        case idle       // no manual check happening; show the plain "Check for updates" link
        case checking   // request in flight — show a spinner
        case upToDate   // just confirmed current — show a fading "You're up to date"
    }

    @Published private(set) var manualCheck: ManualCheck = .idle

    /// The canonical, complete release-note history on the NotchFlow website.
    static let releaseNotesPage = URL(string: "https://www.notch.website/releases")!

    /// A release build may supply its verified GitHub owner/repository through
    /// Info.plist. There is intentionally no guessed fallback: an incorrect
    /// slug makes every check fail and its recovery link open a 404.
    private static var repository: String? {
        let value = (Bundle.main.object(forInfoDictionaryKey: "UpdateRepository") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    /// Only expose a GitHub destination once the release source has been
    /// explicitly configured. This keeps unrelated UI from recreating the
    /// invalid hard-coded repository link the updater intentionally avoids.
    static var repositoryPage: URL? {
        guard let repository else { return nil }
        return URL(string: "https://github.com/\(repository)")
    }

    static var issueTrackerPage: URL? {
        repositoryPage?.appendingPathComponent("issues")
    }

    private static func manualDMGURL(for version: String) -> URL? {
        guard let repository,
              (try? UpdateArtifactVerifier.releaseVersion(fromTag: "v\(version)")) == version
        else { return nil }
        let name = UpdateArtifactVerifier.expectedDMGName(for: version)
        return URL(string: "https://github.com/\(repository)/releases/download/v\(version)/\(name)")
    }

    private static var expectedTeamIdentifier: String? {
        let value = (Bundle.main.object(forInfoDictionaryKey: "UpdateTeamIdentifier") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let pattern = #"^[A-Z0-9]{10}$"#
        guard value.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return value
    }

    /// The running app's marketing version. CI stamps the release tag into
    /// Info.plist via `MARKETING_VERSION`; local builds carry the pbxproj value.
    /// `NOTCH_FAKE_VERSION` overrides it — debug aid for exercising the update
    /// flow against a real release without building an older binary.
    static var currentVersion: String {
        if let fake = ProcessInfo.processInfo.environment["NOTCH_FAKE_VERSION"], !fake.isEmpty {
            return fake
        }
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Optional GitHub token (`NOTCH_GITHUB_TOKEN` / `GITHUB_TOKEN`). Unauthenticated
    /// works once the repo is public; the token makes check + download work against
    /// the private repo (asset downloads there must go through the API URL).
    private static var token: String? {
        let env = ProcessInfo.processInfo.environment
        return env["NOTCH_GITHUB_TOKEN"] ?? env["GITHUB_TOKEN"]
    }

    private enum UpdateError: Error {
        case missingReleaseSource, badResponse, badArchive, toolFailed
    }

    // MARK: - Check

    private let lastCheckKey = "updater_last_check"
    private var checking = false
    /// A release lookup is tiny and should finish quickly. Without an explicit
    /// bound, `URLSession` can leave the manual spinner up for its much longer
    /// default timeout when GitHub or a configured proxy is unreachable.
    private static let checkTimeout: TimeInterval = 10

    /// Silent daily check — called at launch and whenever the panel opens, so a
    /// long-running agent still notices releases. Throttled to once per 24h.
    func checkIfDue() {
        if let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date,
           Date().timeIntervalSince(last) < 24 * 3600 {
            return
        }
        check()
    }

    /// Un-throttled check — run when settings opens, so the Version row reflects
    /// reality while the user is actually looking at it. A failed request is
    /// visible: a broken release endpoint must not look like an idle updater.
    func check() {
        guard !checking, !demoPinned, phase != .updating else { return }
        checking = true
        Task {
            defer { checking = false }
            let release: Release
            do {
                release = try await Self.fetchLatest()
            } catch {
                guard phase != .updating else { return }
                phase = .failed
                return
            }
            UserDefaults.standard.set(Date(), forKey: lastCheckKey)
            // A check landing mid-update must not flip the phase under the swap.
            guard phase != .updating else { return }
            let latest = release.version
            phase = Self.isNewer(latest, than: Self.currentVersion)
                ? .available(latest)
                : .upToDate
        }
    }

    /// User-initiated check — the "Check for updates" button. Same request as
    /// `check()`, but surfaces feedback the silent path deliberately hides: a
    /// spinner while it runs, and a momentary "up to date" when this is already
    /// the latest. If a newer version turns up, `phase` flips to `.available` and
    /// the normal Update button takes over (no separate confirmation needed).
    func checkManually() {
        guard manualCheck != .checking, phase != .updating else { return }
        manualCheck = .checking
        Task {
            // Keep the spinner up for a beat even on a cached/instant response,
            // so the check reads as an action that happened rather than a flash.
            async let minDwell: () = Self.sleep(nanoseconds: 650_000_000)
            let release: Release?
            do {
                release = try await Self.fetchLatest()
            } catch {
                release = nil
            }
            await minDwell
            // A real update superseding the check mid-flight wins.
            guard phase != .updating else { manualCheck = .idle; return }
            guard let release else {
                // The request was explicit, so never turn a broken endpoint
                // into a convincing idle button.
                phase = .failed
                manualCheck = .idle
                return
            }
            UserDefaults.standard.set(Date(), forKey: lastCheckKey)
            let latest = release.version
            if Self.isNewer(latest, than: Self.currentVersion) {
                phase = .available(latest)
                manualCheck = .idle       // the Update button now carries the signal
            } else {
                phase = .upToDate
                manualCheck = .upToDate    // the UI clears this back to .idle after a beat
            }
        }
    }

    /// Dismiss the momentary "up to date" confirmation, returning the button to
    /// its resting "Check for updates" label. The view schedules this after a
    /// short delay so the reassurance shows, then quietly recedes.
    func clearManualConfirmation() {
        if manualCheck == .upToDate { manualCheck = .idle }
    }

    /// Non-throwing sleep — swallows the cancellation error so callers can
    /// `await` it as plain `Void` (used to floor the manual-check spinner time).
    private static func sleep(nanoseconds: UInt64) async {
        try? await Task.sleep(nanoseconds: nanoseconds)
    }

    #if DEBUG
    /// Screenshot aid (`NOTCH_DEMO_UPDATE=<version>`): pin the phase to "a build
    /// is waiting" without a real release to find. The pin also mutes the real
    /// checks, which would otherwise flip the phase back to `.upToDate` a second
    /// or two later, mid-pose. Debug builds only — see `AppDelegate`.
    func _debugPinAvailable(_ version: String) {
        demoPinned = true
        phase = .available(version)
    }
    private var demoPinned = false
    #else
    private let demoPinned = false
    #endif

    /// Numeric dot-component comparison: "1.0.10" beats "1.0.9", "1.1" beats "1.0.2".
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Update

    /// Download the latest release and swap it in. Runs the file work off the
    /// main actor; on success the app relaunches itself (this call never returns
    /// to a UI that needs cleaning up), on failure the old bundle is rolled back
    /// and the Version row shows the releases-page fallback.
    func update() {
        guard case .available(let advertisedVersion) = phase else { return }
        guard let manualDMGURL = Self.manualDMGURL(for: advertisedVersion),
              let teamIdentifier = Self.expectedTeamIdentifier
        else {
            phase = .failed
            return
        }
        let installPlan = UpdateInstallPlanner.plan(
            runningBundleURL: Bundle.main.bundleURL,
            manualDMGURL: manualDMGURL
        )
        guard case .automatic(let destination, let stagingParent) = installPlan else {
            if case .manualDMG(let url, _) = installPlan {
                NSWorkspace.shared.open(url)
            }
            phase = .failed
            return
        }
        phase = .updating
        Task {
            do {
                let release = try await Self.fetchLatest()
                try UpdateArtifactVerifier.validateRefetchedReleaseVersion(
                    release.version,
                    advertisedVersion: advertisedVersion,
                    currentVersion: Self.currentVersion
                )
                let asset = try release.zipAsset(preferAPIURL: Self.token != nil)

                let (tmp, resp) = try await ProxyConfig.urlSession.download(
                    for: Self.request(asset.downloadURL, accept: "application/octet-stream"))
                guard (resp as? HTTPURLResponse)?.statusCode == 200,
                      resp.url?.scheme?.lowercased() == "https"
                else {
                    throw UpdateError.badResponse
                }
                // URLSession's temp file may be reclaimed once this scope moves
                // on — park the zip somewhere stable before the detached work.
                let zip = tmp.deletingLastPathComponent()
                    .appendingPathComponent("notch-update-\(ProcessInfo.processInfo.globallyUniqueString).zip")
                try FileManager.default.moveItem(at: tmp, to: zip)

                try await Task.detached(priority: .userInitiated) {
                    try Self.swapBundle(
                        zip: zip,
                        destination: destination,
                        stagingParent: stagingParent,
                        version: release.version,
                        teamIdentifier: teamIdentifier
                    )
                }.value
                try Self.relaunch(destination)
            } catch {
                phase = .failed
            }
        }
    }

    // MARK: - GitHub API

    private struct Release: Decodable {
        let version: String
        let assets: [Asset]

        private enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }

        struct Asset: Decodable {
            let name: String
            let url: String                    // API asset URL (token path)
            let browser_download_url: String   // public download URL
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let tag = try container.decode(String.self, forKey: .tagName)
            version = try UpdateArtifactVerifier.releaseVersion(fromTag: tag)
            assets = try container.decode([Asset].self, forKey: .assets)
        }

        func zipAsset(preferAPIURL: Bool) throws -> UpdateReleaseAsset {
            let expectedName = UpdateArtifactVerifier.expectedZIPName(for: version)
            let matching = assets.filter { $0.name == expectedName }
            guard matching.count == 1, let rawAsset = matching.first,
                  let downloadURL = URL(string: preferAPIURL ? rawAsset.url : rawAsset.browser_download_url)
            else {
                throw UpdateArtifactVerificationError.missingOrAmbiguousAsset
            }
            return try UpdateArtifactVerifier.selectZIPAsset(
                from: [UpdateReleaseAsset(name: rawAsset.name, downloadURL: downloadURL)],
                releaseVersion: version
            )
        }
    }

    private static func request(_ url: URL, accept: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue(accept, forHTTPHeaderField: "Accept")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return req
    }

    private static func fetchLatest() async throws -> Release {
        guard let repository else { throw UpdateError.missingReleaseSource }
        let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        var req = request(url, accept: "application/vnd.github+json")
        req.timeoutInterval = checkTimeout
        let (data, resp) = try await ProxyConfig.urlSession.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError.badResponse
        }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    // MARK: - Swap & relaunch

    /// Extract on the destination volume, verify the exact root app, then run
    /// the planner's backup/replacement transaction. No destination path is
    /// changed until the candidate has passed every trust and metadata check.
    private nonisolated static func swapBundle(
        zip: URL,
        destination: URL,
        stagingParent: URL,
        version: String,
        teamIdentifier: String
    ) throws {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: zip) }
        let work = try UpdateInstallPlanner.makeStagingDirectory(
            in: stagingParent,
            fileManager: fm
        )
        defer { try? fm.removeItem(at: work) }

        let extracted = work.appendingPathComponent("extracted", isDirectory: true)
        try runTool("/usr/bin/ditto", "-x", "-k", zip.path, extracted.path)
        let staged = extracted.appendingPathComponent("NotchFlow.app", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: staged.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw UpdateError.badArchive
        }

        let verifier = UpdateArtifactVerifier(
            expectedBundleIdentifier: UpdateArtifactVerifier.bundleIdentifier,
            expectedTeamIdentifier: teamIdentifier,
            expectedVersion: version
        )
        try UpdateInstallPlanner.replaceInstalledBundle(
            with: staged,
            at: destination,
            fileManager: fm,
            verifier: verifier.verify(appAt:)
        )
    }

    private nonisolated static func runTool(_ path: String, _ args: String...) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError.toolFailed }
    }

    /// Ask LaunchServices for a distinct process using structured arguments;
    /// never interpolate an app path into a shell command.
    private static func relaunch(_ bundle: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", bundle.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        NSApp.terminate(nil)
    }
}
