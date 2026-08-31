import XCTest
@testable import NotchCapabilities

final class SystemMonitorServiceTests: XCTestCase {

    // MARK: - cpuPercent

    func testCPUPercentAllIdle() {
        let percent = SystemMonitorService.cpuPercent(
            user1: 0, system1: 0, idle1: 0, nice1: 0,
            user2: 0, system2: 0, idle2: 100, nice2: 0)
        XCTAssertEqual(percent, 0)
    }

    func testCPUPercentAllBusy() {
        let percent = SystemMonitorService.cpuPercent(
            user1: 0, system1: 0, idle1: 0, nice1: 0,
            user2: 100, system2: 0, idle2: 0, nice2: 0)
        XCTAssertEqual(percent, 100)
    }

    func testCPUPercentMixedTicks() {
        // 30 user + 10 system + 0 nice busy against 60 idle, over a 100-tick
        // window — the shape a real diff between two samples takes.
        let percent = SystemMonitorService.cpuPercent(
            user1: 1_000, system1: 500, idle1: 2_000, nice1: 0,
            user2: 1_030, system2: 510, idle2: 2_060, nice2: 0)
        XCTAssertEqual(percent, 40, accuracy: 0.001)
    }

    func testCPUPercentNoElapsedTicksReturnsZero() {
        // Two samples taken back-to-back with no time between them — nothing
        // to divide by, and the function should not divide by zero.
        let percent = SystemMonitorService.cpuPercent(
            user1: 10, system1: 10, idle1: 10, nice1: 10,
            user2: 10, system2: 10, idle2: 10, nice2: 10)
        XCTAssertEqual(percent, 0)
    }

    func testCPUPercentClampsToValidRange() {
        // A counter that appears to have gone backwards (e.g. wrapped) should
        // not produce a percentage outside 0...100.
        let percent = SystemMonitorService.cpuPercent(
            user1: 500, system1: 0, idle1: 0, nice1: 0,
            user2: 100, system2: 0, idle2: 0, nice2: 0)
        XCTAssertGreaterThanOrEqual(percent, 0)
        XCTAssertLessThanOrEqual(percent, 100)
    }

    // MARK: - usedPercent

    func testUsedPercentHalf() {
        XCTAssertEqual(SystemMonitorService.usedPercent(used: 50, total: 100), 50)
    }

    func testUsedPercentZeroTotalIsNil() {
        XCTAssertNil(SystemMonitorService.usedPercent(used: 10, total: 0))
    }

    func testUsedPercentFull() {
        XCTAssertEqual(SystemMonitorService.usedPercent(used: 100, total: 100), 100)
    }

    // MARK: - cpuBreakdown

    func testCPUBreakdownSplitsSystemUserIdle() {
        // 30 user + 10 system busy against 60 idle — the same window
        // `testCPUPercentMixedTicks` measures, now split three ways.
        let breakdown = SystemMonitorService.cpuBreakdown(
            user1: 1_000, system1: 500, idle1: 2_000, nice1: 0,
            user2: 1_030, system2: 510, idle2: 2_060, nice2: 0)
        XCTAssertEqual(breakdown.user, 30, accuracy: 0.001)
        XCTAssertEqual(breakdown.system, 10, accuracy: 0.001)
        XCTAssertEqual(breakdown.idle, 60, accuracy: 0.001)
    }

    func testCPUBreakdownSumsToOneHundred() {
        let breakdown = SystemMonitorService.cpuBreakdown(
            user1: 7, system1: 3, idle1: 11, nice1: 2,
            user2: 40, system2: 21, idle2: 96, nice2: 9)
        XCTAssertEqual(breakdown.system + breakdown.user + breakdown.idle, 100, accuracy: 0.001)
    }

    func testCPUBreakdownFoldsNiceIntoUser() {
        // 20 user + 20 nice is 40% user-space work, not two separate series.
        let breakdown = SystemMonitorService.cpuBreakdown(
            user1: 0, system1: 0, idle1: 0, nice1: 0,
            user2: 20, system2: 0, idle2: 60, nice2: 20)
        XCTAssertEqual(breakdown.user, 40, accuracy: 0.001)
        XCTAssertEqual(breakdown.system, 0, accuracy: 0.001)
        XCTAssertEqual(breakdown.idle, 60, accuracy: 0.001)
    }

    func testCPUBreakdownNoElapsedTicksReadsAsIdle() {
        let breakdown = SystemMonitorService.cpuBreakdown(
            user1: 10, system1: 10, idle1: 10, nice1: 10,
            user2: 10, system2: 10, idle2: 10, nice2: 10)
        XCTAssertEqual(breakdown.system, 0)
        XCTAssertEqual(breakdown.user, 0)
        XCTAssertEqual(breakdown.idle, 100)
    }

    func testCPUBreakdownIgnoresBackwardsCounters() {
        // A counter that appears to have wrapped must not produce a negative
        // share, and must not drag the other shares past 100.
        let breakdown = SystemMonitorService.cpuBreakdown(
            user1: 500, system1: 0, idle1: 0, nice1: 0,
            user2: 100, system2: 50, idle2: 50, nice2: 0)
        XCTAssertGreaterThanOrEqual(breakdown.user, 0)
        XCTAssertEqual(breakdown.system, 50, accuracy: 0.001)
        XCTAssertEqual(breakdown.idle, 50, accuracy: 0.001)
    }

