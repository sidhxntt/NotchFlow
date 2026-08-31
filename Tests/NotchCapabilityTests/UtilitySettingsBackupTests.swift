import XCTest
@testable import NotchCapabilities

final class UtilitySettingsBackupTests: XCTestCase {
    func testRoundTripPreservesOnlyPortableSettings() throws {
        let payload = UtilitySettingsBackup.makePayload(version: 1, settings: [
            "clipboard.limit": .int(100), "snippet.enabled": .bool(true),
            "api.key": .string("must-not-export"), "working.path": .string("/Users/me")
        ])
        let encoded = try UtilitySettingsBackup.encode(payload)
        let restored = try UtilitySettingsBackup.decode(encoded, supportedVersion: 1)
        XCTAssertEqual(restored.settings, ["clipboard.limit": .int(100), "snippet.enabled": .bool(true)])
    }

    func testRejectsFutureVersions() throws {
        let payload = UtilitySettingsBackup.Payload(version: 2, settings: [:])
        XCTAssertThrowsError(try UtilitySettingsBackup.decode(UtilitySettingsBackup.encode(payload), supportedVersion: 1))
    }
}
