import XCTest
@testable import NotchCapabilities

/// The settings panes added for Agent, Utilities, and Media are only worth having
/// if the stored value actually reaches the code that reads it. These tests cover
/// that hand-off — the default when nothing is stored, the override, and the
/// behaviour the override is supposed to change — rather than the controls
/// themselves, which live in the app target.
///
/// Every knob here is backed by `UserDefaults.standard`, so each test restores
/// what it found. Without that, one test's override leaks into the next run of
/// the suite (the defaults domain outlives the process).
final class SettingsPolicyTests: XCTestCase {
    private func withStoredValue<T>(_ key: String, _ body: () throws -> T) rethrows -> T {
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        return try body()
    }

    // MARK: - Agent timings

    func testAgentTimingsFallBackToTheirDocumentedDefaults() {
        withStoredValue("agentPermissionDelay") {
            UserDefaults.standard.removeObject(forKey: "agentPermissionDelay")
            XCTAssertEqual(AgentPermissionPolicy.delay, AgentPermissionPolicy.defaultDelay)
            XCTAssertEqual(AgentPermissionPolicy.delay, 5)
        }
        withStoredValue("agentStalledAfter") {
            UserDefaults.standard.removeObject(forKey: "agentStalledAfter")
            XCTAssertEqual(AgentSessionTerminal.stalledAfter, 180)
        }
        withStoredValue("agentActiveFileWindow") {
            UserDefaults.standard.removeObject(forKey: "agentActiveFileWindow")
            XCTAssertEqual(AgentSessionObservation.activeFileWindow, 24 * 60 * 60)
        }
    }

    func testAStoredPermissionDelayChangesWhenAToolCallCountsAsAPrompt() {
        withStoredValue("agentPermissionDelay") {
            AgentPermissionPolicy.delay = 30
            XCTAssertFalse(AgentPermissionPolicy.needsTerminalHandoff(forToolName: "Bash", elapsed: 29))
            XCTAssertTrue(AgentPermissionPolicy.needsTerminalHandoff(forToolName: "Bash", elapsed: 30))
            // The eligible-tool list is what excuses read-only work, not the timer:
            // a longer fuse must not start surfacing Read.
            XCTAssertFalse(AgentPermissionPolicy.needsTerminalHandoff(forToolName: "Read", elapsed: 300))
        }
    }

    func testAStoredStallWindowChangesWhenASilentTurnStopsBeingBelieved() {
        withStoredValue("agentStalledAfter") {
            AgentSessionTerminal.stalledAfter = 60
            XCTAssertNil(AgentSessionTerminal.inferred(completed: false, aborted: false, inactiveFor: 59))
            XCTAssertEqual(AgentSessionTerminal.inferred(completed: false, aborted: false, inactiveFor: 60),
                           .interrupted)
            // An explicit outcome still outranks the clock at any window.
            XCTAssertEqual(AgentSessionTerminal.inferred(completed: true, aborted: false, inactiveFor: 0),
                           .completed)
        }
    }

    func testAStoredSessionWindowChangesWhichTranscriptsCountAsActive() {
        withStoredValue("agentActiveFileWindow") {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            AgentSessionObservation.activeFileWindow = 6 * 60 * 60

            XCTAssertTrue(AgentSessionObservation
                .isWithinActiveWindow(now.addingTimeInterval(-5 * 60 * 60), now: now))
            XCTAssertFalse(AgentSessionObservation
                .isWithinActiveWindow(now.addingTimeInterval(-7 * 60 * 60), now: now))
        }
    }

    func testAZeroOrNegativeStoredTimingIsIgnoredRatherThanObeyed() {
        // A zero permission delay would make every eligible tool call an instant
        // prompt, and a zero stall window would mark every live turn interrupted.
        withStoredValue("agentPermissionDelay") {
            UserDefaults.standard.set(0.0, forKey: "agentPermissionDelay")
            XCTAssertEqual(AgentPermissionPolicy.delay, AgentPermissionPolicy.defaultDelay)
        }
        withStoredValue("agentStalledAfter") {
            UserDefaults.standard.set(-1.0, forKey: "agentStalledAfter")
            XCTAssertEqual(AgentSessionTerminal.stalledAfter,
                           AgentSessionTerminal.defaultStalledAfter)
        }
    }

    // MARK: - Sub-agent badge