    func testCPUBreakdownBusyMatchesCPUPercent() {
        // The one-number readout and the three-way split are the same maths;
        // if these ever disagree one of them is lying to the card.
        let breakdown = SystemMonitorService.cpuBreakdown(
            user1: 1_000, system1: 500, idle1: 2_000, nice1: 5,
            user2: 1_030, system2: 510, idle2: 2_060, nice2: 15)
        let percent = SystemMonitorService.cpuPercent(
            user1: 1_000, system1: 500, idle1: 2_000, nice1: 5,
            user2: 1_030, system2: 510, idle2: 2_060, nice2: 15)
        XCTAssertEqual(breakdown.busy, percent, accuracy: 0.001)
    }

    // MARK: - gigabytesString

    func testGigabytesStringFormatsOneDecimalPlace() {
        XCTAssertEqual(SystemMonitorService.gigabytesString(16_106_127_360), "15.0 GB")
    }

    func testGigabytesStringZero() {
        XCTAssertEqual(SystemMonitorService.gigabytesString(0), "0.0 GB")
    }

    // MARK: - byteString

    func testByteStringZeroIsSpelledOut() {
        // "0.0 GB" would read as a rounded-down number; swap on a healthy
        // machine is genuinely nothing, and should say so.
        XCTAssertEqual(SystemMonitorService.byteString(0), "0 bytes")
    }

    func testByteStringKilobytes() {
        XCTAssertEqual(SystemMonitorService.byteString(512 * 1_024), "512 KB")
    }

    func testByteStringMegabytes() {
        XCTAssertEqual(SystemMonitorService.byteString(5 * 1_024 * 1_024), "5 MB")
    }

    func testByteStringGigabytesUsesTwoDecimals() {
        XCTAssertEqual(SystemMonitorService.byteString(24 * 1_073_741_824), "24.00 GB")
    }

    func testByteStringGigabytesKeepsSecondDecimal() {
        // 16.06 GB and 16.60 GB must not collapse into the same string.
        let sixteenPointOhSix = UInt64(16.06 * 1_073_741_824)
        XCTAssertEqual(SystemMonitorService.byteString(sixteenPointOhSix), "16.06 GB")
    }

    // MARK: - appending (rolling history buffer)

    func testAppendingUnderLimitKeepsEverything() {
        let history = SystemMonitorService.appending(3.0, to: [1.0, 2.0], limit: 5)
        XCTAssertEqual(history, [1.0, 2.0, 3.0])
    }

    func testAppendingAtLimitEvictsOldest() {
        let history = SystemMonitorService.appending(4.0, to: [1.0, 2.0, 3.0], limit: 3)
        XCTAssertEqual(history, [2.0, 3.0, 4.0])
    }

    func testAppendingNeverGrowsPastLimit() {
        var history: [Int] = []
        for sample in 0..<200 {
            history = SystemMonitorService.appending(sample, to: history, limit: 40)
            XCTAssertLessThanOrEqual(history.count, 40)
        }
        XCTAssertEqual(history.count, 40)
        XCTAssertEqual(history.last, 199)
        XCTAssertEqual(history.first, 160)
    }

    func testAppendingTrimsAnAlreadyOversizedHistory() {
        let history = SystemMonitorService.appending(9.0, to: [1.0, 2.0, 3.0, 4.0, 5.0], limit: 2)
        XCTAssertEqual(history, [5.0, 9.0])
    }

    func testAppendingWithNonPositiveLimitKeepsNothing() {
        XCTAssertTrue(SystemMonitorService.appending(1.0, to: [1.0, 2.0], limit: 0).isEmpty)
    }

    func testAppendingCarriesBreakdownSamples() {
        let sample = CPUBreakdown(system: 3, user: 5, idle: 92)
        let history = SystemMonitorService.appending(sample, to: [], limit: 40)
        XCTAssertEqual(history, [sample])
    }

    // MARK: - memoryPressureProxyPercent

    func testMemoryPressureProxyIsShareOfUnreclaimableMemory() {
        // 2 GB wired + 1 GB compressed out of 24 GB physical = 12.5%.
        let proxy = SystemMonitorService.memoryPressureProxyPercent(
            wiredBytes: 2 * 1_073_741_824,
            compressedBytes: 1_073_741_824,
            physicalBytes: 24 * 1_073_741_824)
        XCTAssertEqual(proxy ?? -1, 12.5, accuracy: 0.001)
    }

    func testMemoryPressureProxyZeroPhysicalIsNil() {
        XCTAssertNil(SystemMonitorService.memoryPressureProxyPercent(
            wiredBytes: 1, compressedBytes: 1, physicalBytes: 0))
    }

    func testMemoryPressureProxyClampsToOneHundred() {
        let proxy = SystemMonitorService.memoryPressureProxyPercent(
            wiredBytes: 32 * 1_073_741_824,
            compressedBytes: 32 * 1_073_741_824,
            physicalBytes: 24 * 1_073_741_824)
        XCTAssertEqual(proxy ?? -1, 100, accuracy: 0.001)
    }

    // MARK: - memory-pressure presentation

    func testMemoryPressureGraphToneMatchesTheKernelState() {
        XCTAssertEqual(MemoryPressureLevel.normal.graphTone, .normal)
        XCTAssertEqual(MemoryPressureLevel.warning.graphTone, .warning)
        XCTAssertEqual(MemoryPressureLevel.critical.graphTone, .critical)
        XCTAssertEqual(MemoryPressureLevel.unknown.graphTone, .unknown)
    }
}
