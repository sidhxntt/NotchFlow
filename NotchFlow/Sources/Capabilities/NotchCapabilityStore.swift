import Combine
import Foundation

public struct MediaLaunchTarget: Equatable, Sendable {
    public let applicationBundleIdentifier: String?
    public let fallbackURL: URL?

    public init(applicationBundleIdentifier: String?, fallbackURL: URL?) {
        self.applicationBundleIdentifier = applicationBundleIdentifier
        self.fallbackURL = fallbackURL
    }
}

public enum MediaSource: String, CaseIterable, Codable, Sendable {
    case appleMusic
    case spotify
    case nowPlaying
    /// Retained only to decode a preference written by older releases. YouTube
    /// Music runs inside a browser, so it cannot be a distinct system media
    /// source; its playback is covered by `.nowPlaying`.
    case youtubeMusic

    /// Sources the Follow player setting can genuinely pin. Browser sites are
    /// deliberately absent: macOS exposes their active media as one shared
    /// system-wide Now Playing session.
    public static let allCases: [MediaSource] = [.appleMusic, .spotify, .nowPlaying]

    public var displayName: String {
        switch self {
        case .appleMusic: "Apple Music"
        case .spotify: "Spotify"
        case .nowPlaying: "Now Playing"
        case .youtubeMusic: "YouTube Music"
        }
    }

    public var applicationBundleIdentifier: String? {
        launchTarget.applicationBundleIdentifier
    }

    public var webLaunchURL: URL? {
        launchTarget.fallbackURL
    }

    public var launchTarget: MediaLaunchTarget {
        switch self {
        case .appleMusic: MediaLaunchTarget(applicationBundleIdentifier: "com.apple.Music", fallbackURL: URL(string: "https://music.apple.com"))
        case .spotify: MediaLaunchTarget(applicationBundleIdentifier: "com.spotify.client", fallbackURL: URL(string: "https://open.spotify.com"))
        case .youtubeMusic: MediaLaunchTarget(applicationBundleIdentifier: nil, fallbackURL: URL(string: "https://music.youtube.com"))
        case .nowPlaying: MediaLaunchTarget(applicationBundleIdentifier: nil, fallbackURL: nil)
        }
    }
}

public struct MediaState: Equatable, Sendable {
    public var source: MediaSource
    public var title: String
    public var artist: String
    public var album: String
    public var isPlaying: Bool
    public var position: TimeInterval
    public var duration: TimeInterval
    public var volume: Double
    public var artworkData: Data?
    public var lastAudibleAt: Date
    /// The app that owns a system now-playing session. Native player states
    /// leave this nil and use their source's ordinary launch target instead.
    public var originatingApplicationBundleIdentifier: String?

    public init(source: MediaSource, title: String = "", artist: String = "", album: String = "", isPlaying: Bool = false, position: TimeInterval = 0, duration: TimeInterval = 0, volume: Double = 0.5, artworkData: Data? = nil, lastAudibleAt: Date = .distantPast, originatingApplicationBundleIdentifier: String? = nil) {
        self.source = source
        self.title = title
        self.artist = artist
        self.album = album
        self.isPlaying = isPlaying
        self.position = position
        self.duration = duration
        self.volume = volume
        self.artworkData = artworkData
        self.lastAudibleAt = lastAudibleAt
        self.originatingApplicationBundleIdentifier = originatingApplicationBundleIdentifier
    }

    public static let inactive = MediaState(source: .nowPlaying)
    public var isActive: Bool { isPlaying && !title.isEmpty }
    public var hasTrack: Bool { !title.isEmpty }
    public var launchTarget: MediaLaunchTarget {
        guard let originatingApplicationBundleIdentifier else { return source.launchTarget }
        return MediaLaunchTarget(applicationBundleIdentifier: originatingApplicationBundleIdentifier,
                                 fallbackURL: source.webLaunchURL)
    }
}

