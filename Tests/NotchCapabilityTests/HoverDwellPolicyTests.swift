import XCTest
@testable import NotchCapabilities

final class HoverDwellPolicyTests: XCTestCase {
    func testLevelsHaveDistinctHoverOpenDelays() throws {
        XCTAssertNil(HoverDwellPolicy.openingDelay(for: .click))

        let low = try XCTUnwrap(HoverDwellPolicy.openingDelay(for: .low))
        let balanced = try XCTUnwrap(HoverDwellPolicy.openingDelay(for: .balanced))
        let instant = try XCTUnwrap(HoverDwellPolicy.openingDelay(for: .instant))

        XCTAssertGreaterThanOrEqual(low, 0.4)
        XCTAssertGreaterThanOrEqual(balanced, 0.15)
        XCTAssertLessThan(balanced, low)
        XCTAssertEqual(instant, 0)
    }
}
