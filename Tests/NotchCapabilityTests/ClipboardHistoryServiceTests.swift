import XCTest
@testable import NotchCapabilities

@MainActor
final class ClipboardHistoryServiceTests: XCTestCase {
    func testRecordingHonorsTheConfiguredLimitAndCanRestoreAnItem() {
        let service = ClipboardHistoryService(isEnabled: true, limit: 2, persistsPreferences: false)

        service.record(.text("one"), sourceBundleID: "com.example")
        service.record(.text("two"), sourceBundleID: "com.example")
        service.record(.text("three"), sourceBundleID: "com.example")

        XCTAssertEqual(service.items.map(\.content), [.text("three"), .text("two")])
        XCTAssertEqual(service.itemToRestore, .text("three"))
    }

    func testDisablingStopsCaptureButKeepsExistingHistoryAvailable() {
        let service = ClipboardHistoryService(isEnabled: true, limit: 10, persistsPreferences: false)
        service.record(.text("saved"))
        service.isEnabled = false
        service.record(.text("ignored"))

        XCTAssertEqual(service.items.map(\.content), [.text("saved")])
    }
}
