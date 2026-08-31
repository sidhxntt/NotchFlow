import XCTest
@testable import NotchCapabilities

final class SustainedAlertGateTests: XCTestCase {
    func testConditionMustRemainTrueForTheWholeDuration() {
        var gate = SustainedAlertGate(duration: 10)
        XCTAssertFalse(gate.observe(isBreached: true, at: Date(timeIntervalSince1970: 0)))
        XCTAssertFalse(gate.observe(isBreached: true, at: Date(timeIntervalSince1970: 9)))
        XCTAssertTrue(gate.observe(isBreached: true, at: Date(timeIntervalSince1970: 10)))
    }

    func testAlertFiresOnceUntilTheConditionRecovers() {
        var gate = SustainedAlertGate(duration: 1)
        _ = gate.observe(isBreached: true, at: .distantPast)
        XCTAssertTrue(gate.observe(isBreached: true, at: .distantPast.addingTimeInterval(1)))
        XCTAssertFalse(gate.observe(isBreached: true, at: .distantPast.addingTimeInterval(20)))
        XCTAssertFalse(gate.observe(isBreached: false, at: .distantPast.addingTimeInterval(21)))
        XCTAssertFalse(gate.observe(isBreached: true, at: .distantPast.addingTimeInterval(22)))
        XCTAssertTrue(gate.observe(isBreached: true, at: .distantPast.addingTimeInterval(23)))
    }

    func testZeroDurationFiresImmediately() {
        var gate = SustainedAlertGate(duration: 0)
        XCTAssertTrue(gate.observe(isBreached: true, at: .distantPast))
    }
}
