import XCTest
@testable import NotchCapabilities

final class SecurePromptPolicyTests: XCTestCase {
    func testRecognisesSystemAuthenticationProcesses() {
        XCTAssertTrue(SecurePromptPolicy.isSecurePrompt(ownerName: "coreautha"))
        XCTAssertTrue(SecurePromptPolicy.isSecurePrompt(ownerName: "SecurityAgent"))
        XCTAssertFalse(SecurePromptPolicy.isSecurePrompt(ownerName: "Safari"))
        XCTAssertFalse(SecurePromptPolicy.isSecurePrompt(ownerName: nil))
    }

    func testUnknownHighWindowIgnoresMenusOrdinaryUIAndLowWindows() {
        let island = 25
        XCTAssertTrue(SecurePromptPolicy.isUnknownHighWindow(ownerName: "SomeAgent", layer: 25, islandLayer: island))
        XCTAssertFalse(SecurePromptPolicy.isUnknownHighWindow(ownerName: "Safari", layer: 101, islandLayer: island))
        XCTAssertFalse(SecurePromptPolicy.isUnknownHighWindow(ownerName: "Safari", layer: 0, islandLayer: island))
        XCTAssertFalse(SecurePromptPolicy.isUnknownHighWindow(ownerName: "Dock", layer: 30, islandLayer: island))
        XCTAssertFalse(SecurePromptPolicy.isUnknownHighWindow(ownerName: "coreautha", layer: 30, islandLayer: island))
    }
}
