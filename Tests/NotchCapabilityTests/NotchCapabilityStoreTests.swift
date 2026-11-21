import AppKit
import XCTest
import UniformTypeIdentifiers
@testable import NotchCapabilities

final class NotchCapabilityStoreTests: XCTestCase {
    func testIdleMediaPollingWaitsFiveSecondsButPlayingMediaStaysResponsive() {
        let policy = MediaRefreshPolicy()
        let now = Date(timeIntervalSinceReferenceDate: 1_000)

        XCTAssertFalse(policy.shouldPoll(lastState: .inactive, lastPolledAt: now, now: now.addingTimeInterval(4.9)))
        XCTAssertTrue(policy.shouldPoll(lastState: .inactive, lastPolledAt: now, now: now.addingTimeInterval(5)))
        XCTAssertTrue(policy.shouldPoll(lastState: MediaState(source: .spotify, title: "Song", isPlaying: true),
                                        lastPolledAt: now, now: now.addingTimeInterval(1)))
    }

    private final class RecordingMediaController: MediaControlling {
        var source: MediaSource = .spotify
        var state = MediaState(source: .spotify, title: "Song", artist: "Artist", isPlaying: true)
        var commands: [MediaCommand] = []

        func refresh() async -> MediaState { state }
        func perform(_ command: MediaCommand) async { commands.append(command) }
    }

    @MainActor
    func testPlayingMediaBecomesTheCollapsedActivity() {
        let store = NotchCapabilityStore()

        store.apply(MediaState(source: .spotify,
                               title: "Midnight City",
                               artist: "M83",
                               isPlaying: true,
                               position: 12,
                               duration: 244,
                               lastAudibleAt: .now))

        XCTAssertEqual(store.primaryActivity?.kind, .media)
        XCTAssertEqual(store.primaryActivity?.title, "Midnight City")
        XCTAssertEqual(store.media.title, "Midnight City")
    }

    @MainActor
    func testPausedMediaDoesNotReplaceAnActiveSystemActivity() {
        let store = NotchCapabilityStore()
        store.apply(SystemActivity(kind: .download, title: "Downloading", detail: "42%", progress: 0.42))
        store.apply(MediaState(source: .appleMusic, title: "Paused", artist: "Artist", isPlaying: false))

        XCTAssertEqual(store.primaryActivity?.kind, .download)
        XCTAssertEqual(store.primaryActivity?.title, "Downloading")
    }

    @MainActor
    func testMediaServiceRoutesTransportToTheSelectedSource() async {
        let spotify = RecordingMediaController()
        let service = MediaCapabilityService(controllers: [spotify])
        await service.perform(.next)

        XCTAssertEqual(spotify.commands, [.next])
    }

    @MainActor
    func testRefreshPublishesMediaServiceStateToTheNotchFlowStore() async {
        let spotify = RecordingMediaController()
        let store = NotchCapabilityStore(mediaService: MediaCapabilityService(controllers: [spotify]))

        await store.refresh()

        XCTAssertEqual(store.media.title, "Song")
        XCTAssertEqual(store.primaryActivity?.kind, .media)
    }

    /// A stub for whichever source a selection test needs.
    @MainActor
    private final class FixedMediaController: MediaControlling {
        let source: MediaSource
        var state: MediaState

        init(_ source: MediaSource, title: String, playing: Bool,
             lastAudibleAt: Date = .distantPast, artwork: Data? = nil) {
            self.source = source
            state = MediaState(source: source, title: title, artist: "Artist",
                               isPlaying: playing, artworkData: artwork,
                               lastAudibleAt: lastAudibleAt)
        }

        func refresh() async -> MediaState { state }
        func perform(_ command: MediaCommand) async {}
    }

    @MainActor
    func testAPlayingSpotifyOutranksTheBrowserSessionAndBringsItsCover() async {
        let cover = Data("album".utf8)
        let browser = FixedMediaController(.nowPlaying, title: "Netflix", playing: true,
                                           lastAudibleAt: .now)
        let spotify = FixedMediaController(.spotify, title: "Loser", playing: true,
                                           lastAudibleAt: .now.addingTimeInterval(-30),
                                           artwork: cover)
        let service = MediaCapabilityService(controllers: [browser, spotify])

        let state = await service.refresh()

        XCTAssertEqual(state.source, .spotify, "a dedicated player outranks a browser tab")
        XCTAssertEqual(state.title, "Loser")
        XCTAssertEqual(state.artworkData, cover)
    }

    @MainActor
    func testAPausedBrowserTabDoesNotHoldTheNotchAgainstAPlayingPlayer() async {
        let browser = FixedMediaController(.nowPlaying, title: "Netflix", playing: false,
                                           lastAudibleAt: .now)
        let music = FixedMediaController(.appleMusic, title: "Redbone", playing: true,
                                         lastAudibleAt: .now.addingTimeInterval(-600))
        let service = MediaCapabilityService(controllers: [browser, music])

        let state = await service.refresh()

        XCTAssertEqual(state.source, .appleMusic)
    }

    @MainActor
    func testTheBrowserStillWinsWhenNoDedicatedPlayerHasATrack() async {
        let browser = FixedMediaController(.nowPlaying, title: "Netflix", playing: true,
                                           lastAudibleAt: .now)
        let spotify = FixedMediaController(.spotify, title: "", playing: false)
        let service = MediaCapabilityService(controllers: [browser, spotify])

        let state = await service.refresh()

        XCTAssertEqual(state.source, .nowPlaying)
        XCTAssertEqual(state.title, "Netflix")
    }

