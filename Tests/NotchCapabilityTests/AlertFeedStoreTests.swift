import XCTest
@testable import NotchCapabilities

@MainActor
final class AlertFeedStoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func store() -> AlertFeedStore {
        AlertFeedStore(ownBundleID: "com.notchflow.app")
    }

    private func banner(app: String = "WhatsApp",
                        bundleID: String? = "net.whatsapp.WhatsApp",
                        title: String = "Priya",
                        body: String = "see you at 8",
                        token: Int = 1) -> AlertBanner {
        AlertBanner(appName: app, bundleID: bundleID, title: title, body: body,
                    token: token)
    }

    // MARK: - Tally

    func testOneBannerAnnouncesItsAppWithACountOfOne() {
        let store = store()
        store.ingest(banner(), now: t0)

        guard case .notifications(let burst) = store.announcement else {
            return XCTFail("expected a notification burst, got \(String(describing: store.announcement))")
        }
        XCTAssertEqual(burst.bundleID, "net.whatsapp.WhatsApp")
        XCTAssertEqual(burst.appName, "WhatsApp")
        XCTAssertEqual(burst.count, 1)
    }

    func testRepeatBannersFromOneAppAccumulate() {
        let store = store()
        for i in 1...5 { store.ingest(banner(token: i), now: t0.addingTimeInterval(Double(i) * 0.2)) }

        guard case .notifications(let burst) = store.announcement else { return XCTFail("no burst") }
        XCTAssertEqual(burst.count, 5)
    }

    func testOurOwnBannersAreIgnored() {
        let store = store()
        store.ingest(banner(app: "NotchFlow", bundleID: "com.notchflow.app"), now: t0)
        XCTAssertNil(store.announcement)
    }

    func testUnresolvedBundleIDsStillKeepSeparateTallies() {
        let store = store()
        store.ingest(banner(app: "Alpha", bundleID: nil), now: t0)
        store.ingest(banner(app: "Beta", bundleID: nil, token: 2), now: t0)

        guard case .notifications(let burst) = store.announcement else { return XCTFail("no burst") }
        XCTAssertEqual(burst.appName, "Alpha", "the first app should still hold its slot")
        XCTAssertEqual(burst.count, 1, "Beta's banner must not land in Alpha's tally")
    }

    // MARK: - Queue

    func testASecondAppWaitsForItsOwnSlotThenTakesTheEar() {
        let store = store()
        store.ingest(banner(), now: t0)
        store.ingest(banner(app: "Slack", bundleID: "com.tinyspeck.slackmacgap", token: 2), now: t0)

        guard case .notifications(let first) = store.announcement else { return XCTFail("no burst") }
        XCTAssertEqual(first.appName, "WhatsApp", "newest app must not steal a live slot mid-dwell")

        store.tick(now: t0.addingTimeInterval(AlertFeedStore.burstWindow))

        guard case .notifications(let second) = store.announcement else { return XCTFail("no queued burst") }
        XCTAssertEqual(second.appName, "Slack")
        XCTAssertEqual(second.count, 1)
    }

    func testTheEarFoldsOnceTheQueueDrains() {
        let store = store()
        store.ingest(banner(), now: t0)
        store.tick(now: t0.addingTimeInterval(AlertFeedStore.burstWindow))
        XCTAssertNil(store.announcement)
    }

    func testAnAppIsNotQueuedTwice() {
        let store = store()
        store.ingest(banner(), now: t0)
        store.ingest(banner(app: "Slack", bundleID: "slack", token: 2), now: t0)
        store.ingest(banner(app: "Slack", bundleID: "slack", token: 3), now: t0)

        store.tick(now: t0.addingTimeInterval(AlertFeedStore.burstWindow))
        guard case .notifications(let slack) = store.announcement else { return XCTFail("no slack burst") }
        XCTAssertEqual(slack.count, 2, "both Slack banners belong to one slot")

        store.tick(now: t0.addingTimeInterval(AlertFeedStore.burstWindow * 2))
        XCTAssertNil(store.announcement, "Slack must not get a second slot")
    }

    // MARK: - Reset

    func testOpeningTheNotchClearsEveryTally() {
        let store = store()
        store.ingest(banner(), now: t0)
        store.notchDidOpen(now: t0)
        XCTAssertNil(store.announcement)

        store.ingest(banner(token: 9), now: t0)
        guard case .notifications(let burst) = store.announcement else { return XCTFail("no burst") }
        XCTAssertEqual(burst.count, 1, "the count restarts after the user has looked")
    }

    func testAStaleTallyIsForgotten() {
        let store = store()
        store.ingest(banner(), now: t0)
        store.tick(now: t0.addingTimeInterval(AlertFeedStore.tallyLifetime))
        store.ingest(banner(token: 2), now: t0.addingTimeInterval(AlertFeedStore.tallyLifetime))

        guard case .notifications(let burst) = store.announcement else { return XCTFail("no burst") }
        XCTAssertEqual(burst.count, 1, "two-minute-old news should not add to a fresh burst")
    }

    // MARK: - Incoming calls are ordinary notifications

    func testIncomingCallBannerIsAnOrdinaryNotification() {
        let store = store()
        store.ingest(banner(title: "Govind", body: "Incoming call"), now: t0)

        guard case .notifications(let burst) = store.announcement else {
            return XCTFail("an incoming call must be handled as a notification")
        }
        XCTAssertEqual(burst.appName, "WhatsApp")
        XCTAssertEqual(burst.count, 1)
    }

    func testIncomingCallBannerWaitsForTheCurrentNotificationSlot() {
        let store = store()
        store.ingest(banner(app: "Slack", bundleID: "com.tinyspeck.slackmacgap"), now: t0)
        store.ingest(banner(title: "Govind", body: "Incoming call", token: 2), now: t0)

        guard case .notifications(let burst) = store.announcement else {
            return XCTFail("an incoming call must not preempt notifications")
        }
        XCTAssertEqual(burst.appName, "Slack")

        store.tick(now: t0.addingTimeInterval(AlertFeedStore.burstWindow))
        guard case .notifications(let queued) = store.announcement else {
            return XCTFail("the incoming call banner should queue as a notification")
        }
        XCTAssertEqual(queued.appName, "WhatsApp")
    }
}