    func testTheSubagentBadgeIsDisplayOnlyAndTheCountSurvivesHidingIt() {
        withStoredValue("agentShowsSubagents") {
            var record = AgentSessionState(id: "root", source: .claude, status: .working,
                                           subagentCount: 3)

            AgentDisplayPolicy.showsSubagents = true
            XCTAssertEqual(record.subagentBadge, "3")

            AgentDisplayPolicy.showsSubagents = false
            XCTAssertNil(record.subagentBadge)
            // The number itself is still there — the setting hides a cue, it does
            // not change what the app believes about the session.
            XCTAssertEqual(record.subagentCount, 3)

            record.subagentCount = 0
            AgentDisplayPolicy.showsSubagents = true
            XCTAssertNil(record.subagentBadge, "no children, no badge, at any setting")
        }
    }

    // MARK: - Workspace tabs

    func testCompanionModeOffersThreeTabsAndNoAgenticOnes() {
        XCTAssertEqual(NotchWorkspaceTab.companionTabs, [.media, .utilities, .activityMonitor])
        for tab in NotchWorkspaceTab.companionTabs {
            XCTAssertNotEqual(tab, .chat)
            XCTAssertNotEqual(tab, .agent)
            XCTAssertNotEqual(tab, .aiActivityMonitor)
        }
    }

    func testEveryWorkspaceTabHasItsOwnGlyph() {
        // Activity Monitor became a first-class companion tab; the switcher's old
        // ternary chain ended in the Utilities grid, so a new tab silently
        // inherited the wrong icon.
        let symbols = NotchWorkspaceTab.allCases.map(\.symbolName)
        XCTAssertEqual(Set(symbols).count, NotchWorkspaceTab.allCases.count, "\(symbols)")
        XCTAssertEqual(NotchWorkspaceTab.activityMonitor.symbolName,
                       "gauge.with.dots.needle.67percent")
        XCTAssertEqual(NotchWorkspaceTab.utilities.symbolName, "square.grid.2x2")
    }

    // MARK: - Quick-action strip

    func testHidingAQuickActionRemovesItFromTheStripOnly() {
        withStoredValue("utilityQuickActionsHidden") {
            QuickUtilityStrip.hidden = []
            XCTAssertEqual(QuickUtilityStrip.visibleActions.count, QuickUtilityAction.allCases.count)

            XCTAssertTrue(QuickUtilityStrip.setVisible(false, for: .pomodoro))
            XCTAssertFalse(QuickUtilityStrip.isVisible(.pomodoro))
            XCTAssertTrue(QuickUtilityStrip.isVisible(.clipboard))
            // The overlay behind a hidden chip still exists and is still openable.
            XCTAssertEqual(UtilityOverlayKind(for: .pomodoro), .pomodoro)

            XCTAssertTrue(QuickUtilityStrip.setVisible(true, for: .pomodoro))
            XCTAssertTrue(QuickUtilityStrip.isVisible(.pomodoro))
        }
    }

    func testTheStripRefusesToBecomeEmpty() {
        withStoredValue("utilityQuickActionsHidden") {
            QuickUtilityStrip.hidden = []
            let all = QuickUtilityAction.allCases
            for action in all.dropLast() {
                XCTAssertTrue(QuickUtilityStrip.setVisible(false, for: action))
            }
            XCTAssertEqual(QuickUtilityStrip.visibleActions, [all.last!])

            // The refusal is reported, not silently corrected, so a switch in the
            // settings pane can decline to move.
            XCTAssertFalse(QuickUtilityStrip.setVisible(false, for: all.last!))
            XCTAssertEqual(QuickUtilityStrip.visibleActions, [all.last!])
        }
    }

    func testAStoredStripThatHidesEverythingFallsBackToTheFullSet() {
        withStoredValue("utilityQuickActionsHidden") {
            // Reachable by hand-editing defaults, or by a future release renaming
            // enough chips. A blank strip is a worse answer than ignoring the file.
            QuickUtilityStrip.hidden = Set(QuickUtilityAction.allCases.map(\.id))
            XCTAssertEqual(QuickUtilityStrip.visibleActions, QuickUtilityAction.allCases)
        }
    }

