import Testing
@testable import NotchCapabilities

@Test("identified banner text keeps the title and message while dropping its subtitle")
func identifiedBannerTextIsSplit() {
    let split = AlertBannerText.split([
        .init(identifier: "title", value: "Priya"),
        .init(identifier: "subtitle", value: "WhatsApp"),
        .init(identifier: "body", value: "Incoming call"),
    ])

    #expect(split.title == "Priya")
    #expect(split.body == "Incoming call")
}

@Test("unidentified banner text falls back without treating the subtitle as content")
func unidentifiedBannerTextUsesContentOnly() {
    let split = AlertBannerText.split([
        .init(identifier: nil, value: "Priya"),
        .init(identifier: "subtitle", value: "WhatsApp"),
        .init(identifier: nil, value: "Incoming call"),
    ])

    #expect(split.title == "Priya")
    #expect(split.body == "Incoming call")
}

@Test("one identified field retains a positional fallback for the other")
func partialIdentifiersStillProduceBothFields() {
    let split = AlertBannerText.split([
        .init(identifier: "title", value: "Priya"),
        .init(identifier: nil, value: "Incoming call"),
    ])

    #expect(split.title == "Priya")
    #expect(split.body == "Incoming call")
}