public enum ActivityKind: Equatable, Sendable { case media, download, battery, volume, brightness, webcam }

public enum CapabilityPermission: Equatable, Sendable {
    case unknown, authorized, denied, unavailable
    public var statusText: String {
        switch self {
        case .authorized: "Ready"
        case .denied: "Permission required"
        case .unavailable: "Unavailable"
        case .unknown: "Not configured"
        }
    }
}

public struct SystemActivity: Equatable, Sendable {
    public var kind: ActivityKind
    public var title: String
    public var detail: String
    public var progress: Double?

    public init(kind: ActivityKind, title: String, detail: String = "", progress: Double? = nil) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.progress = progress
    }
}

public struct NotchActivity: Equatable, Sendable {
    public var kind: ActivityKind
    public var title: String
    public var detail: String
    public var progress: Double?
}

/// What the media capability is allowed to draw, and which player it follows.
public enum MediaPresentationPolicy {
    private static let closedNotchKey = "mediaShowsInClosedNotch"
    private static let preferredSourceKey = "mediaPreferredSource"

    /// Whether a playing track claims one of the resting notch's ears. On by
    /// default. Off leaves media entirely inside the opened panel — the notch
    /// stays blank while music plays, which is the point for anyone who finds a
    /// permanently occupied ear distracting.
    public static var showsInClosedNotch: Bool {
        get { UserDefaults.standard.object(forKey: closedNotchKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: closedNotchKey) }
    }

    /// The player the notch follows, or `nil` for "whichever is playing".
    ///
    /// Pinning matters when two players hold a track at once: Music.app keeps a
    /// `current track` populated for days after playback stops, so a browser tab
    /// and a stale Music window can trade the notch back and forth. Pinning ends
    /// that argument. This is the persistent form of `MediaCapabilityService`'s
    /// `select(_:)`, which until now could only be set for the current launch.
    public static var preferredSource: MediaSource? {
        get {
            UserDefaults.standard.string(forKey: preferredSourceKey)
                .flatMap(MediaSource.init)
                .flatMap { MediaSource.allCases.contains($0) ? $0 : nil }
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.rawValue, forKey: preferredSourceKey)
            } else {
                UserDefaults.standard.removeObject(forKey: preferredSourceKey)
            }
        }
    }
}

public enum NotchCapabilityPresentation {
    public static func supportsCollapsedPreview(_ media: MediaState) -> Bool {
        MediaPresentationPolicy.showsInClosedNotch && media.isActive
    }

    public static func compactTitle(for activity: NotchActivity) -> String {
        activity.detail.isEmpty ? activity.title : "\(activity.title) · \(activity.detail)"
    }

    public static func symbol(for activity: NotchActivity) -> String {
        switch activity.kind {
        case .media: "music.note"
        case .download: "arrow.down.circle"
        case .battery: "battery.75percent"
        case .volume: "speaker.wave.2"
        case .brightness: "sun.max"
        case .webcam: "video"
        }
    }
}

/// Mirrors NotchFlow's deliberately conservative permission cue: only tools
/// that ordinarily change state (or an MCP action) are surfaced, and only after
/// they have remained unresolved for five seconds. Read-only work must never
/// look like a permission request.
public enum AgentPermissionPolicy {
    /// How long a state-changing tool call may sit unresolved before the notch
    /// treats it as a permission prompt and offers the terminal handoff. Five
    /// seconds is long enough that ordinary fast tool calls never raise a cue,
    /// and short enough that a real prompt is surfaced while the user is still
    /// looking. Tunable from Settings → Agent: a slow machine benefits from a
    /// longer fuse, and someone who runs everything under approval wants a
    /// shorter one.
    public static let defaultDelay: TimeInterval = 5
    public static let delayChoices: [TimeInterval] = [2, 5, 10, 30]
    private static let delayKey = "agentPermissionDelay"