    @MainActor
    func testAmongTwoDedicatedPlayersTheMostRecentlyAudibleWins() async {
        let spotify = FixedMediaController(.spotify, title: "Loser", playing: true,
                                           lastAudibleAt: .now.addingTimeInterval(-30))
        let music = FixedMediaController(.appleMusic, title: "Redbone", playing: true,
                                         lastAudibleAt: .now)
        let service = MediaCapabilityService(controllers: [spotify, music])

        let state = await service.refresh()

        XCTAssertEqual(state.source, .appleMusic)
    }

    @MainActor
    func testRefreshKeepsPausedTrackUntilItsSourceStopsReportingIt() async {
        let spotify = RecordingMediaController()
        spotify.state.isPlaying = false
        spotify.state.lastAudibleAt = .now
        let service = MediaCapabilityService(controllers: [spotify])

        let paused = await service.refresh()
        XCTAssertEqual(paused.title, "Song")

        spotify.state = .inactive
        let stopped = await service.refresh()
        XCTAssertEqual(stopped, .inactive)
    }

    @MainActor
    func testChangingFocusDurationWhileRunningRebasesTheDeadline() {
        let start = Date(timeIntervalSinceReferenceDate: 30_000)
        let store = FocusTimerStore(defaults: makeDefaults(named: #function), now: start)

        store.start(at: start)
        store.focusMinutes = 60

        XCTAssertEqual(store.remaining(at: start), 60 * 60, accuracy: 0.01,
                       "the selected focus duration must describe both the ring and the deadline")
        XCTAssertEqual(store.progress(at: start), 0, accuracy: 0.0001)
    }

    func testMediaActivityGetsNotchFlowCompactPresentation() {
        let activity = NotchActivity(kind: .media, title: "Midnight City", detail: "M83", progress: 0.25)

        XCTAssertEqual(NotchCapabilityPresentation.compactTitle(for: activity), "Midnight City · M83")
        XCTAssertEqual(NotchCapabilityPresentation.symbol(for: activity), "music.note")
    }

    func testOnlyPlayingMediaQualifiesForTheCollapsedNowPlayingPreview() {
        XCTAssertTrue(NotchCapabilityPresentation.supportsCollapsedPreview(
            MediaState(source: .spotify, title: "Loser", isPlaying: true)))
        XCTAssertFalse(NotchCapabilityPresentation.supportsCollapsedPreview(
            MediaState(source: .spotify, title: "Loser", isPlaying: false)))
    }

    func testAirPodsOutputNamesAreRecognizedForTheCollapsedAccessoryPreview() {
        XCTAssertTrue(ConnectedAudioDevice.isAirPodsName("Sid's AirPods Max"))
        XCTAssertTrue(ConnectedAudioDevice.isAirPodsName("AirPods Pro"))
        XCTAssertFalse(ConnectedAudioDevice.isAirPodsName("MacBook Pro Speakers"))
    }

    func testAccessoryConnectionEventsDescribeConnectAndDisconnectTransitions() {
        let airPods = ConnectedAudioDevice(name: "Sid's AirPods Max")

        XCTAssertEqual(AccessoryConnectionEvent.transition(from: nil, to: airPods), .connected(airPods))
        XCTAssertEqual(AccessoryConnectionEvent.transition(from: airPods, to: nil), .disconnected(airPods))
        XCTAssertNil(AccessoryConnectionEvent.transition(from: airPods, to: airPods))
    }

    func testMediaSourcePlayerCardsHaveLaunchFallbacks() {
        XCTAssertEqual(MediaSource.spotify.webLaunchURL?.host, "open.spotify.com")
        XCTAssertEqual(MediaSource.appleMusic.webLaunchURL?.host, "music.apple.com")
        XCTAssertNil(MediaSource.nowPlaying.webLaunchURL)
    }

    func testMediaPlayerShortcutsPreferTheirInstalledMacApps() {
        XCTAssertEqual(MediaSource.spotify.launchTarget.applicationBundleIdentifier, "com.spotify.client")
        XCTAssertEqual(MediaSource.appleMusic.launchTarget.applicationBundleIdentifier, "com.apple.Music")
        XCTAssertEqual(MediaSource.spotify.launchTarget.fallbackURL?.host, "open.spotify.com")
    }

    @MainActor
    func testAppleScriptScalarCommandResultDoesNotGetReadAsAList() {
        let result = NSAppleEventDescriptor(string: "done")

        XCTAssertTrue(AppleScriptMediaController.listItems(from: result).isEmpty)
    }

    func testMediaRemotePayloadRoutesBrowserPlaybackAndItsOpenActionToTheOriginatingBrowser() throws {
        let data = Data("{\"bundleIdentifier\":\"com.google.Chrome\",\"title\":\"Browser Track\",\"artist\":\"Web Artist\",\"duration\":180,\"elapsedTimeNow\":42,\"playing\":true}".utf8)
        let payload = try JSONDecoder().decode(MediaRemotePayload.self, from: data)

        let state = payload.mediaState(previous: .inactive)

        XCTAssertEqual(state.source, .nowPlaying)
        XCTAssertEqual(state.title, "Browser Track")
        XCTAssertEqual(state.position, 42)
        XCTAssertTrue(state.isPlaying)
        XCTAssertEqual(state.originatingApplicationBundleIdentifier, "com.google.Chrome")
        XCTAssertEqual(state.launchTarget.applicationBundleIdentifier, "com.google.Chrome")
    }

    @MainActor
    func testShelfAddsAndRemovesDroppedFile() throws {
        let store = NotchCapabilityStore()
        let file = URL(fileURLWithPath: "/tmp/notch-shelf-test.txt")

        try store.addShelfItem(url: file)
        XCTAssertEqual(store.shelfItems.map(\.url), [file])

        store.removeShelfItem(id: store.shelfItems[0].id)
        XCTAssertTrue(store.shelfItems.isEmpty)
    }

    func testFileTraySelectionClearsWhenItsSelectedFileIsRemoved() {
        let first = NotchShelfItem.text("First")
        let second = NotchShelfItem.text("Second")

        XCTAssertEqual(ShelfTraySelection.item(in: [first, second], selectedID: second.id)?.id, second.id)
        XCTAssertNil(ShelfTraySelection.item(in: [first], selectedID: second.id))
    }

    func testFileTraySelectionKeepsEverySelectedItemInTrayOrder() {
        let first = NotchShelfItem.text("First")
        let second = NotchShelfItem.text("Second")
        let third = NotchShelfItem.text("Third")

        let selected = ShelfTraySelection.items(
            in: [first, second, third],
            selectedIDs: [third.id, first.id]
        )

        XCTAssertEqual(selected.map(\.id), [first.id, third.id])
    }

    func testAIActivityGroupsMultipleClaudeSessionsIntoOneProviderSummary() {
        let summaries = AIActivityProviderAggregation.summaries(for: [
            .init(id: "claude-chat", providerID: "claude", provider: "Claude Code", model: "Opus 5", status: "Current chat", isCurrentChat: true),
            .init(id: "claude-work", providerID: "claude", provider: "Claude Code", model: "Opus 5", status: "Working"),
            .init(id: "codex-work", providerID: "codex", provider: "Codex", model: "GPT-5", status: "Working")
        ])

        XCTAssertEqual(summaries.map(\.id), ["claude", "codex"])
        XCTAssertEqual(summaries[0].sessionCount, 2)
        XCTAssertEqual(summaries[0].status, "Current chat · 1 session")
    }

    func testAIActivityKeepsIdleCodexVisibleBesideClaude() {
        let claude = AIActivityProviderSession(id: "claude-chat", providerID: "claude", provider: "Claude Code", model: "Opus 5", status: "Current chat", isCurrentChat: true)
        let codex = AIActivityProviderSession(id: "codex-baseline", providerID: "codex", provider: "Codex", model: "Codex", status: "No activity", isBaseline: true)

        let summaries = AIActivityProviderAggregation.summaries(for: [claude], including: [claude, codex])

        XCTAssertEqual(summaries.map(\.id), ["claude", "codex"])
        XCTAssertEqual(summaries[1].status, "No activity")
    }

    @MainActor
    func testRevealingTheFileTraySelectsUtilitiesWorkspace() {
        let store = NotchCapabilityStore(persistence: .ephemeral)

        store.revealFileTray()

        XCTAssertEqual(store.workspaceTab, .utilities)
    }

    @MainActor
    func testSelectingAgentWorkspaceDoesNotRestoreDisabledAgenticMode() {
        let defaults = UserDefaults.standard
        let key = "agenticModeEnabled"
        let previousValue = defaults.object(forKey: key)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let store = NotchCapabilityStore(persistence: .ephemeral)
        store.agenticModeEnabled = false

        store.workspaceTab = .agent

        XCTAssertFalse(store.agenticModeEnabled)
        XCTAssertEqual(store.workspaceTab, .agent)
    }

    @MainActor
    func testRevealingTheFileTrayPublishesANewRevealRequest() {
        let store = NotchCapabilityStore(persistence: .ephemeral)
        let initialRequest = store.fileTrayRevealRequest

        store.revealFileTray()

        XCTAssertEqual(store.fileTrayRevealRequest, initialRequest + 1)
    }

    @MainActor
    func testPreparingForAnIncomingFileDropOpensTheFileTray() {
        let store = NotchCapabilityStore(persistence: .ephemeral)
        store.workspaceTab = .chat

        store.prepareForIncomingFileDrop()

        XCTAssertEqual(store.workspaceTab, .utilities)
        XCTAssertEqual(store.fileTrayRevealRequest, 1)
    }

    @MainActor
    func testShelfRestoresPersistedFileLinkAndTextItems() throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let persistence = ShelfPersistenceService(defaults: defaults)
        let file = try makeFixtureFile(named: "persistent.txt")
        let original = NotchCapabilityStore(persistence: persistence)

        try original.addShelfItems([
            NotchShelfItem.file(url: file),
            .link(URL(string: "https://example.com")!),
            .text("Remember this")
        ])

        let restored = NotchCapabilityStore(persistence: persistence)
        XCTAssertEqual(restored.shelfItems.count, 3)
        XCTAssertTrue(restored.shelfItems[0].displayName.hasSuffix("persistent.txt"))
        XCTAssertEqual(restored.shelfItems.dropFirst().map(\.displayName), ["example.com", "Remember this"])
    }

    @MainActor
    func testShelfBatchIngestionKeepsEveryDistinctItem() throws {
        let store = NotchCapabilityStore(persistence: .ephemeral)
        let file = try makeFixtureFile(named: "batch.txt")

        try store.addShelfItems([
            NotchShelfItem.file(url: file),
            .text("hello"),
            .file(url: file)
        ])

        XCTAssertEqual(store.shelfItems.count, 2)
    }

    @MainActor
    func testNewestDropAppearsFirstAndKeepsItsDisplayName() throws {
        let store = NotchCapabilityStore(persistence: .ephemeral)
        let older = try makeFixtureFile(named: "older.txt")
        let newest = try makeFixtureFile(named: "opaque-storage-name")

        try store.addShelfItems([.file(url: older)])
        try store.addShelfItems([.file(url: newest, displayName: "Quarterly report.pdf")])

        XCTAssertEqual(store.shelfItems.map(\.displayName), ["Quarterly report.pdf", older.lastPathComponent])
    }

    func testTemporaryStorageUUIDIsNeverShownAsTheFileName() {
        let url = URL(fileURLWithPath: "/tmp/7A1B6A56-4D9E-45B7-9BE9-A7B983752B31-Quarterly report.pdf")
        let item = NotchShelfItem.file(url: url, isTemporary: true)

        XCTAssertEqual(item.displayName, "Quarterly report.pdf")
    }

    func testTemporaryStorageKeepsTheOriginalFilenameOnDisk() {
        let url = TemporaryShelfStorage.create(data: Data("fixture".utf8), suggestedName: "Quarterly report.pdf")

        XCTAssertEqual(url?.lastPathComponent, "Quarterly report.pdf")
        if let url { TemporaryShelfStorage.remove(url) }
    }

    func testDropServiceResolvesEncodedItemURLBeforeCreatingTemporaryData() async throws {
        let original = try makeFixtureFile(named: "original-name.pdf")
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.item.identifier, visibility: .all) { completion in
            completion(Data(original.absoluteString.utf8), nil)
            return nil
        }

        let items = await ShelfDropService.items(from: [provider])

        XCTAssertEqual(items.first?.displayName, original.lastPathComponent)
        XCTAssertFalse(items.first?.isTemporary ?? true)
    }

