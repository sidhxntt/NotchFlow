import AppKit
import Foundation

public enum MediaCommand: Equatable, Sendable {
    case playPause, next, previous
    case seek(TimeInterval)
    case setVolume(Double)
}

@MainActor
public protocol MediaControlling: AnyObject {
    var source: MediaSource { get }
    var state: MediaState { get }
    func refresh() async -> MediaState
    func perform(_ command: MediaCommand) async
}

/// Poll player metadata at the rate users can perceive while a track is active,
/// but do not keep sending Apple events to an idle player every capability tick.
public struct MediaRefreshPolicy: Sendable {
    public let activeInterval: TimeInterval
    public let idleInterval: TimeInterval

    public init(activeInterval: TimeInterval = 1, idleInterval: TimeInterval = 5) {
        self.activeInterval = activeInterval
        self.idleInterval = idleInterval
    }

    public func shouldPoll(lastState: MediaState, lastPolledAt: Date?, now: Date = .now) -> Bool {
        guard let lastPolledAt else { return true }
        let interval = lastState.isActive ? activeInterval : idleInterval
        return max(0, now.timeIntervalSince(lastPolledAt)) >= interval
    }
}

@MainActor
protocol MediaErrorReporting: AnyObject {
    var mediaError: String? { get }
}

/// Coordinates player controllers through NotchFlow's single state store.
/// The active audible controller wins unless a caller has explicitly pinned a source.
@MainActor
public final class MediaCapabilityService {
    private var controllers: [any MediaControlling]
    private var pinnedSource: MediaSource?
    public private(set) var state: MediaState = .inactive
    /// A playback command or Automation request can fail while the media state
    /// remains valid. Keep the reason separate so the UI never has to pretend a
    /// blank player means nothing happened.
    public private(set) var mediaError: String?

    public init(controllers: [any MediaControlling]? = nil) {
        if let controllers {
            self.controllers = controllers
        } else {
            self.controllers = [
                AppleScriptMediaController(source: .appleMusic),
                AppleScriptMediaController(source: .spotify)
            ]
        }
    }

    public func refresh() async -> MediaState {
        var candidates: [MediaState] = []
        for controller in controllers {
            candidates.append(await controller.refresh())
        }
        mediaError = controllers.compactMap { ($0 as? any MediaErrorReporting)?.mediaError }.first
        if let pinnedSource, let pinned = candidates.first(where: { $0.source == pinnedSource }) {
            state = pinned
        } else {
            let playing = candidates.filter(\.isActive)
            let visible = playing.isEmpty ? candidates.filter(\.hasTrack) : playing
            state = visible.max(by: Self.ranksBelow) ?? .inactive
        }
        return state
    }

    /// Which of two candidates the notch should show. A dedicated player only
    /// outranks a browser session while it is actually doing something more
    /// recent than the browser: AppleScript's `current track` stays populated
    /// in Music.app for days after playback stops, so an unconditional
    /// dedicated-wins rule would let a stale Music.app window beat a browser
    /// tab that was playing moments ago and has only just paused. Starting
    /// Spotify (or Music) still hands over the notch immediately, since a
    /// dedicated source that is actually playing always wins. Within the same
    /// rank, or when neither dedicated source is playing, the most recently
    /// audible one wins, as before.
    static func ranksBelow(_ lhs: MediaState, _ rhs: MediaState) -> Bool {
        let lhsDedicated = lhs.source != .nowPlaying
        let rhsDedicated = rhs.source != .nowPlaying
        if lhsDedicated != rhsDedicated {
            let dedicated = lhsDedicated ? lhs : rhs
            let browser = lhsDedicated ? rhs : lhs
            let dedicatedWins = dedicated.isPlaying || dedicated.lastAudibleAt > browser.lastAudibleAt
            return lhsDedicated ? !dedicatedWins : dedicatedWins
        }
        return lhs.lastAudibleAt < rhs.lastAudibleAt
    }

    public func select(_ source: MediaSource?) async {
        pinnedSource = source
        _ = await refresh()
    }

    public func perform(_ command: MediaCommand) async {
        let target = controllers.first(where: { $0.source == state.source }) ?? controllers.first
        guard let target else { return }
        await target.perform(command)
        state = await target.refresh()
        mediaError = (target as? any MediaErrorReporting)?.mediaError
    }

