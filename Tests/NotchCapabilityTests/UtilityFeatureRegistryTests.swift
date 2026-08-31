import XCTest
@testable import NotchCapabilities

final class UtilityFeatureRegistryTests: XCTestCase {
    func testEveryReferenceCapabilityHasOneUniqueFeatureDefinition() {
        XCTAssertEqual(UtilityFeature.allCases.count, Set(UtilityFeature.allCases).count)
        XCTAssertTrue(UtilityFeature.allCases.contains(.clipboardHistory))
        XCTAssertTrue(UtilityFeature.allCases.contains(.windowSwitcher))
        XCTAssertTrue(UtilityFeature.allCases.contains(.screenRecorder))
        XCTAssertTrue(UtilityFeature.allCases.contains(.fanControl))
        XCTAssertTrue(UtilityFeature.allCases.contains(.homebrew))
    }

    func testDestructiveFeaturesAlwaysRequireExplicitConfirmation() {
        let destructive: Set<UtilityFeature> = [.cleaner, .uninstaller, .diskImageInstaller,
                                                .homebrew, .appUpdates, .cleaningMode, .killProcess]
        for feature in destructive {
            XCTAssertTrue(UtilityFeatureRegistry.definition(for: feature).requiresConfirmation,
                          "\\(feature) must not mutate the Mac without an explicit confirmation")
        }
    }

    func testFeaturePermissionsAreCentralizedAndStable() {
        XCTAssertEqual(UtilityFeatureRegistry.definition(for: .screenRecorder).permissions,
                       [.screenRecording, .microphone])
        XCTAssertEqual(UtilityFeatureRegistry.definition(for: .clipboardHistory).permissions, [])
        XCTAssertEqual(UtilityFeatureRegistry.definition(for: .windowLayout).permissions,
                       [.accessibility])
    }

    func testPresetBundlesContainOnlyTheirNamedFamily() {
        XCTAssertTrue(UtilityFeaturePreset.windows.features.contains(.windowSwitcher))
        XCTAssertTrue(UtilityFeaturePreset.windows.features.contains(.windowLayout))
        XCTAssertFalse(UtilityFeaturePreset.windows.features.contains(.cleaner))
        XCTAssertTrue(UtilityFeaturePreset.essentials.features.contains(.clipboardHistory))
    }
}
