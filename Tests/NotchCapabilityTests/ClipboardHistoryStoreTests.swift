import XCTest
@testable import NotchCapabilities

final class ClipboardHistoryStoreTests: XCTestCase {
    func testAddingARepeatedItemPromotesInsteadOfDuplicatingIt() {
        var store = ClipboardHistoryStore(limit: 3)
        store.record(.text("first"), sourceBundleID: "com.example.one", at: Date(timeIntervalSince1970: 1))
        store.record(.text("second"), sourceBundleID: "com.example.two", at: Date(timeIntervalSince1970: 2))
        store.record(.text("first"), sourceBundleID: "com.example.one", at: Date(timeIntervalSince1970: 3))

        XCTAssertEqual(store.items.map(\.content), [.text("first"), .text("second")])
        XCTAssertEqual(store.items.first?.capturedAt, Date(timeIntervalSince1970: 3))
    }

    func testPinnedItemsSurviveTheCapacityEviction() {
        var store = ClipboardHistoryStore(limit: 2)
        store.record(.text("pinned"), at: .distantPast)
        store.setPinned(true, id: store.items[0].id)
        store.record(.text("two"), at: Date(timeIntervalSince1970: 2))
        store.record(.text("three"), at: Date(timeIntervalSince1970: 3))

        XCTAssertEqual(store.items.map(\.content), [.text("three"), .text("pinned")])
    }

    func testIgnoredSourceAndEmptyTextAreNeverRecorded() {
        var store = ClipboardHistoryStore(limit: 10, ignoredBundleIDs: ["com.private.app"])
        store.record(.text("secret"), sourceBundleID: "com.private.app")
        store.record(.text("   "), sourceBundleID: "com.example")
        XCTAssertTrue(store.items.isEmpty)
    }

    func testSearchFindsTextAndFileNamesCaseInsensitively() {
        var store = ClipboardHistoryStore(limit: 10)
        store.record(.text("Ship the release notes"))
        store.record(.file(URL(fileURLWithPath: "/tmp/Quarterly Report.pdf")))
        XCTAssertEqual(store.search("RELEASE").count, 1)
        XCTAssertEqual(store.search("report").count, 1)
    }

    func testAutoClearPolicySeparatesSystemClipboardFromSavedHistory() {
        let policy = ClipboardAutoClearPolicy(after: 60, clearOnSleep: true, clearOnLock: false)
        XCTAssertTrue(policy.shouldClear(for: .elapsed(seconds: 60)))
        XCTAssertTrue(policy.shouldClear(for: .sleep))
        XCTAssertFalse(policy.shouldClear(for: .lock))
    }
}
