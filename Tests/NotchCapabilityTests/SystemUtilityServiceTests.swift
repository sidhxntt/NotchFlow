import XCTest
@testable import NotchCapabilities

final class SystemUtilityServiceTests: XCTestCase {
    /// Shaped exactly like the payload this machine produces: the same device
    /// appears in two sections, one with only a case level and one with bud
    /// levels too.
    private let payload = Data("""
    {"SPBluetoothDataType":[{
      "device_connected":[
        {"Priya’s AirPods Pro":{"device_batteryLevelCase":"79%"}},
        {"Priya’s AirPods Pro":{"device_batteryLevelCase":"79%","device_batteryLevelLeft":"90%","device_batteryLevelRight":"94%"}},
        {"Magic Mouse":{"device_batteryLevelMain":"12%"}}
      ]
    }]}
    """.utf8)

    func testBudLevelsWinOverTheCaseLevel() {
        let readings = SystemUtilityService.parseBluetoothBatteries(payload)
        let airpods = readings.first { $0.name.contains("AirPods") }
        // The buds are what die mid-call. Reporting the case's 79% while the buds
        // sit at 90% understates what you can actually use.
        XCTAssertEqual(airpods?.percent, 90)
    }

    func testTheSameDeviceIsListedOnce() {
        let readings = SystemUtilityService.parseBluetoothBatteries(payload)
        XCTAssertEqual(readings.filter { $0.name.contains("AirPods") }.count, 1)
    }

    func testAMainLevelIsUsedWhenThereAreNoBuds() {
        let readings = SystemUtilityService.parseBluetoothBatteries(payload)
        XCTAssertEqual(readings.first { $0.name == "Magic Mouse" }?.percent, 12)
    }

    func testLowIsFlaggedOnlyWhenNotCharging() {
        let readings = SystemUtilityService.parseBluetoothBatteries(payload)
        XCTAssertTrue(readings.first { $0.name == "Magic Mouse" }?.isLow ?? false)

        let charging = BatteryReading(name: "Mac", percent: 8, isCharging: true, symbolName: "bolt.fill")
        XCTAssertFalse(charging.isLow, "a charging battery is not a problem to flag")
    }

    func testGarbageAndEmptyPayloads() {
        XCTAssertEqual(SystemUtilityService.parseBluetoothBatteries(Data("nonsense".utf8)).count, 0)
        XCTAssertEqual(SystemUtilityService.parseBluetoothBatteries(Data("{}".utf8)).count, 0)
        XCTAssertEqual(
            SystemUtilityService.parseBluetoothBatteries(
                Data(#"{"SPBluetoothDataType":[{"device_connected":[{"Speaker":{}}]}]}"#.utf8)).count,
            0, "a device with no level at all should be omitted, not shown as 0%")
    }

    func testPercentParsing() {
        XCTAssertEqual(SystemUtilityService.percentValue("79%"), 79)
        XCTAssertEqual(SystemUtilityService.percentValue(" 5% "), 5)
        XCTAssertNil(SystemUtilityService.percentValue(nil))
        XCTAssertNil(SystemUtilityService.percentValue(42))
    }

    func testTheMacsOwnBatteryIsNotCalledInternalBattery0() {
        XCTAssertEqual(SystemUtilityService.friendlyName("InternalBattery-0", type: ""), "Mac")
        XCTAssertEqual(SystemUtilityService.friendlyName("Magic Trackpad", type: ""), "Magic Trackpad")
    }

    func testSymbolsFollowTheDeviceKind() {
        XCTAssertEqual(SystemUtilityService.symbol(for: "Priya’s AirPods Pro", type: ""), "airpodspro")
        XCTAssertEqual(SystemUtilityService.symbol(for: "Magic Mouse", type: ""), "magicmouse.fill")
        XCTAssertEqual(SystemUtilityService.symbol(for: "Magic Keyboard", type: ""), "keyboard.fill")
        XCTAssertEqual(SystemUtilityService.symbol(for: "Mac", type: ""), "battery.100")
    }

    func testKeepAwakePlanFormatsRemainingTimeAndExpiresAtDeadline() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let plan = KeepAwakePlan(until: now.addingTimeInterval(65 * 60))
        XCTAssertEqual(plan.remainingLabel(at: now), "1h 5m")
        XCTAssertTrue(plan.isActive(at: now.addingTimeInterval(64 * 60)))
        XCTAssertFalse(plan.isActive(at: now.addingTimeInterval(65 * 60)))
    }

    func testIndefiniteKeepAwakeDoesNotAdvertiseATimer() {
        XCTAssertNil(KeepAwakePlan(until: nil).remainingLabel(at: .now))
    }

    func testDeviceOverviewSummarizesDisplaysAndMacDetails() {
        let overview = DeviceOverview(
            modelName: "MacBook Pro",
            macOSVersion: "macOS 26.0",
            uptime: 3_661,
            displays: [
                ConnectedDisplay(name: "Built-in Retina Display", resolution: "3024 × 1964"),
                ConnectedDisplay(name: "Studio Display", resolution: "5120 × 2880")
            ])

        XCTAssertEqual(overview.uptimeLabel, "1h 1m")
        XCTAssertEqual(overview.displaySummary, "2 displays")
    }

    func testDeviceVolumeKeepsOnlyEjectableVolumes() {
        let volumes = [
            DeviceVolume(name: "Macintosh HD", url: URL(fileURLWithPath: "/"), availableBytes: 1, totalBytes: 2, isEjectable: false),
            DeviceVolume(name: "Project SSD", url: URL(fileURLWithPath: "/Volumes/Project SSD"), availableBytes: 50, totalBytes: 100, isEjectable: true)
        ]

        XCTAssertEqual(SystemUtilityService.ejectableVolumes(from: volumes).map(\.name), ["Project SSD"])
    }

    func testBatteryDetailsFormatsEstimatedTime() {
        XCTAssertEqual(BatteryDetails(health: nil, cycleCount: nil, maximumCapacityPercent: nil, estimatedMinutes: 125).estimatedTimeLabel, "2h 5m remaining")
        XCTAssertNil(BatteryDetails(health: nil, cycleCount: nil, maximumCapacityPercent: nil, estimatedMinutes: nil).estimatedTimeLabel)
    }

    func testHealthyBatteryRegistryStatusShowsNormal() {
        XCTAssertEqual(SystemUtilityService.batteryHealthLabel(permanentFailureStatus: 0), "Normal")
        XCTAssertEqual(SystemUtilityService.batteryHealthLabel(permanentFailureStatus: 1), "Service Recommended")
        XCTAssertNil(SystemUtilityService.batteryHealthLabel(permanentFailureStatus: nil))
    }

    func testBatteryHealthUsesTheNonEmptyPowerSourceValue() {
        XCTAssertEqual(SystemUtilityService.normalizedBatteryHealth("Good"), "Good")
        XCTAssertNil(SystemUtilityService.normalizedBatteryHealth(""))
        XCTAssertNil(SystemUtilityService.normalizedBatteryHealth("  \n"))
    }

    func testHardwareOverviewUsesTheFriendlyMachineName() {
        let data = Data(#"{"SPHardwareDataType":[{"machine_model":"Mac17,9","machine_name":"MacBook Pro"}]}"#.utf8)
        XCTAssertEqual(SystemUtilityService.hardwareModelName(from: data), "MacBook Pro")
    }
}