    func testStoredTemporaryItemMigratesItsPhysicalFilenameToTheOriginalName() throws {
        let legacy = try makeFixtureFile(named: "4D61F401-2E76-45B1-A656-65F0F4D6DAD2-Dropped Item")
        let originalName = "\(UUID().uuidString)-Original document.pdf"
        var item = NotchShelfItem.file(url: legacy, displayName: originalName, isTemporary: true)

        XCTAssertTrue(item.restorePreferredTemporaryFilename())
        XCTAssertEqual(item.url?.lastPathComponent, originalName)
    }

    @MainActor
    func testFolderIsShelfItemOnlyWhenDroppedOnTheFileTray() throws {
        let store = NotchCapabilityStore(persistence: .ephemeral)
        let folder = try makeFixtureFolder(named: "project")

        XCTAssertFalse(store.shouldAddToShelf(url: folder, target: .chatNotch))
        XCTAssertTrue(store.shouldAddToShelf(url: folder, target: .fileTray))
    }

    func testDropServiceReadsEveryFileProvider() async throws {
        let first = try makeFixtureFile(named: "first.txt")
        let second = try makeFixtureFile(named: "second.txt")
        let providers = [
            NSItemProvider(object: first as NSURL),
            NSItemProvider(object: second as NSURL)
        ]

        let items = await ShelfDropService.items(from: providers)

        XCTAssertEqual(items.compactMap(\.url).map(\.lastPathComponent), [first.lastPathComponent, second.lastPathComponent])
    }

