import XCTest
@testable import NotchCapabilities

final class WindowLayoutPlannerTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1200, height: 800)

    func testHalvesAndCornersFillExpectedScreenRegions() {
        XCTAssertEqual(WindowLayoutPlanner.frame(for: .leftHalf, in: screen), CGRect(x: 0, y: 0, width: 600, height: 800))
        XCTAssertEqual(WindowLayoutPlanner.frame(for: .topRight, in: screen), CGRect(x: 600, y: 400, width: 600, height: 400))
    }

    func testMarginIsAppliedInsideTheTargetFrame() {
        XCTAssertEqual(WindowLayoutPlanner.frame(for: .center, in: screen, margin: 20),
                       CGRect(x: 320, y: 220, width: 560, height: 360))
    }

    func testRestoreHistoryReturnsMostRecentPlacementFirst() {
        var history = WindowLayoutHistory(capacity: 2)
        history.record(.leftHalf)
        history.record(.rightHalf)
        history.record(.center)
        XCTAssertEqual(history.popRestore(), .center)
        XCTAssertEqual(history.popRestore(), .rightHalf)
        XCTAssertNil(history.popRestore())
    }
}