    func testHiddenChipsAreStoredByNameSoReorderingCasesCannotRemapThem() {
        withStoredValue("utilityQuickActionsHidden") {
            QuickUtilityStrip.hidden = ["Clipboard"]
            XCTAssertFalse(QuickUtilityStrip.isVisible(.clipboard))
            XCTAssertTrue(QuickUtilityStrip.isVisible(.pomodoro))

            // A name from a build that no longer has that chip is inert.
            QuickUtilityStrip.hidden = ["Teleport"]
            XCTAssertEqual(QuickUtilityStrip.visibleActions, QuickUtilityAction.allCases)
        }
    }

    // MARK: - Temperature unit

    func testTemperatureUnitOverridesTheLocaleAndReachesTheDisplayedString() {
        withStoredValue("utilityTemperatureUnit") {
            let snapshot = WeatherSnapshot(temperatureC: 20, code: 0, isDay: true,
                                           fetchedAt: Date(timeIntervalSince1970: 0))

            WeatherUnitPreference.current = .celsius
            XCTAssertEqual(WeatherUnitPreference.current, .celsius)
            XCTAssertEqual(snapshot.shortTemperature, "20°")

            WeatherUnitPreference.current = .fahrenheit
            XCTAssertEqual(snapshot.shortTemperature, "68°")

            // System means "ask the locale", which is what this always did.
            WeatherUnitPreference.current = .system
            XCTAssertEqual(WeatherUnitPreference.current.usesFahrenheit,
                           Locale.current.measurementSystem == .us)
        }
    }

    func testAnUnreadableStoredUnitFallsBackToSystem() {
        withStoredValue("utilityTemperatureUnit") {
            UserDefaults.standard.set("kelvin", forKey: "utilityTemperatureUnit")
            XCTAssertEqual(WeatherUnitPreference.current, .system)
        }
    }

    // MARK: - Media

    func testTheClosedNotchToggleGatesTheCollapsedNowPlayingPreview() {
        withStoredValue("mediaShowsInClosedNotch") {
            let playing = MediaState(source: .spotify, title: "Song", isPlaying: true)

            UserDefaults.standard.removeObject(forKey: "mediaShowsInClosedNotch")
            XCTAssertTrue(MediaPresentationPolicy.showsInClosedNotch, "on by default")
            XCTAssertTrue(NotchCapabilityPresentation.supportsCollapsedPreview(playing))

            MediaPresentationPolicy.showsInClosedNotch = false
            XCTAssertFalse(NotchCapabilityPresentation.supportsCollapsedPreview(playing))

            // And silence still shows nothing when the toggle is on.
            MediaPresentationPolicy.showsInClosedNotch = true
            XCTAssertFalse(NotchCapabilityPresentation.supportsCollapsedPreview(.inactive))
        }
    }

    func testThePreferredPlayerRoundTripsAndAutomaticClearsIt() {
        withStoredValue("mediaPreferredSource") {
            UserDefaults.standard.removeObject(forKey: "mediaPreferredSource")
            XCTAssertNil(MediaPresentationPolicy.preferredSource, "Automatic is the default")

            MediaPresentationPolicy.preferredSource = .appleMusic
            XCTAssertEqual(MediaPresentationPolicy.preferredSource, .appleMusic)

            MediaPresentationPolicy.preferredSource = nil
            XCTAssertNil(MediaPresentationPolicy.preferredSource)
            XCTAssertNil(UserDefaults.standard.string(forKey: "mediaPreferredSource"),
                         "Automatic must clear the key, not store a sentinel")
        }
    }

    func testAnUnreadableStoredPlayerIsTreatedAsAutomatic() {
        withStoredValue("mediaPreferredSource") {
            UserDefaults.standard.set("winamp", forKey: "mediaPreferredSource")
            XCTAssertNil(MediaPresentationPolicy.preferredSource)
        }
    }

    // MARK: - Clipboard retention

    @MainActor
    func testTheStoredClipboardLimitIsHonouredAndNeverDropsBelowOne() {
        let key = ClipboardHistoryService.limitDefaultsKey
        withStoredValue(key) {
            UserDefaults.standard.set(3, forKey: key)
            var store = ClipboardHistoryStore(
                limit: UserDefaults.standard.integer(forKey: key))
            for index in 1...5 {
                store.record(.text("entry \(index)"))
            }
            XCTAssertEqual(store.items.count, 3)
            XCTAssertEqual(store.items.first?.content, .text("entry 5"))
        }
    }
}