    public func launch(_ source: MediaSource) {
        let target = source.launchTarget
        if let identifier = target.applicationBundleIdentifier,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, _ in }
        } else if let url = target.fallbackURL {
            NSWorkspace.shared.open(url)
        }
    }
}

/// AppleScript controls for Spotify and Apple Music.
@MainActor
public final class AppleScriptMediaController: MediaControlling, MediaErrorReporting {
    private static let maximumArtworkBytes = 4 * 1024 * 1024

    private struct PlaybackSnapshot: Sendable {
        let isPlaying: Bool
        let title: String
        let artist: String
        let album: String
        let position: Double
        let duration: Double
        let volume: Double
    }
    private struct PlaybackResult: Sendable {
        let snapshot: PlaybackSnapshot?
        let error: String?
    }

    public let source: MediaSource
    public private(set) var state: MediaState
    public private(set) var mediaError: String?

    /// The cover for `artworkTrack`, fetched from the player itself. Spotify
    /// exposes an image URL; Music exposes the raw bytes.
    private var artwork: Data?
    /// The track the cached cover belongs to — "title|album", so the fetch runs
    /// once per track rather than on every one-second refresh.
    private var artworkTrack: String?
    private let session: URLSession
    private let refreshPolicy: MediaRefreshPolicy
    private var lastPolledAt: Date?

    public init(source: MediaSource, session: URLSession = .shared,
                refreshPolicy: MediaRefreshPolicy = .init()) {
        self.source = source
        self.session = session
        self.refreshPolicy = refreshPolicy
        self.state = MediaState(source: source)
    }