    public static var delay: TimeInterval {
        get {
            (UserDefaults.standard.object(forKey: delayKey) as? Double)
                .map { $0 > 0 ? $0 : defaultDelay } ?? defaultDelay
        }
        set { UserDefaults.standard.set(newValue, forKey: delayKey) }
    }

    private static let eligibleToolNames: Set<String> = [
        "Bash", "Write", "Edit", "MultiEdit", "Task", "NotebookEdit",
        "AskUserQuestion", "WebSearch", "WebFetch"
    ]

    public static func needsTerminalHandoff(forToolName toolName: String,
                                            elapsed: TimeInterval) -> Bool {
        guard elapsed >= delay else { return false }
        return eligibleToolNames.contains(toolName)
            || toolName.lowercased().hasPrefix("mcp__")
    }
}

public enum NotchUtilitiesLayout {
    public static let maximumVisibleRows = 3
}

/// The immediate actions shown above the Utilities workspace, in a horizontally
/// scrolling strip. Started as three fixed, equal-width chips; grew a second
/// group (Power, Devices, Shortcuts) that would not fit at equal width, which is
/// what made the strip scroll instead of squeezing.
public enum QuickUtilityAction: CaseIterable, Identifiable, Equatable, Sendable {
    case pomodoro
    case quickNote
    case reminder
    case power
    case devices
    case clipboard
    case shortcuts

    public var id: String { title }

    public var title: String {
        switch self {
        case .pomodoro: "Pomodoro"
        case .quickNote: "Quick note"
        case .reminder: "Reminder"
        case .power: "Power"
        case .devices: "Devices"
        case .clipboard: "Clipboard"
        case .shortcuts: "Shortcuts"
        }
    }

    public var symbolName: String {
        switch self {
        case .pomodoro: "timer"
        case .quickNote: "note.text"
        case .reminder: "checklist"
        case .power: "moon.zzz.fill"
        case .devices: "batteryblock.fill"
        case .clipboard: "clipboard.fill"
        case .shortcuts: "bolt.fill"
        }
    }
}

/// Which of the quick-action chips the Utilities strip actually offers.
///
/// Seven chips no longer fit a notch-wide panel without scrolling, and not
/// everyone uses all seven — someone who never runs a Pomodoro is scrolling past
/// it to reach Clipboard every time. Hiding a chip only removes it from the
/// strip; the surface behind it is untouched and still reachable from anywhere
/// else that opens it (a file drop still reveals the File tray).
public enum QuickUtilityStrip {
    private static let defaultsKey = "utilityQuickActionsHidden"

    /// Hidden by raw title, not by index: a future case inserted in the middle of
    /// `QuickUtilityAction` would otherwise silently re-map everyone's choices.
    public static var hidden: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: defaultsKey) }
    }

    public static var visibleActions: [QuickUtilityAction] {
        let hidden = hidden
        let visible = QuickUtilityAction.allCases.filter { !hidden.contains($0.id) }
        // An empty strip is not a state worth allowing: it leaves the Utilities
        // pane with a bare, unexplained gap where the chips were.
        return visible.isEmpty ? QuickUtilityAction.allCases : visible
    }

    public static func isVisible(_ action: QuickUtilityAction) -> Bool {
        visibleActions.contains(action)
    }

    /// Show or hide one chip. Hiding the last visible one is refused rather than
    /// silently corrected, so the settings row's switch can't lie about the result.
    @discardableResult
    public static func setVisible(_ visible: Bool, for action: QuickUtilityAction) -> Bool {
        var next = hidden
        if visible {
            next.remove(action.id)
        } else {
            guard visibleActions.count > 1 else { return false }
            next.insert(action.id)
        }
        hidden = next
        return true
    }
}

public enum UtilityOverlayKind: Equatable, Sendable {
    case pomodoro
    case quickNote
    case reminder
    case power
    case devices
    case clipboard
    case shortcuts

