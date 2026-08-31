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
                        buttons: [String] = ["Reply", "Mark as Read"],
                        token: Int = 1) -> AlertBanner {
        AlertBanner(appName: app, bundleID: bundleID, title: title, body: body,
                    buttonTitles: buttons, token: token)
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

    // MARK: - Call classification

    func testAcceptAndDeclineButtonsMakeItACall() {
        let store = store()
        store.ingest(banner(title: "Govind", body: "Incoming call",
                            buttons: ["Accept", "Decline"]), now: t0)

        guard case .call(let call) = store.announcement else { return XCTFail("expected a call") }
        XCTAssertEqual(call.callerName, "Govind")
        XCTAssertEqual(call.state, .ringing)
        XCTAssertTrue(call.canAct)
    }

    func testAcceptWithoutDeclineIsNotACall() {
        let store = store()
        store.ingest(banner(buttons: ["Join", "Mark as Read"]), now: t0)
        guard case .notifications = store.announcement else {
            return XCTFail("a lone accept-shaped button must stay a notification")
        }
    }

    func testDismissAloneIsNotACall() {
        let store = store()
        store.ingest(banner(buttons: ["Dismiss"]), now: t0)
        guard case .notifications = store.announcement else {
            return XCTFail("Dismiss is the generic banner action, not a decline")
        }
    }

    func testCallVocabularyIsMatchedAcrossLanguages() {
        for (accept, decline) in [("接聽", "拒絕"), ("応答", "拒否"), ("Répondre", "Refuser"),
                                  ("Contestar", "Rechazar"), ("수락", "거절"), ("Pick Up", "Hang Up")] {
            let store = store()
            store.ingest(banner(title: "Caller", buttons: [accept, decline]), now: t0)
            guard case .call = store.announcement else {
                return XCTFail("\(accept)/\(decline) should classify as a call")
            }
        }
    }

    func testACallOutranksALiveNotificationBurst() {
        let store = store()
        store.ingest(banner(), now: t0)
        store.ingest(banner(app: "FaceTime", bundleID: "com.apple.FaceTime", title: "Mum",
                            buttons: ["Accept", "Decline"], token: 2), now: t0)

        guard case .call(let call) = store.announcement else { return XCTFail("call must preempt") }
        XCTAssertEqual(call.callerName, "Mum")
    }

    func testCallerFallsBackToTheAppNameWhenTheBannerHasNoTitle() {
        let store = store()
        store.ingest(banner(app: "Telegram", title: "", body: "",
                            buttons: ["Accept", "Decline"]), now: t0)
        guard case .call(let call) = store.announcement else { return XCTFail("no call") }
        XCTAssertEqual(call.callerName, "Telegram")
    }

    // MARK: - Call classification from text (buttons hidden)

    func testAWhatsAppCallIsACallEvenWithNoButtonsExposed() {
        let store = store()
        store.ingest(banner(app: "WhatsApp", title: "Priya", body: "Incoming voice call",
                            buttons: []), now: t0)

        guard case .call(let call) = store.announcement else {
            return XCTFail("a call banner whose buttons AX never exposed must still read as a call")
        }
        XCTAssertEqual(call.callerName, "Priya")
        XCTAssertFalse(call.canAct, "with no buttons the ear must not offer to answer")
    }

    func testCallTextIsRecognisedAcrossLanguages() {
        for body in ["Incoming call", "来电", "着信", "Appel entrant", "Llamada entrante", "수신 전화"] {
            let store = store()
            store.ingest(banner(title: "Caller", body: body, buttons: []), now: t0)
            guard case .call = store.announcement else {
                return XCTFail("body \"\(body)\" should read as a call")
            }
        }
    }

    func testAMessageMENTIONINGACallIsStillAMessage() {
        let store = store()
        store.ingest(banner(title: "Priya",
                            body: "sorry I missed your incoming call earlier",
                            buttons: []), now: t0)
        guard case .notifications = store.announcement else {
            return XCTFail("a chat message about calls must not ring the notch")
        }
    }

    func testButtonsWinOverTextWhenBothPresent() {
        let store = store()
        store.ingest(banner(title: "Govind", body: "Incoming call",
                            buttons: ["Accept", "Decline"]), now: t0)
        guard case .call(let call) = store.announcement else { return XCTFail("no call") }
        XCTAssertTrue(call.canAct, "real buttons mean the notch can really answer")
    }

    // MARK: - Call actions

    func testAcceptingPressesTheBannerAndConnects() {
        let store = store()
        var pressed: [(Int, AlertCallAction)] = []
        store.pressHandler = { token, action in pressed.append((token, action)); return true }
        store.ingest(banner(title: "Govind", buttons: ["Accept", "Decline"], token: 7), now: t0)

        store.perform(.accept, now: t0)

        XCTAssertEqual(pressed.count, 1)
        XCTAssertEqual(pressed.first?.0, 7)
        XCTAssertEqual(pressed.first?.1, .accept)
        guard case .call(let call) = store.announcement else { return XCTFail("call should remain") }
        XCTAssertEqual(call.state, .connected)
    }

    func testDecliningClearsTheEar() {
        let store = store()
        store.pressHandler = { _, _ in true }
        store.ingest(banner(buttons: ["Accept", "Decline"]), now: t0)

        store.perform(.decline, now: t0)
        XCTAssertNil(store.announcement)
    }

    func testAFailedPressHandsOffToTheSourceAppInsteadOfLying() {
        let store = store()
        var handedOff: [String?] = []
        store.pressHandler = { _, _ in false }
        store.handOffHandler = { handedOff.append($0) }
        store.ingest(banner(app: "WhatsApp", buttons: ["Accept", "Decline"]), now: t0)

        store.perform(.accept, now: t0)

        XCTAssertEqual(handedOff, ["net.whatsapp.WhatsApp"])
        guard case .call(let call) = store.announcement else { return XCTFail("call should remain") }
        XCTAssertEqual(call.state, .handedOff)
        XCTAssertFalse(call.canAct, "the ear must stop claiming it can answer")
    }

    func testAnsweringStampsWhenTheCallWentLive() {
        let store = store()
        store.pressHandler = { _, _ in true }
        store.ingest(banner(buttons: ["Accept", "Decline"]), now: t0)

        let answeredAt = t0.addingTimeInterval(4)
        store.perform(.accept, now: answeredAt)

        guard case .call(let call) = store.announcement else { return XCTFail("no call") }
        XCTAssertEqual(call.connectedAt, answeredAt, "the duration clock counts from the answer")
    }

    func testALiveCallHoldsTheEarIndefinitely() {
        let store = store()
        store.pressHandler = { _, _ in true }
        store.ingest(banner(buttons: ["Accept", "Decline"]), now: t0)
        store.perform(.accept, now: t0)

        // An hour in, a call the user is still on is still the notch's business —
        // it is a standing state like the current track, not an announcement.
        store.tick(now: t0.addingTimeInterval(3600))
        guard case .call(let call) = store.announcement else {
            return XCTFail("a live call must not time out")
        }
        XCTAssertEqual(call.state, .connected)
    }

    func testALiveCallEndsWhenItsSourceGoesAway() {
        let store = store()
        store.pressHandler = { _, _ in true }
        store.ingest(banner(buttons: ["Accept", "Decline"], token: 5), now: t0)
        store.perform(.accept, now: t0)

        store.bannerVanished(token: 5, now: t0.addingTimeInterval(120))
        XCTAssertNil(store.announcement, "the ear clears when the call itself is over")
    }

    func testARingingCallHasNoDurationYet() {
        let store = store()
        store.ingest(banner(buttons: ["Accept", "Decline"]), now: t0)
        guard case .call(let call) = store.announcement else { return XCTFail("no call") }
        XCTAssertNil(call.connectedAt)
    }

    // MARK: - A source answering the call for us

    func testASourceCanPromoteARingingCallToLive() {
        let store = store()
        store.ingest(banner(buttons: ["Accept", "Decline"], token: 11), now: t0)

        // Answered on the phone, or in the app's own window — not from the notch.
        let answered = t0.addingTimeInterval(6)
        store.updateCallState(token: 11, to: .connected, now: answered)

        guard case .call(let call) = store.announcement else { return XCTFail("no call") }
        XCTAssertEqual(call.state, .connected)
        XCTAssertEqual(call.connectedAt, answered)
    }

    func testPromotingKeepsTheOriginalStartWhenAlreadyLive() {
        let store = store()
        store.pressHandler = { _, _ in true }
        store.ingest(banner(buttons: ["Accept", "Decline"], token: 11), now: t0)
        store.perform(.accept, now: t0)

        store.updateCallState(token: 11, to: .connected, now: t0.addingTimeInterval(30))
        guard case .call(let call) = store.announcement else { return XCTFail("no call") }
        XCTAssertEqual(call.connectedAt, t0, "the clock must not restart on a repeat signal")
    }

    func testAStateUpdateForAnotherCallIsIgnored() {
        let store = store()
        store.ingest(banner(buttons: ["Accept", "Decline"], token: 11), now: t0)
        store.updateCallState(token: 99, to: .connected, now: t0)
        guard case .call(let call) = store.announcement else { return XCTFail("no call") }
        XCTAssertEqual(call.state, .ringing)
    }

    func testAVanishedBannerRetiresTheCall() {
        let store = store()
        store.ingest(banner(buttons: ["Accept", "Decline"], token: 4), now: t0)
        store.bannerVanished(token: 4, now: t0)
        XCTAssertNil(store.announcement)
    }

    func testAVanishedUnrelatedBannerLeavesTheCallAlone() {
        let store = store()
        store.ingest(banner(buttons: ["Accept", "Decline"], token: 4), now: t0)
        store.bannerVanished(token: 99, now: t0)
        guard case .call = store.announcement else { return XCTFail("wrong banner retired the call") }
    }

    func testARingingCallNobodyAnsweredExpires() {
        let store = store()
        store.ingest(banner(buttons: ["Accept", "Decline"]), now: t0)
        store.tick(now: t0.addingTimeInterval(AlertFeedStore.ringingLifetime))
        XCTAssertNil(store.announcement)
    }

    func testAnAnsweredCallDoesNotExpireOnTheRingingTimeout() {
        let store = store()
        store.pressHandler = { _, _ in true }
        store.ingest(banner(buttons: ["Accept", "Decline"]), now: t0)
        store.perform(.accept, now: t0)

        store.tick(now: t0.addingTimeInterval(AlertFeedStore.ringingLifetime * 2))
        guard case .call(let call) = store.announcement else { return XCTFail("a live call was dropped") }
        XCTAssertEqual(call.state, .connected)
    }

    func testOpeningTheNotchDoesNotAnswerOrDropARingingCall() {
        let store = store()
        store.ingest(banner(buttons: ["Accept", "Decline"]), now: t0)
        store.notchDidOpen(now: t0)
        guard case .call(let call) = store.announcement else { return XCTFail("call was dropped") }
        XCTAssertEqual(call.state, .ringing)
    }

    // MARK: - Invisible characters
    //
    // Every case above is written in clean ASCII, which is exactly why this
    // feature shipped broken: no real call app sends clean ASCII. WhatsApp
    // prefixes every user-facing string it ships with U+200E (LEFT-TO-RIGHT
    // MARK) so a caller's name in a right-to-left script cannot flip the layout
    // around it — its own string catalogue stores the button as
    // "\u{200E}Accept", and NSRunningApplication reports the app itself as
    // "\u{200E}WhatsApp". Apple's apps wrap names in the bidi isolates
    // U+2068/U+2069 for the same reason. None of that is visible in a diff, and
    // all of it used to defeat the vocabulary match outright.

    func testAWhatsAppCallRingsEvenThoughEveryStringCarriesABidiMark() {
        let store = store()
        store.ingest(banner(app: "\u{200E}WhatsApp",
                            title: "\u{200E}Priya",
                            body: "",
                            buttons: ["\u{200E}Accept", "\u{200E}Decline"]), now: t0)

        guard case .call(let call) = store.announcement else {
            return XCTFail("the exact strings WhatsApp ships must still read as a call")
        }
        XCTAssertTrue(call.canAct)
    }

    func testCallTextSurvivesTheSameBidiMark() {
        let store = store()
        store.ingest(banner(title: "\u{200E}Priya",
                            body: "\u{200E}Incoming voice call",
                            buttons: []), now: t0)

        guard case .call = store.announcement else {
            return XCTFail("a bidi mark in front of the body must not hide the call")
        }
    }

    func testEveryInvisibleWrapperRealAppsUseNormalizesAway() {
        // In order: the LTR mark, the RTL mark, the first-strong isolate and its
        // terminator, a zero-width space, a byte-order mark, a soft hyphen, a
        // narrow no-break space, and an ordinary no-break space.
        let wrapped = [
            "\u{200E}Accept", "\u{200F}Accept",
            "\u{2068}Accept\u{2069}", "\u{200B}Accept",
            "\u{FEFF}Accept", "Ac\u{00AD}cept",
            "Pick\u{202F}Up", "Pick\u{00A0}Up",
        ]
        for label in wrapped {
            XCTAssertTrue(
                AlertFeedStore.acceptWords.contains(AlertFeedStore.normalizedForMatching(label)),
                "\(label.unicodeScalars.map { "U+\(String($0.value, radix: 16))" }) should match")
        }
    }

    func testNormalizationStillTellsDifferentWordsApart() {
        // Stripping invisibles must not start collapsing real words together:
        // "Dismiss" is deliberately absent from the decline vocabulary, and it
        // has to stay absent.
        XCTAssertFalse(AlertFeedStore.declineWords
            .contains(AlertFeedStore.normalizedForMatching("\u{200E}Dismiss")))
        XCTAssertEqual(AlertFeedStore.normalizedForMatching("\u{200E}End Call"), "endcall")
    }

    // MARK: - Calls a source already recognised

    func testASourceCanHandOverACallItAlreadyRecognised() {
        let store = store()
        store.ingest(call: liveCall(state: .ringing), now: t0)

        guard case .call(let call) = store.announcement else { return XCTFail("no call") }
        XCTAssertEqual(call.callerName, "Priya")
        XCTAssertTrue(call.canAct)
    }

    func testACallJoinedInProgressIsACallAndNotANotification() {
        // The window watcher sees a conversation already under way: one hang-up
        // button and no accept. Routed through the banner rule that used to
        // become a bell and a "1" on the shoulder, which is how a live call
        // disappeared from the notch entirely.
        let store = store()
        store.ingest(call: liveCall(state: .connected), now: t0)

        guard case .call(let call) = store.announcement else {
            return XCTFail("a call in progress must not be filed as a notification")
        }
        XCTAssertEqual(call.state, .connected)
        XCTAssertEqual(call.connectedAt, t0, "the duration clock has to start somewhere")
    }

    func testAHandedOverCallOutranksABurstAlreadyOnTheShoulders() {
        let store = store()
        store.ingest(banner(), now: t0)
        store.ingest(call: liveCall(state: .ringing), now: t0)

        guard case .call = store.announcement else { return XCTFail("the call must take the strip") }
    }

    func testSeeingTheSameCallAgainDoesNotRestartItsClock() {
        // The watcher re-reports on every one-second sweep. If each sighting
        // re-adopted the call, a long conversation's timer would sit at 0:00 and
        // a ringing call would never time out.
        let store = store()
        store.ingest(call: liveCall(state: .ringing), now: t0)
        store.ingest(call: liveCall(state: .connected), now: t0.addingTimeInterval(4))
        store.ingest(call: liveCall(state: .connected), now: t0.addingTimeInterval(9))

        guard case .call(let call) = store.announcement else { return XCTFail("no call") }
        XCTAssertEqual(call.connectedAt, t0.addingTimeInterval(4),
                       "the clock must keep the moment it went live")
    }

    func testOurOwnCallsAreIgnoredJustLikeOurOwnBanners() {
        let store = store()
        store.ingest(call: AlertCall(callerName: "Loop", appName: "NotchFlow",
                                     bundleID: "com.notchflow.app", token: 1,
                                     state: .ringing, canAct: true), now: t0)
        XCTAssertNil(store.announcement)
    }

    private func liveCall(state: AlertCall.State, token: Int = 1_000_000) -> AlertCall {
        AlertCall(callerName: "Priya", appName: "WhatsApp",
                  bundleID: "net.whatsapp.WhatsApp", token: token,
                  state: state, canAct: true)
    }
}
