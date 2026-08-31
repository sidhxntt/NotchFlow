import Testing
@testable import NotchCapabilities

// The banner shape below was dumped from the live Accessibility tree on
// macOS 26.6.2 by posting a real three-part notification:
//
//   AXGroup sub=AXNotificationCenterBanner
//     AXStaticText id=title    value=Priya
//     AXStaticText id=subtitle value=WhatsApp
//     AXStaticText id=body     value=Incoming call
//
// Positional splitting — first line is the title, join the rest as the body —
// produced "WhatsApp Incoming call", and `looksLikeCallText` requires the call
// phrase to OPEN the body. That is why no call ever reached the notch.

private func node(_ identifier: String?, _ value: String) -> AlertBannerText.Node {
    AlertBannerText.Node(identifier: identifier, value: value)
}

/// A banner exactly as macOS publishes it for a chat app's incoming call.
private func liveCallBanner() -> [AlertBannerText.Node] {
    [node("title", "Priya"), node("subtitle", "WhatsApp"), node("body", "Incoming call")]
}

private func banner(title: String, body: String) -> AlertBanner {
    AlertBanner(appName: "WhatsApp", bundleID: "net.whatsapp.WhatsApp",
                title: title, body: body, buttonTitles: [], token: 1)
}

@Test("the app's own subtitle never becomes part of the body")
func subtitleIsNotFoldedIntoTheBody() {
    let (title, body) = AlertBannerText.split(liveCallBanner())

    #expect(title == "Priya")
    #expect(body == "Incoming call")
}

@Test("a live three-part call banner is recognised as a call, end to end")
@MainActor func liveCallBannerIsRecognisedAsACall() {
    // The regression in one assertion: split the real node shape, feed it to the
    // real matcher, and require a call.
    let (title, body) = AlertBannerText.split(liveCallBanner())

    #expect(AlertFeedStore.looksLikeCallText(banner(title: title, body: body)))
}

@Test("the positional split this replaced would not have matched")
@MainActor func theOldPositionalSplitWouldHaveFailed() {
    // Pins WHY the fix is needed, so nobody reverts to joining the tail.
    let values = liveCallBanner().map(\.value)
    let positionalBody = values.dropFirst().joined(separator: " ")

    #expect(positionalBody == "WhatsApp Incoming call")
    #expect(!AlertFeedStore.looksLikeCallText(banner(title: values[0], body: positionalBody)))
}

@Test("a banner with no identifiers still splits by position")
func splitFallsBackToPositionWithoutIdentifiers() {
    // A future macOS that stops publishing the identifiers must degrade to the
    // old behaviour rather than to nothing at all.
    let (title, body) = AlertBannerText.split([node(nil, "Priya"), node(nil, "Incoming call")])

    #expect(title == "Priya")
    #expect(body == "Incoming call")
}

@Test("each identifier is resolved independently of the other")
func titleAndBodyFallBackSeparately() {
    // Only `body` is named; the title must still come from position rather than
    // one renamed identifier taking the whole split down.
    let (title, body) = AlertBannerText.split([node(nil, "Priya"),
                                               node("subtitle", "WhatsApp"),
                                               node("body", "Incoming call")])

    #expect(title == "Priya")
    #expect(body == "Incoming call")
}

@Test("empty texts never become the title or body")
func emptyNodesAreIgnored() {
    let (title, body) = AlertBannerText.split([node("title", ""), node(nil, "Priya"),
                                               node("body", "Incoming call")])

    #expect(title == "Priya")
    #expect(body == "Incoming call")
}

@Test("a banner with no texts at all splits to empty rather than crashing")
func noTextsSplitsToEmpty() {
    let (title, body) = AlertBannerText.split([])

    #expect(title.isEmpty)
    #expect(body.isEmpty)
}

// MARK: - The vocabulary itself

@Test("a call phrase must open the body, not merely appear in it")
@MainActor func callPhraseMustOpenTheBody() {
    #expect(AlertFeedStore.looksLikeCallText(banner(title: "Priya", body: "Incoming call")))
    // A conversation *about* a call is a message.
    #expect(!AlertFeedStore.looksLikeCallText(
        banner(title: "Priya", body: "Sorry I missed your incoming call earlier")))
}

@Test("every shipped call phrase is reachable through the matcher")
@MainActor func everyCallPhraseMatches() {
    // Guards against a phrase that can never fire — the Korean entry in
    // CallWindowWatcher was a mixed-script typo (CJK 通 + Hangul 화) that no real
    // UI string could contain.
    for phrase in AlertFeedStore.callPhrases {
        #expect(AlertFeedStore.looksLikeCallText(banner(title: "Someone", body: phrase)),
                "call phrase never matches: \(phrase)")
    }
}

@Test("call phrases are stored already normalised")
@MainActor func callPhrasesAreStoredNormalised() {
    // The set is compared against `normalizedForMatching` output, so an entry
    // carrying a space or a capital could never be equalled.
    for phrase in AlertFeedStore.callPhrases {
        #expect(AlertFeedStore.normalizedForMatching(phrase) == phrase,
                "call phrase is not in normalised form: \(phrase)")
    }
}

@Test("the Korean call vocabulary uses Hangul, not a mixed-script lookalike")
@MainActor func koreanCallVocabularyIsHangul() {
    // 통 is U+D1B5. The bug was 通 (U+901A), which merely looks similar.
    for phrase in ["음성통화", "영상통화"] {
        #expect(AlertFeedStore.callPhrases.contains(phrase))
        #expect(phrase.unicodeScalars.allSatisfy { $0.value < 0x4E00 || $0.value > 0x9FFF },
                "phrase contains a CJK ideograph: \(phrase)")
    }
}
