import XCTest
@testable import NotchCapabilities

final class CommandQueryEvaluatorTests: XCTestCase {
    func testEvaluatesExactArithmeticWithoutShellExecution() {
        XCTAssertEqual(CommandQueryEvaluator.evaluate("12 * (3 + 2)")?.title, "60")
    }

    func testRecognizesAWebURLAndKeepsTheOriginalValue() {
        let result = CommandQueryEvaluator.evaluate("https://example.com/path?q=1")
        XCTAssertEqual(result?.kind, .webURL)
        XCTAssertEqual(result?.payload, "https://example.com/path?q=1")
    }

    func testSearchRanksPrefixMatchesBeforeContainsMatches() {
        let rows = [CommandCatalogEntry(title: "Open Settings", payload: "settings"),
                    CommandCatalogEntry(title: "System Settings", payload: "system")]
        XCTAssertEqual(CommandQueryEvaluator.search("set", entries: rows).map(\.title),
                       ["Open Settings", "System Settings"])
    }
}
