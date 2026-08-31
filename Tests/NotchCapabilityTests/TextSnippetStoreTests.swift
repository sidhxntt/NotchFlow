import XCTest
@testable import NotchCapabilities

final class TextSnippetStoreTests: XCTestCase {
    func testExpandsOnlyTheTrailingTrigger() {
        let store = TextSnippetStore(snippets: [TextSnippet(trigger: ";sig", body: "Siddhant")])
        XCTAssertEqual(store.expansion(in: "email ;sig", clipboard: "", now: .distantPast)?.replacing,
                       ";sig")
        XCTAssertNil(store.expansion(in: "email ;signature", clipboard: "", now: .distantPast))
    }

    func testLongerOverlappingTriggerWins() {
        let store = TextSnippetStore(snippets: [
            TextSnippet(trigger: ";a", body: "short"),
            TextSnippet(trigger: ";addr", body: "long")
        ])
        XCTAssertEqual(store.expansion(in: "meet ;addr", clipboard: "", now: .distantPast)?.text, "long")
    }

    func testExpandsClipboardAndDateVariablesUsingTheProvidedContext() {
        let store = TextSnippetStore(snippets: [TextSnippet(trigger: ";ctx", body: "[[clipboard]] on [[date:yyyy-MM-dd]]")])
        let date = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(store.expansion(in: ";ctx", clipboard: "copied", now: date,
                                       locale: Locale(identifier: "en_US_POSIX"), timeZone: .gmt)?.text,
                       "copied on 1970-01-01")
    }

    func testDisabledSnippetNeverExpandsAndFolderFilterIsStable() {
        let snippets = [TextSnippet(trigger: ";a", body: "A", folder: "Work"),
                        TextSnippet(trigger: ";b", body: "B", folder: "Personal", isEnabled: false)]
        let store = TextSnippetStore(snippets: snippets)
        XCTAssertNil(store.expansion(in: ";b", clipboard: "", now: .distantPast))
        XCTAssertEqual(store.snippets(in: "Work").map(\.trigger), [";a"])
    }
}