    public func refresh() async -> MediaState {
        let bundleID = source == .spotify ? "com.spotify.client" : "com.apple.Music"
        guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleID }) else {
            state = MediaState(source: source)
            artwork = nil
            artworkTrack = nil
            lastPolledAt = nil
            return state
        }
        guard refreshPolicy.shouldPoll(lastState: state, lastPolledAt: lastPolledAt) else {
            return state
        }
        lastPolledAt = .now
        let script: String
        if source == .spotify {
            script = """
            tell application "Spotify"
                try
                    set t to current track
                    return {(player state is playing), name of t, artist of t, album of t, player position, (duration of t) / 1000, sound volume}
                on error errMsg number errNum
                    return {"__notch_error__", errNum, errMsg}
                end try
            end tell
            """
        } else {
            script = """
            tell application "Music"
                try
                    set t to current track
                    return {(player state is playing), name of t, artist of t, album of t, player position, duration of t, sound volume}
                on error errMsg number errNum
                    return {"__notch_error__", errNum, errMsg}
                end try
            end tell
            """
        }
        // NSAppleScript performs a synchronous Apple event. It may wait for a
        // busy player or Automation consent, so never run it on the UI actor.
        let result = await Task.detached(priority: .userInitiated) {
            Self.playbackResult(script)
        }.value
        if let error = result.error { mediaError = error }
        guard let snapshot = result.snapshot else {
            // A player with no current track reports an AppleScript error. That
            // is an inactive state, not a reason to leave yesterday's song up.
            if result.error == nil { state = MediaState(source: source) }
            return state
        }
        let playing = snapshot.isPlaying
        let title = snapshot.title
        let album = snapshot.album
        await refreshArtwork(title: title, album: album)
        state = MediaState(source: source,
                           title: title,
                           artist: snapshot.artist,
                           album: album,
                           isPlaying: playing,
                           position: snapshot.position,
                           duration: snapshot.duration,
                           volume: snapshot.volume,
                           artworkData: artwork,
                           lastAudibleAt: playing ? .now : state.lastAudibleAt)
        mediaError = nil
        return state
    }

    /// Fetches the cover once per track. A failure caches `nil` for that track
    /// rather than retrying every second.
    private func refreshArtwork(title: String, album: String) async {
        guard !title.isEmpty else {
            artwork = nil
            artworkTrack = nil
            return
        }
        let track = "\(title)|\(album)"
        guard artworkTrack != track else { return }
        artworkTrack = track
        artwork = source == .spotify ? await spotifyArtwork() : await musicArtwork()
    }

    /// Spotify hands out an image URL (`https://i.scdn.co/image/…`), so the cover
    /// is one small download — cached against the track above.
    private func spotifyArtwork() async -> Data? {
        let script = "tell application \"Spotify\" to return artwork url of current track"
        let raw = await Task.detached(priority: .utility) {
            Self.runScalar(script)?.stringValue
        }.value
        guard let raw, let url = URL(string: raw), url.scheme?.hasPrefix("http") == true else { return nil }
        guard let (data, _) = try? await session.data(from: url), !data.isEmpty else { return nil }
        return data.count <= Self.maximumArtworkBytes ? data : nil
    }

    /// Music keeps the image locally, so its bytes come straight back over the
    /// Apple event — no network at all.
    private func musicArtwork() async -> Data? {
        let script = """
        tell application "Music"
            try
                return raw data of artwork 1 of current track
            on error
                return missing value
            end try
        end tell
        """
        let data = await Task.detached(priority: .utility) {
            Self.runScalar(script)?.data
        }.value
        guard let data, !data.isEmpty else { return nil }
        return data.count <= Self.maximumArtworkBytes ? data : nil
    }

    public func perform(_ command: MediaCommand) async {
        let appName = source == .spotify ? "Spotify" : "Music"
        let action: String = switch command {
        case .playPause: "playpause"
        case .next: "next track"
        case .previous: "previous track"
        case .seek(let time): "set player position to \(max(0, time))"
        case .setVolume(let volume): "set sound volume to \(Int(max(0, min(1, volume)) * 100))"
        }
        let script = "tell application \"\(appName)\" to \(action)"
        let error = await Task.detached(priority: .userInitiated) {
            Self.automationError(from: script)
        }.value
        mediaError = error
        // A user action is the one situation in which an idle poll must not
        // wait for its backoff interval before the notch reflects the result.
        lastPolledAt = nil
    }

    nonisolated private static func playbackResult(_ source: String) -> PlaybackResult {
        guard let values = run(source) else { return .init(snapshot: nil, error: nil) }
        if values.count == 3, values[0].stringValue == "__notch_error__" {
            let code = values[1].int32Value
            return .init(snapshot: nil, error: code == -1743
                         ? "Allow NotchFlow to control the player in System Settings → Privacy & Security → Automation."
                         : nil)
        }
        guard values.count == 7 else { return .init(snapshot: nil, error: nil) }
        return .init(snapshot: PlaybackSnapshot(isPlaying: values[0].booleanValue,
                                                title: values[1].stringValue ?? "",
                                                artist: values[2].stringValue ?? "",
                                                album: values[3].stringValue ?? "",
                                                position: values[4].doubleValue,
                                                duration: values[5].doubleValue,
                                                volume: Double(values[6].int32Value) / 100),
                     error: nil)
    }

    nonisolated private static func automationError(from source: String) -> String? {
        var error: NSDictionary?
        _ = NSAppleScript(source: source)?.executeAndReturnError(&error)
        let code = error?[NSAppleScript.errorNumber] as? Int
        let message = error?[NSAppleScript.errorMessage] as? String ?? ""
        return messageForAutomationFailure(message, code: code)
    }

    nonisolated private static func messageForAutomationFailure(_ message: String, code: Int?) -> String? {
        guard code == -1743 else { return nil }
        return "Allow NotchFlow to control the player in System Settings → Privacy & Security → Automation."
    }

    nonisolated private static func run(_ source: String) -> [NSAppleEventDescriptor]? {
        guard let result = runScalar(source) else { return nil }
        return Self.listItems(from: result)
    }

    /// The raw descriptor, for scripts that answer with ONE value (an artwork URL
    /// string, a blob of image bytes). `listItems` would flatten those to an
    /// empty array — a scalar reports no items.
    nonisolated private static func runScalar(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error),
              error == nil else { return nil }
        return result
    }

    /// Playback commands return a scalar descriptor (often `null`), whereas a
    /// metadata refresh returns an AppleScript list. Never index a scalar result:
    /// AppKit traps on the invalid one-based index and terminates the app.
    nonisolated static func listItems(from result: NSAppleEventDescriptor) -> [NSAppleEventDescriptor] {
        guard result.numberOfItems > 0 else { return [] }
        return (1...result.numberOfItems).compactMap { result.atIndex($0) }
    }
}