    public init?(for action: QuickUtilityAction) {
        switch action {
        case .pomodoro: self = .pomodoro
        case .quickNote: self = .quickNote
        case .reminder: self = .reminder
        case .power: self = .power
        case .devices: self = .devices
        case .clipboard: self = .clipboard
        case .shortcuts: self = .shortcuts
        }
    }

    /// The chip that opens this overlay — the inverse of `init(for:)`, so the
    /// strip can show which of its chips is the one currently selected.
    public var action: QuickUtilityAction {
        switch self {
        case .pomodoro: .pomodoro
        case .quickNote: .quickNote
        case .reminder: .reminder
        case .power: .power
        case .devices: .devices
        case .clipboard: .clipboard
        case .shortcuts: .shortcuts
        }
    }
}

/// Owns the lifetime of an in-notch utility overlay. Keeping this state out of
/// the view means a button press that re-lays the panel out cannot lose the
/// overlay's identity mid-interaction. It does not pin the panel open: the
/// overlay folds when the pointer leaves, like the workspace tabs around it.
@MainActor
public final class UtilityOverlaySession: ObservableObject {
    @Published public private(set) var selection: UtilityOverlayKind?

    public init(selection: UtilityOverlayKind? = nil) {
        self.selection = selection
    }

    public var protectsPanelInteraction: Bool {
        selection != nil
    }

    public func present(_ selection: UtilityOverlayKind) {
        self.selection = selection
    }

    public func dismiss() {
        selection = nil
    }
}

/// A lightweight, immutable focus session. The view owns its lifecycle; this
/// type only makes the duration and countdown deterministic and testable.
public struct PomodoroSession: Equatable, Sendable {
    public static let duration: TimeInterval = 25 * 60
    public let endsAt: Date

    public init(startingAt start: Date, duration: TimeInterval = PomodoroSession.duration) {
        endsAt = start.addingTimeInterval(duration)
    }

    public func remaining(at date: Date) -> TimeInterval {
        max(0, endsAt.timeIntervalSince(date))
    }
}

/// Shared geometry constants for the compact in-notch focus surface.
public enum PomodoroOverlayLayout {
    public static let columnCount = 2
    /// Two weeks per row, so the squares fill the tracker's width instead of
    /// leaving its right half empty.
    public static let activityWeekColumns = 14
    /// Eight weeks in four rows: wide enough to use the panel, short enough to
    /// keep the tracker no taller than the timer controls.
    public static let activityDayCount = 56

    /// A commit-graph shade ramp: the more focus blocks a day holds, the more
    /// solid its square. Returned as the accent's opacity, so an untouched day
    /// (0) is the empty well and four-plus blocks is full accent.
    public static func shade(forSessions sessions: Int) -> Double {
        switch max(0, sessions) {
        case 0: 0
        case 1: 0.32
        case 2: 0.55
        case 3: 0.78
        default: 1
        }
    }
}

public enum PomodoroDurationPresets {
    public static let focus = [10, 15, 20, 25, 30, 45, 60]
    public static let breakTime = [5, 10, 15, 20]

    public static func label(for minutes: Int) -> String {
        "\(minutes) min"
    }

    public static func contains(_ minutes: Int, in presets: [Int]) -> Bool {
        presets.contains(minutes)
    }
}

public enum ShelfSharingLayout {
    public static func pickerRect(for buttonBounds: CGRect) -> CGRect {
        buttonBounds
    }
}

public enum NotchWorkspaceTab: String, CaseIterable, Identifiable, Sendable {
    case chat = "Chat"
    case agent = "Agent"
    case media = "Media"
    case utilities = "Utilities"
    case activityMonitor = "Activity Monitor"
    case aiActivityMonitor = "AI Activity Monitor"

    public var id: String { rawValue }

