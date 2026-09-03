import XCTest
@testable import NotchCapabilities

@MainActor
final class MediaCapabilityServiceRankingTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testAutomaticModeRegistersTheSystemNowPlayingProvider() {
        let service = MediaCapabilityService()
        let controllers = Mirror(reflecting: service).children
            .first(where: { $0.label == "controllers" })?.value as? [any MediaControlling]

        XCTAssertNotNil(controllers, "the automatic media sources must be inspectable")
        XCTAssertTrue(controllers?.contains(where: { $0.source == .nowPlaying }) == true,
                      "Automatic must include the system-wide Now Playing source, not just Music and Spotify")
    }

    func testFollowPlayerOptionsDoNotPromiseASiteSpecificBrowserFilter() {
        XCTAssertFalse(MediaSource.allCases.contains(.youtubeMusic),
                       "YouTube Music is supplied by a browser-wide Now Playing session, not a separate controllable source")
    }

    // MARK: - The regression: a stale dedicated track must not beat a live browser

    func testABrowserActivelyPlayingOutranksAnIdleStaleMusicTrack() {
        let browser = MediaState(source: .nowPlaying, title: "Podcast Episode",
                                  isPlaying: true, lastAudibleAt: t0)
        let music = MediaState(source: .appleMusic, title: "Old Song",
                                isPlaying: false, lastAudibleAt: .distantPast)

        XCTAssertTrue(MediaCapabilityService.ranksBelow(music, browser),
                       "a Music.app window sitting on a days-old track must not outrank audio playing right now")
        XCTAssertFalse(MediaCapabilityService.ranksBelow(browser, music))
    }

    func testABrowserJustPausedStillOutranksAnIdleStaleMusicTrack() {
        // This is the exact reported bug: pausing the browser must not hand the
        // notch to a Music.app window whose "current track" has been sitting
        // there, untouched, since long before the browser was ever opened.
        let justPaused = t0.addingTimeInterval(-1)
        let browser = MediaState(source: .nowPlaying, title: "Podcast Episode",
                                  isPlaying: false, lastAudibleAt: justPaused)
        let music = MediaState(source: .appleMusic, title: "Old Song",
                                isPlaying: false, lastAudibleAt: .distantPast)

        XCTAssertTrue(MediaCapabilityService.ranksBelow(music, browser),
                       "a browser tab that was playing a second ago must beat a stale, long-idle Music.app track")
        XCTAssertFalse(MediaCapabilityService.ranksBelow(browser, music))
    }

    // MARK: - The original intended behavior must survive

    func testMusicActuallyPlayingOutranksAnIdleNeverPlayedBrowserTab() {
        let music = MediaState(source: .appleMusic, title: "New Song",
                                isPlaying: true, lastAudibleAt: t0)
        let browser = MediaState(source: .nowPlaying, title: "Old Tab",
                                  isPlaying: false, lastAudibleAt: .distantPast)

        XCTAssertTrue(MediaCapabilityService.ranksBelow(browser, music),
                       "starting Music while a browser tab merely holds old state must still hand over the notch")
        XCTAssertFalse(MediaCapabilityService.ranksBelow(music, browser))
    }

    func testASpotifySessionThatJustStartedOutranksAnIdleBrowserTab() {
        // Spotify need not be "isPlaying" this instant to win if it was audible
        // more recently than the browser candidate — recency, not just the
        // current instant, decides once neither side is actively playing.
        let spotify = MediaState(source: .spotify, title: "Track",
                                  isPlaying: false, lastAudibleAt: t0)
        let browser = MediaState(source: .nowPlaying, title: "Old Tab",
                                  isPlaying: false, lastAudibleAt: t0.addingTimeInterval(-1000))

        XCTAssertTrue(MediaCapabilityService.ranksBelow(browser, spotify),
                       "a more recently audible dedicated source still wins when neither side is playing")
        XCTAssertFalse(MediaCapabilityService.ranksBelow(spotify, browser))
    }

    // MARK: - Same-category comparisons are unaffected

    func testTwoBrowserCandidatesRankByRecencyAlone() {
        let older = MediaState(source: .nowPlaying, title: "Tab A",
                                isPlaying: false, lastAudibleAt: t0)
        let newer = MediaState(source: .nowPlaying, title: "Tab B",
                                isPlaying: false, lastAudibleAt: t0.addingTimeInterval(60))

        XCTAssertTrue(MediaCapabilityService.ranksBelow(older, newer),
                       "within the same category the more recently audible candidate must win")
        XCTAssertFalse(MediaCapabilityService.ranksBelow(newer, older))
    }

    func testMusicAndSpotifyRankByRecencyAloneWhenBothDedicated() {
        let music = MediaState(source: .appleMusic, title: "Song",
                                isPlaying: false, lastAudibleAt: t0)
        let spotify = MediaState(source: .spotify, title: "Track",
                                  isPlaying: false, lastAudibleAt: t0.addingTimeInterval(60))

        XCTAssertTrue(MediaCapabilityService.ranksBelow(music, spotify),
                       "two dedicated sources must still rank purely by recency between each other")
        XCTAssertFalse(MediaCapabilityService.ranksBelow(spotify, music))
    }
}
