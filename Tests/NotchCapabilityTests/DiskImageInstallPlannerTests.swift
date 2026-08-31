import XCTest
@testable import NotchCapabilities

final class DiskImageInstallPlannerTests: XCTestCase {
    func testSingleAppProducesAnInstallPlan() {
        let app = URL(fileURLWithPath: "/Volumes/Test/Example.app")
        let plan = DiskImageInstallPlanner.plan(mountedItems: [app])
        XCTAssertEqual(plan?.source, app)
        XCTAssertEqual(plan?.destination.path, "/Applications/Example.app")
        XCTAssertTrue(plan?.requiresConfirmation == true)
    }

    func testMultipleAppsOrNoAppsProduceNoPlan() {
        XCTAssertNil(DiskImageInstallPlanner.plan(mountedItems: []))
        XCTAssertNil(DiskImageInstallPlanner.plan(mountedItems: [
            URL(fileURLWithPath: "/Volumes/Test/A.app"), URL(fileURLWithPath: "/Volumes/Test/B.app")
        ]))
    }
}