    /// The glyph the workspace switcher draws for this tab. Lives on the tab
    /// rather than in the switcher's own conditional chain: Activity Monitor is a
    /// first-class tab in companion mode, and a four-deep ternary that ended in
    /// "…otherwise the Utilities grid" silently gave it the wrong icon.
    public var symbolName: String {
        switch self {
        case .chat: "message"
        case .agent: "terminal"
        case .media: "music.note"
        case .utilities: "square.grid.2x2"
        case .activityMonitor: "gauge.with.dots.needle.67percent"
        case .aiActivityMonitor: "sparkles"
        }
    }

    /// The tabs the switcher offers when the agentic layer is turned off. Chat and
    /// Agent are gone, and Activity Monitor stops being an edge toggle beside
    /// Utilities and becomes the third peer.
    public static let companionTabs: [NotchWorkspaceTab] = [.media, .utilities, .activityMonitor]
}

/// The single bridge between NotchFlow services and the UI/agent.
/// Services only publish immutable state here; NotchFlow decides how and where to render it.
@MainActor
public final class NotchCapabilityStore: ObservableObject {
    public static let shared = NotchCapabilityStore()
    private static let agenticModeKey = "agenticModeEnabled"
    @Published public private(set) var media: MediaState = .inactive
    @Published public private(set) var mediaError: String?
    @Published public private(set) var connectedAudioDevice: ConnectedAudioDevice?
    @Published public private(set) var accessoryConnectionEvent: AccessoryConnectionEvent?
    @Published public private(set) var systemActivity: SystemActivity?
    @Published public private(set) var shelfItems: [NotchShelfItem]
    @Published public var workspaceTab: NotchWorkspaceTab = .chat
    /// Agentic mode exposes the inherited Chat and Agent workspaces. Turning it
    /// off leaves NotchFlow as a focused media-and-utilities companion.
    @Published public var agenticModeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(agenticModeEnabled, forKey: Self.agenticModeKey)
            if !agenticModeEnabled,
               workspaceTab == .chat || workspaceTab == .agent || workspaceTab == .aiActivityMonitor {
                workspaceTab = .media
            }
        }
    }
    /// The player the notch follows, or `nil` for whichever is playing. Writes go
    /// straight through to the media service's pin AND to storage, so the choice
    /// survives a relaunch — `MediaCapabilityService.select(_:)` on its own only
    /// held for the current launch.
    @Published public var preferredMediaSource: MediaSource? {
        didSet {
            guard preferredMediaSource != oldValue else { return }
            MediaPresentationPolicy.preferredSource = preferredMediaSource
            applyPreferredMediaSource()
        }
    }
    /// Increments for every file drop, including when Utilities is already
    /// selected. Views use it to reveal the File tray from a utility overlay.
    @Published public private(set) var fileTrayRevealRequest = 0
    private let mediaService: MediaCapabilityService
    private let audioDeviceService: AudioDeviceCapabilityService
    private let persistence: ShelfPersistenceService
    private var accessoryEventExpiresAt: Date?
    private let accessoryEventDuration: TimeInterval = 3
    /// Filters the flap macOS puts the output device through on a removal.
    private var accessorySettler = AccessoryConnectionSettler()

    public init(mediaService: MediaCapabilityService? = nil, persistence: ShelfPersistenceService = .shared) {
        self.mediaService = mediaService ?? MediaCapabilityService()
        self.audioDeviceService = AudioDeviceCapabilityService()
        self.persistence = persistence
        let storedAgenticMode = UserDefaults.standard.object(forKey: Self.agenticModeKey) as? Bool ?? true
        self.agenticModeEnabled = storedAgenticMode
        // Property initialisation does not run `didSet`, so the stored pin has to
        // be handed to the service explicitly — otherwise a pinned player would
        // only take effect after the user re-picked it.
        self.preferredMediaSource = MediaPresentationPolicy.preferredSource
        var restoredItems = persistence.load()
        let migratedLegacyItems = restoredItems.indices.reduce(into: false) { didMigrate, index in
            if restoredItems[index].restorePreferredTemporaryFilename() {
                didMigrate = true
            }
        }
        self.shelfItems = restoredItems
        if !storedAgenticMode {
            workspaceTab = .media
        }
        if migratedLegacyItems {
            persistence.save(restoredItems)
        }
        applyPreferredMediaSource()
    }

    private func applyPreferredMediaSource() {
        let source = preferredMediaSource
        Task { [mediaService] in
            await mediaService.select(source)
            self.media = mediaService.state
            self.mediaError = mediaService.mediaError
        }
    }

    public var primaryActivity: NotchActivity? {
        if media.isActive {
            return NotchActivity(kind: .media, title: media.title, detail: media.artist, progress: media.duration > 0 ? media.position / media.duration : nil)
        }
        guard let systemActivity else { return nil }
        return NotchActivity(kind: systemActivity.kind, title: systemActivity.title, detail: systemActivity.detail, progress: systemActivity.progress)
    }

    public func revealFileTray() {
        workspaceTab = .utilities
        fileTrayRevealRequest &+= 1
    }

    /// A file is hovering the notch. Select its destination before the user
    /// releases, so the open animation reveals the File Tray rather than the
    /// last workspace they happened to use.
    public func prepareForIncomingFileDrop() {
        revealFileTray()
    }

    public func apply(_ state: MediaState) { media = state }
    public func apply(_ activity: SystemActivity?) { systemActivity = activity }

    public func refresh() async {
        media = await mediaService.refresh()
        mediaError = mediaService.mediaError
        if let event = accessorySettler.observe(audioDeviceService.connectedAirPods()) {
            accessoryConnectionEvent = event
            accessoryEventExpiresAt = Date().addingTimeInterval(accessoryEventDuration)
        } else if let accessoryEventExpiresAt, Date() >= accessoryEventExpiresAt {
            accessoryConnectionEvent = nil
            self.accessoryEventExpiresAt = nil
        }
        connectedAudioDevice = accessorySettler.device
    }

    public func performMedia(_ command: MediaCommand) async {
        await mediaService.perform(command)
        media = mediaService.state
        mediaError = mediaService.mediaError
    }

    public func launchMedia(_ source: MediaSource) {
        mediaService.launch(source)
    }

    public func launchMedia(_ media: MediaState) {
        mediaService.launch(media)
    }

    public func addShelfItem(url: URL) throws {
        guard url.isFileURL else { throw CocoaError(.fileNoSuchFile) }
        try addShelfItems([.file(url: url)])
    }

    public func addShelfItems(_ items: [NotchShelfItem]) throws {
        var seenKeys = Set(shelfItems.map(\.identityKey))
        let newItems = items.filter { seenKeys.insert($0.identityKey).inserted }
        shelfItems.insert(contentsOf: newItems, at: 0)
        persistence.save(shelfItems)
    }

    public func ingest(_ items: [NotchShelfItem]) {
        try? addShelfItems(items)
    }

    public func shouldAddToShelf(url: URL, target: ShelfDropTarget) -> Bool {
        guard target == .chatNotch else { return true }
        var isDirectory: ObjCBool = false
        return !(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue)
    }

    /// Empty the File tray. Temporary files (a drag-out that Notch staged itself)
    /// are deleted from disk as well, exactly as removing them one at a time does
    /// — anything else would leave orphans in the staging directory.
    public func clearShelf() {
        for item in shelfItems where item.isTemporary {
            if let url = item.url { TemporaryShelfStorage.remove(url) }
        }
        shelfItems.removeAll()
        persistence.save(shelfItems)
    }

    public func removeShelfItem(id: UUID) {
        guard let item = shelfItems.first(where: { $0.id == id }) else { return }
        if item.isTemporary, let url = item.url { TemporaryShelfStorage.remove(url) }
        shelfItems.removeAll { $0.id == id }
        persistence.save(shelfItems)
    }
}