    private func makeFixtureFile(named name: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(UUID().uuidString)-\(name)")
        try Data("fixture".utf8).write(to: url)
        return url
    }

    private func makeFixtureFolder(named name: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(UUID().uuidString)-\(name)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeDefaults(named name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testPermissionStateHasActionableUnavailableLabel() {
        XCTAssertEqual(CapabilityPermission.denied.statusText, "Permission required")
    }

    func testUtilitiesListsShareAThreeRowViewportLimit() {
        XCTAssertEqual(NotchUtilitiesLayout.maximumVisibleRows, 3)
    }

    func testPomodoroSessionStartsWithTwentyFiveMinutesAndCountsDown() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let session = PomodoroSession(startingAt: start)

        XCTAssertEqual(session.remaining(at: start), 25 * 60)
        XCTAssertEqual(session.remaining(at: start.addingTimeInterval(90)), 23 * 60 + 30)
        XCTAssertEqual(session.remaining(at: start.addingTimeInterval(2_000)), 0)
    }

    func testPomodoroOverlayUsesTwoBalancedColumnsAndAFullWidthStreakGrid() {
        XCTAssertEqual(PomodoroOverlayLayout.columnCount, 2)
        XCTAssertEqual(PomodoroOverlayLayout.activityWeekColumns, 14)
        XCTAssertEqual(PomodoroOverlayLayout.activityDayCount, 56)
        // Whole weeks per row, and rows short enough to sit beside the timer.
        XCTAssertEqual(PomodoroOverlayLayout.activityWeekColumns % 7, 0)
        XCTAssertEqual(PomodoroOverlayLayout.activityDayCount
                        / PomodoroOverlayLayout.activityWeekColumns, 4)
    }

    func testPomodoroDropdownsExposeOnlyTheRequestedPresets() {
        XCTAssertEqual(PomodoroDurationPresets.focus, [10, 15, 20, 25, 30, 45, 60])
        XCTAssertEqual(PomodoroDurationPresets.breakTime, [5, 10, 15, 20])
    }

    func testPomodoroDropdownFormatsTheSelectedPresetAsOneCompactLabel() {
        XCTAssertEqual(PomodoroDurationPresets.label(for: 25), "25 min")
    }

    func testPomodoroDurationPresetsRejectsValuesOutsideTheVisibleDropdown() {
        XCTAssertTrue(PomodoroDurationPresets.contains(25, in: PomodoroDurationPresets.focus))
        XCTAssertFalse(PomodoroDurationPresets.contains(35, in: PomodoroDurationPresets.focus))
    }

    func testQuickUtilityActionsProvideTheRequestedShortcuts() {
        XCTAssertEqual(QuickUtilityAction.allCases.map(\.title),
                       ["Pomodoro", "Quick note", "Reminder", "Power", "Devices", "Clipboard", "Shortcuts"])
    }

    func testWorkspaceTabsIncludeAnIndependentAgentWorkspace() {
        XCTAssertEqual(NotchWorkspaceTab.allCases.map(\.rawValue),
                       ["Chat", "Agent", "Media", "Utilities", "Activity Monitor", "AI Activity Monitor"])
    }

    func testAgentPermissionPolicyFlagsOnlyStalledPermissionEligibleTools() {
        XCTAssertFalse(AgentPermissionPolicy.needsTerminalHandoff(forToolName: "Bash", elapsed: 4.9))
        XCTAssertTrue(AgentPermissionPolicy.needsTerminalHandoff(forToolName: "Bash", elapsed: 5))
        XCTAssertTrue(AgentPermissionPolicy.needsTerminalHandoff(forToolName: "WebSearch", elapsed: 5))
        XCTAssertTrue(AgentPermissionPolicy.needsTerminalHandoff(forToolName: "Task", elapsed: 5))
        XCTAssertTrue(AgentPermissionPolicy.needsTerminalHandoff(forToolName: "mcp__github__create_issue", elapsed: 5))
        XCTAssertFalse(AgentPermissionPolicy.needsTerminalHandoff(forToolName: "Read", elapsed: 30))
    }

    func testEveryQuickUtilityActionOpensAnInNotchOverlay() {
        for action in QuickUtilityAction.allCases {
            XCTAssertNotNil(UtilityOverlayKind(for: action), "\(action) has no overlay to open")
        }
    }

    func testEachOverlayKindMapsBackToTheChipThatOpenedIt() {
        for action in QuickUtilityAction.allCases {
            let kind = UtilityOverlayKind(for: action)
            XCTAssertEqual(kind?.action, action, "the reverse mapping must round-trip")
        }
    }

    @MainActor
    func testUtilityOverlaySessionProtectsTheNotchUntilItIsExplicitlyDismissed() {
        let session = UtilityOverlaySession()

        session.present(.pomodoro)
        XCTAssertEqual(session.selection, .pomodoro)
        XCTAssertTrue(session.protectsPanelInteraction)

        session.dismiss()
        XCTAssertNil(session.selection)
        XCTAssertFalse(session.protectsPanelInteraction)
    }

    @MainActor
    func testFocusTimerPersistsTheActiveEndDateAndRestoresItsCountdown() {
        let defaults = makeDefaults(named: #function)
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let original = FocusTimerStore(defaults: defaults)
        original.start(at: start)

        let restored = FocusTimerStore(defaults: defaults, now: start.addingTimeInterval(60))

        XCTAssertEqual(restored.phase, .focus)
        XCTAssertEqual(restored.remaining(at: start.addingTimeInterval(60)), 24 * 60)
    }

    @MainActor
    func testExpiredFocusMovesToBreakAndAddsOneCompletedDay() {
        let defaults = makeDefaults(named: #function)
        let start = Date(timeIntervalSinceReferenceDate: 10_000_000)
        let store = FocusTimerStore(defaults: defaults)
        store.start(at: start)

        store.refresh(at: start.addingTimeInterval(25 * 60))

        XCTAssertEqual(store.phase, .break)
        XCTAssertEqual(store.completedDayCount, 1)
        XCTAssertEqual(store.currentStreak(at: start), 1)
    }

    @MainActor
    func testRestoredExpiredFocusSessionImmediatelyMovesToBreak() {
        let defaults = makeDefaults(named: #function)
        let start = Date(timeIntervalSinceReferenceDate: 10_000_000)
        FocusTimerStore(defaults: defaults).start(at: start)

        let restored = FocusTimerStore(defaults: defaults,
                                       now: start.addingTimeInterval(25 * 60))

        XCTAssertEqual(restored.phase, .break)
        XCTAssertEqual(restored.completedDayCount, 1)
    }

    @MainActor
    func testFocusTimerCountsEachCalendarDayOnlyOnce() {
        let store = FocusTimerStore(defaults: makeDefaults(named: #function))
        let day = Date(timeIntervalSinceReferenceDate: 10_000_000)

        store.recordFocusCompletion(on: day)
        store.recordFocusCompletion(on: day)

        XCTAssertEqual(store.completedDayCount, 1)
    }

    /// The duration pickers write straight through a `Binding`, so a setter that
    /// re-enters its own observer overflows the stack and takes the app down.
    @MainActor
    func testPickingADurationClampsWithoutReenteringTheSetter() {
        let defaults = makeDefaults(named: #function)
        let store = FocusTimerStore(defaults: defaults)

        store.focusMinutes = 45
        store.breakMinutes = 10

        XCTAssertEqual(store.focusMinutes, 45)
        XCTAssertEqual(store.breakMinutes, 10)

        store.focusMinutes = 9_000
        store.breakMinutes = 0

        XCTAssertEqual(store.focusMinutes, 180)
        XCTAssertEqual(store.breakMinutes, 1)

        let restored = FocusTimerStore(defaults: defaults)
        XCTAssertEqual(restored.focusMinutes, 180)
        XCTAssertEqual(restored.breakMinutes, 1)
    }

    func testStreakSquareShadeDeepensWithEachFocusSession() {
        let ramp = (0...5).map(PomodoroOverlayLayout.shade(forSessions:))
        XCTAssertEqual(ramp[0], 0)
        XCTAssertEqual(zip(ramp, ramp.dropFirst()).filter { $0 > $1 }.count, 0,
                       "shade must never lighten as sessions grow")
        XCTAssertEqual(PomodoroOverlayLayout.shade(forSessions: 4), 1)
        XCTAssertEqual(PomodoroOverlayLayout.shade(forSessions: 40), 1)
        XCTAssertEqual(PomodoroOverlayLayout.shade(forSessions: -3), 0)
    }

    @MainActor
    func testRepeatedFocusOnOneDayDeepensThatDaysSquare() {
        let store = FocusTimerStore(defaults: makeDefaults(named: #function))
        // Anchored mid-morning so the second session can't tip into tomorrow in
        // whatever time zone the test runs in.
        let day = Calendar.current
            .startOfDay(for: Date(timeIntervalSinceReferenceDate: 10_000_000))
            .addingTimeInterval(9 * 3_600)

        store.recordFocusCompletion(on: day)
        store.recordFocusCompletion(on: day.addingTimeInterval(3_600))

        XCTAssertEqual(store.sessions(on: day), 2)
        XCTAssertEqual(store.completedDayCount, 1, "still one focused DAY")
        XCTAssertGreaterThan(PomodoroOverlayLayout.shade(forSessions: store.sessions(on: day)),
                             PomodoroOverlayLayout.shade(forSessions: 1))
    }

    @MainActor
    func testStreakDaysSavedBeforeTalliesRestoreAsOneSession() {
        let defaults = makeDefaults(named: #function)
        let day = Date(timeIntervalSinceReferenceDate: 10_000_000)
        let legacy = """
        {"phase":"ready","isRunning":false,"focusMinutes":25,"breakMinutes":5,\
        "completedDayIntervals":[\(day.timeIntervalSinceReferenceDate)]}
        """
        defaults.set(Data(legacy.utf8), forKey: "notchflow.focusTimer.v1")

        let store = FocusTimerStore(defaults: defaults)

        XCTAssertEqual(store.sessions(on: day), 1)
        XCTAssertTrue(store.isCompleted(on: day))
        XCTAssertEqual(store.completedDayCount, 1)
    }

    @MainActor
    func testFocusEndingAnnouncesTheBreakThenFoldsTheAnnouncementAway() {
        let store = FocusTimerStore(defaults: makeDefaults(named: #function))
        let start = Date(timeIntervalSinceReferenceDate: 10_000_000)
        store.start(at: start)
        let focusEnd = start.addingTimeInterval(25 * 60)

        store.refresh(at: focusEnd)
        XCTAssertEqual(store.transition, .focusEnded)

        store.refresh(at: focusEnd.addingTimeInterval(FocusTimerStore.transitionWindow + 1))
        XCTAssertNil(store.transition, "the announcement is time-boxed")
    }

    @MainActor
    func testTheRunningBorderTracesOneLapPerPhase() {
        let store = FocusTimerStore(defaults: makeDefaults(named: #function))
        let start = Date(timeIntervalSinceReferenceDate: 10_000_000)

        XCTAssertEqual(store.progress(at: start), 0, "an idle timer traces nothing")

        store.start(at: start)
        XCTAssertEqual(store.progress(at: start), 0, accuracy: 0.001)
        XCTAssertEqual(store.progress(at: start.addingTimeInterval(12.5 * 60)), 0.5, accuracy: 0.001)
        XCTAssertEqual(store.progress(at: start.addingTimeInterval(25 * 60)), 1, accuracy: 0.001)

        // The break is its own lap, not a continuation of the focus one.
        store.refresh(at: start.addingTimeInterval(25 * 60))
        XCTAssertEqual(store.phase, .break)
        let breakStart = start.addingTimeInterval(25 * 60)
        XCTAssertEqual(store.progress(at: breakStart), 0, accuracy: 0.001)
        XCTAssertEqual(store.progress(at: breakStart.addingTimeInterval(2.5 * 60)), 0.5, accuracy: 0.001)
    }

    @MainActor
    func testPausingFreezesTheBorderWhereItStopped() {
        let store = FocusTimerStore(defaults: makeDefaults(named: #function))
        let start = Date(timeIntervalSinceReferenceDate: 10_000_000)
        store.start(at: start)

        store.pause(at: start.addingTimeInterval(5 * 60))
        let frozen = store.progress(at: start.addingTimeInterval(5 * 60))

        XCTAssertEqual(frozen, 0.2, accuracy: 0.001)
        XCTAssertEqual(store.progress(at: start.addingTimeInterval(20 * 60)), frozen, accuracy: 0.001,
                       "wall-clock time must not advance a paused lap")

        store.resume(at: start.addingTimeInterval(20 * 60))
        XCTAssertEqual(store.progress(at: start.addingTimeInterval(20 * 60)), frozen, accuracy: 0.001)
        XCTAssertEqual(store.progress(at: start.addingTimeInterval(25 * 60)), 0.4, accuracy: 0.001)
    }

    @MainActor
    func testAShorterPresetStillTracesExactlyOneLap() {
        let store = FocusTimerStore(defaults: makeDefaults(named: #function))
        store.focusMinutes = 10
        let start = Date(timeIntervalSinceReferenceDate: 10_000_000)
        store.start(at: start)

        XCTAssertEqual(store.progress(at: start.addingTimeInterval(5 * 60)), 0.5, accuracy: 0.001)
        XCTAssertEqual(store.progress(at: start.addingTimeInterval(10 * 60)), 1, accuracy: 0.001)
    }

    @MainActor
    func testThePhaseHandoffIsFiveSeconds() {
        XCTAssertEqual(FocusTimerStore.transitionWindow, 5)
    }

    @MainActor
    func testBreakEndingAnnouncesTheMarkedStreak() {
        let store = FocusTimerStore(defaults: makeDefaults(named: #function))
        let start = Date(timeIntervalSinceReferenceDate: 10_000_000)
        store.start(at: start)
        let focusEnd = start.addingTimeInterval(25 * 60)
        store.refresh(at: focusEnd)

        store.refresh(at: focusEnd.addingTimeInterval(5 * 60))

        XCTAssertEqual(store.transition, .breakEnded)
        XCTAssertEqual(store.phase, .ready)
        XCTAssertEqual(store.sessions(on: start), 1)
    }

    /// Reconciling a session the Mac slept through must not announce a boundary
    /// that happened hours ago.
    @MainActor
    func testABoundaryOlderThanTheWindowNeverAnnounces() {
        let store = FocusTimerStore(defaults: makeDefaults(named: #function))
        let start = Date(timeIntervalSinceReferenceDate: 10_000_000)
        store.start(at: start)

        store.refresh(at: start.addingTimeInterval(25 * 60 + FocusTimerStore.transitionWindow + 60))

        XCTAssertEqual(store.phase, .break)
        XCTAssertNil(store.transition)
    }

    @MainActor
    func testOpeningTheTimerAcknowledgesTheAnnouncement() {
        let store = FocusTimerStore(defaults: makeDefaults(named: #function))
        let start = Date(timeIntervalSinceReferenceDate: 10_000_000)
        store.start(at: start)
        store.refresh(at: start.addingTimeInterval(25 * 60))
        XCTAssertNotNil(store.transition)

        store.acknowledgeTransition()

        XCTAssertNil(store.transition)
    }

    @MainActor
    func testStoppingClearsAnyPendingAnnouncement() {
        let store = FocusTimerStore(defaults: makeDefaults(named: #function))
        let start = Date(timeIntervalSinceReferenceDate: 10_000_000)
        store.start(at: start)
        store.refresh(at: start.addingTimeInterval(25 * 60))

        store.stop()

        XCTAssertNil(store.transition)
        XCTAssertEqual(store.phase, .ready)
    }

    // MARK: - AirPods connect / remove

    func testConnectingAirPodsIsAnnouncedImmediately() {
        var settler = AccessoryConnectionSettler()
        let airpods = ConnectedAudioDevice(name: "Siddhant’s AirPods Pro")

        XCTAssertEqual(settler.observe(airpods), .connected(airpods))
        XCTAssertEqual(settler.device, airpods)
        XCTAssertNil(settler.observe(airpods), "a steady device is not an event")
    }

    /// Replays the measured removal: Speakers → AirPods → Speakers inside one
    /// second. The old single-sample reading announced "disconnected", then
    /// overwrote it with "connected" off the flap.
    func testRemovingAirPodsSurvivesTheOutputDeviceFlappingBack() {
        let airpods = ConnectedAudioDevice(name: "Siddhant’s AirPods Pro")
        var settler = AccessoryConnectionSettler(settled: airpods)

        XCTAssertNil(settler.observe(nil), "one empty sample is not a removal yet")
        XCTAssertNil(settler.observe(airpods), "the flap back must not read as a new connection")
        XCTAssertNil(settler.observe(nil))

        XCTAssertEqual(settler.observe(nil), .disconnected(airpods))
        XCTAssertNil(settler.device)
    }

    func testATrueRemovalIsAnnouncedOnceItHolds() {
        let airpods = ConnectedAudioDevice(name: "AirPods Max")
        var settler = AccessoryConnectionSettler(settled: airpods)

        XCTAssertNil(settler.observe(nil))
        XCTAssertEqual(settler.observe(nil), .disconnected(airpods))
        XCTAssertNil(settler.observe(nil), "and only once")
    }

    func testSwappingStraightToAnotherAirPodsAnnouncesTheNewOne() {
        let pro = ConnectedAudioDevice(name: "AirPods Pro")
        let max = ConnectedAudioDevice(name: "AirPods Max")
        var settler = AccessoryConnectionSettler(settled: pro)

        XCTAssertEqual(settler.observe(max), .connected(max))
        XCTAssertEqual(settler.device, max)
    }

    // MARK: - Quick reminder

    func testQuickReminderSchedulesResolveToTheMomentTheyName() {
        let calendar = Calendar(identifier: .gregorian)
        var noon = DateComponents()
        noon.year = 2026; noon.month = 3; noon.day = 4; noon.hour = 12
        let now = calendar.date(from: noon)!

        XCTAssertNil(QuickReminderSchedule.noDate.fireDate(from: now, calendar: calendar))
        XCTAssertEqual(QuickReminderSchedule.inOneHour.fireDate(from: now, calendar: calendar),
                       now.addingTimeInterval(3_600))

        let evening = QuickReminderSchedule.thisEvening.fireDate(from: now, calendar: calendar)
        XCTAssertEqual(calendar.component(.hour, from: evening!), 20)
        XCTAssertEqual(calendar.component(.day, from: evening!), 4)

        let morning = QuickReminderSchedule.tomorrowMorning.fireDate(from: now, calendar: calendar)
        XCTAssertEqual(calendar.component(.hour, from: morning!), 9)
        XCTAssertEqual(calendar.component(.day, from: morning!), 5)
    }

    func testThisEveningRollsToTomorrowOnceTonightHasPassed() {
        let calendar = Calendar(identifier: .gregorian)
        var lateNight = DateComponents()
        lateNight.year = 2026; lateNight.month = 3; lateNight.day = 4; lateNight.hour = 22
        let now = calendar.date(from: lateNight)!

        let evening = QuickReminderSchedule.thisEvening.fireDate(from: now, calendar: calendar)!

        XCTAssertGreaterThan(evening, now)
        XCTAssertEqual(calendar.component(.day, from: evening), 5)
        XCTAssertEqual(calendar.component(.hour, from: evening), 20)
    }

    func testWhenTypedUsesTheDateReadOutOfTheLine() {
        let parsed = Date(timeIntervalSinceReferenceDate: 900_000)
        XCTAssertEqual(QuickReminderSchedule.whenTyped.fireDate(from: .now, parsed: parsed), parsed)
        XCTAssertNil(QuickReminderSchedule.whenTyped.fireDate(from: .now, parsed: nil),
                     "a line naming no date saves without one")
    }

    @MainActor
    func testQuickReminderSavesTheTrimmedLineWithItsDueDateAndThenClears() {
        var written: (text: String, due: Date?)?
        let store = QuickReminderStore(defaults: makeDefaults(named: #function)) { text, due, done in
            written = (text, due)
            done(true)
        }
        let parsed = Date(timeIntervalSinceReferenceDate: 900_000)
        store.draft = "  Call the dentist  "

        store.save(parsed: parsed)

        XCTAssertEqual(written?.text, "Call the dentist")
        XCTAssertEqual(written?.due, parsed, "the default schedule is the date in the text")
        XCTAssertEqual(store.saveState, .saved)
        XCTAssertEqual(store.draft, "", "a saved reminder leaves an empty field")
    }

    @MainActor
    func testQuickReminderIgnoresAnEmptyLine() {
        var writes = 0
        let store = QuickReminderStore(defaults: makeDefaults(named: #function)) { _, _, done in
            writes += 1
            done(true)
        }
        store.draft = "   \n "

        store.save()

        XCTAssertEqual(writes, 0)
        XCTAssertFalse(store.canSave)
        XCTAssertEqual(store.saveState, .idle)
    }

    @MainActor
    func testAFailedReminderKeepsTheLineAndClearsTheBadgeOnTheNextKeystroke() {
        let defaults = makeDefaults(named: #function)
        let store = QuickReminderStore(defaults: defaults) { _, _, done in done(false) }
        store.draft = "Water the plants"

        store.save()
        XCTAssertEqual(store.saveState, .failed)
        XCTAssertEqual(store.draft, "Water the plants")

        store.draft = "Water the plants tonight"
        store.draftChanged()
        XCTAssertEqual(store.saveState, .idle)

        // The panel folds the moment the pointer leaves, so the line has to be
        // waiting in the next store the panel builds.
        let restored = QuickReminderStore(defaults: defaults) { _, _, done in done(true) }
        XCTAssertEqual(restored.draft, "Water the plants tonight")
    }

    @MainActor
    func testQuickReminderRestoresTheChosenSchedule() {
        let defaults = makeDefaults(named: #function)
        let store = QuickReminderStore(defaults: defaults) { _, _, done in done(true) }
        store.schedule = .tomorrowMorning

        let restored = QuickReminderStore(defaults: defaults) { _, _, done in done(true) }

        XCTAssertEqual(restored.schedule, .tomorrowMorning)
    }

    @MainActor
    func testQuickNoteRestoresAnUnsavedDraft() {
        let defaults = makeDefaults(named: #function)
        let first = QuickNoteStore(defaults: defaults, writer: { _, _ in })
        first.draft = "Buy coffee"

        let restored = QuickNoteStore(defaults: defaults, writer: { _, _ in })

        XCTAssertEqual(restored.draft, "Buy coffee")
    }

    @MainActor
    func testQuickNoteSaveFailureRetainsTheDraft() {
        let store = QuickNoteStore(defaults: makeDefaults(named: #function)) { _, completion in
            completion(false)
        }
        store.draft = "Keep this"

        store.saveNow()

        XCTAssertEqual(store.draft, "Keep this")
        XCTAssertEqual(store.saveState, .failed)
    }

    @MainActor
    func testEmptyQuickNoteNeverCallsTheWriter() {
        var writes = 0
        let store = QuickNoteStore(defaults: makeDefaults(named: #function)) { _, _ in
            writes += 1
        }
        store.draft = "  \n "

        store.saveNow()

        XCTAssertEqual(writes, 0)
    }

    func testSharePickerUsesTheFileButtonBoundsAsItsAnchor() {
        let buttonBounds = CGRect(x: 0, y: 0, width: 22, height: 22)

        XCTAssertEqual(ShelfSharingLayout.pickerRect(for: buttonBounds), buttonBounds)
    }

    func testCodexTranscriptUsageRecordsOnlyCumulativeCounterDeltas() {
        let transcript = Data("""
        {"timestamp":"2026-08-30T08:00:00.000Z","ordinal":1,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":10}}}}
        {"timestamp":"2026-08-30T08:05:00.000Z","ordinal":2,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":140,"output_tokens":16}}}}
        """.utf8)

        let events = CodexTranscriptUsage.incrementalEvents(in: transcript, identifierPrefix: "rollout")

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].id, "rollout:2")
        XCTAssertEqual(events[0].input, 40)
        XCTAssertEqual(events[0].output, 6)
    }

    func testCodexTranscriptContextUsesLatestTurnInsteadOfLifetimeTotal() {
        let transcript = Data("""
        {"timestamp":"2026-08-30T08:05:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":79093569},"last_token_usage":{"total_tokens":214020},"model_context_window":258400}}}
        """.utf8)

        let context = CodexTranscriptContext.latest(in: transcript)

        XCTAssertEqual(context?.used, 214020)
        XCTAssertEqual(context?.window, 258400)
    }

    func testClaudeTranscriptUsageDeduplicatesStreamingSnapshotsByMessageID() {
        let transcript = Data("""
        {"type":"assistant","uuid":"snapshot-1","sessionId":"claude-session","timestamp":"2026-08-30T08:00:00.000Z","message":{"id":"msg-one","usage":{"input_tokens":10,"cache_read_input_tokens":20,"cache_creation_input_tokens":30,"output_tokens":4}}}
        {"type":"assistant","uuid":"snapshot-2","sessionId":"claude-session","timestamp":"2026-08-30T08:00:01.000Z","message":{"id":"msg-one","usage":{"input_tokens":10,"cache_read_input_tokens":20,"cache_creation_input_tokens":30,"output_tokens":4}}}
        {"type":"assistant","uuid":"snapshot-3","sessionId":"claude-session","timestamp":"2026-08-30T08:01:00.000Z","message":{"id":"msg-two","usage":{"input_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":2}}}
        """.utf8)

        let events = ClaudeTranscriptUsage.events(in: transcript, identifierPrefix: "claude:claude-session")

        XCTAssertEqual(events.map(\.id), ["claude:claude-session:msg-one", "claude:claude-session:msg-two"])
        XCTAssertEqual(events.map(\.input), [60, 5])
        XCTAssertEqual(events.map(\.output), [4, 2])
    }
}
