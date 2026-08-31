import XCTest
@testable import NotchCapabilities

final class CodexApprovalQueueTests: XCTestCase {
    func testLegacyCodexHookPayloadBecomesADirectCodexApproval() throws {
        let payload = Data("""
        {"v":1,"source":"codex","session_id":"terminal-session","cwd":"/tmp/project","tool_name":"Bash","detail":"git push origin main","reason":"Publish the branch","escalated":true,"action":"gate"}
        """.utf8)

        let request = try XCTUnwrap(CodexTerminalHookRequest.decode(payload))
        XCTAssertEqual(request.approval.threadID, "terminal-session")
        XCTAssertEqual(request.approval.title, "git push origin main")
        XCTAssertEqual(request.approval.detail, "Publish the branch")
        XCTAssertEqual(request.approval.workingDirectory, "/tmp/project")
        XCTAssertEqual(request.approval.source, .codex)
        XCTAssertEqual(CodexTerminalHookResponse.line(for: .approve), "{\"behavior\":\"allow\"}")
        XCTAssertTrue(CodexTerminalHookResponse.line(for: .deny).contains("\"behavior\":\"deny\""))
    }

    func testTerminalHookAcceptsThreadIDWhenSessionIDIsAbsent() throws {
        let payload = Data("""
        {"source":"codex","action":"gate","thread_id":"terminal-thread","tool_name":"exec_command"}
        """.utf8)

        XCTAssertEqual(try XCTUnwrap(CodexTerminalHookRequest.decode(payload)).approval.threadID, "terminal-thread")
    }

    func testNotificationDecodesWithoutARequestID() {
        let payload = Data("""
        {"jsonrpc":"2.0","method":"turn/completed","params":{"threadId":"thread-1","turn":{"status":"completed"}}}
        """.utf8)

        let notification = CodexAppServerNotification.decode(payload)

        XCTAssertEqual(notification?.method, "turn/completed")
        XCTAssertEqual(notification?.threadID, "thread-1")
        XCTAssertEqual(notification?.turnStatus, "completed")
    }

    func testResolvingOneSessionLeavesTheOtherSessionAndAdvancesItsOwnQueue() {
        var queue = CodexApprovalQueue()
        queue.enqueue(CodexApproval(id: "one-a", threadID: "one", itemID: "item-a", title: "mkdir first"))
        queue.enqueue(CodexApproval(id: "two-a", threadID: "two", itemID: "item-b", title: "touch second"))
        queue.enqueue(CodexApproval(id: "one-b", threadID: "one", itemID: "item-c", title: "git status"))

        XCTAssertEqual(queue.sessionQueues.map(\.threadID), ["one", "two"])
        XCTAssertEqual(queue.sessionQueues[0].current.title, "mkdir first")
        XCTAssertEqual(queue.sessionQueues[0].pendingCount, 2)

        queue.resolve(id: "one-a")

        XCTAssertEqual(queue.sessionQueues.map(\.threadID), ["one", "two"])
        XCTAssertEqual(queue.sessionQueues[0].current.title, "git status")
        XCTAssertEqual(queue.sessionQueues[0].pendingCount, 1)
        XCTAssertEqual(queue.sessionQueues[1].current.title, "touch second")
        XCTAssertEqual(queue.sessionQueues[1].pendingCount, 1)
    }

    func testSessionQueueBuildsCompactMetadataForAnApprovalRow() {
        let queue = AgentApprovalSessionQueue(threadID: "session-1", approvals: [
            AgentApproval(id: "request-1", threadID: "session-1", itemID: "item-1",
                          title: "git push", detail: "Publish the branch",
                          workingDirectory: "/work/AgentNotch", source: .codex),
            AgentApproval(id: "request-2", threadID: "session-1", itemID: "item-2",
                          title: "git status", source: .codex)
        ])

        XCTAssertEqual(queue.compactMetadataLabel, "AgentNotch · 2 queued")
    }

    func testChildApprovalsAppearInTheirRootSessionsSingleFIFOQueue() {
        var queue = CodexApprovalQueue()
        queue.enqueue(CodexApproval(id: "root-a", threadID: "root", itemID: "root-a",
                                    title: "root command", sessionGroupID: "root"))
        queue.enqueue(CodexApproval(id: "child-a", threadID: "child-a", itemID: "child-a",
                                    title: "child command", sessionGroupID: "root"))
        queue.enqueue(CodexApproval(id: "child-b", threadID: "child-b", itemID: "child-b",
                                    title: "second child command", sessionGroupID: "root"))

        XCTAssertEqual(queue.sessionQueues.map(\.threadID), ["root"])
        XCTAssertEqual(queue.sessionQueues[0].approvals.map(\.id), ["root-a", "child-a", "child-b"])
        XCTAssertEqual(queue.sessionQueues[0].approvals.map(\.threadID), ["root", "child-a", "child-b"])
    }

    func testRegroupingLateDiscoveredChildrenPreservesArrivalOrderAndTheirCallbackIDs() {
        var queue = CodexApprovalQueue()
        queue.enqueue(CodexApproval(id: "child-a-1", threadID: "child-a", itemID: "item-a-1", title: "first"))
        queue.enqueue(CodexApproval(id: "child-b-1", threadID: "child-b", itemID: "item-b-1", title: "second"))
        queue.enqueue(CodexApproval(id: "child-a-2", threadID: "child-a", itemID: "item-a-2", title: "third"))

        let hierarchy = CodexSessionHierarchy(parentBySessionID: [
            "child-a": "root", "child-b": "root"
        ])
        queue.regroup(using: hierarchy)

        XCTAssertEqual(queue.sessionQueues.map(\.threadID), ["root"])
        XCTAssertEqual(queue.sessionQueues[0].approvals.map(\.id), ["child-a-1", "child-b-1", "child-a-2"])
        XCTAssertEqual(queue.sessionQueues[0].approvals.map(\.threadID), ["child-a", "child-b", "child-a"])

        queue.resolve(id: "child-b-1")
        XCTAssertEqual(queue.sessionQueues[0].approvals.map(\.id), ["child-a-1", "child-a-2"])
    }

    func testHierarchyResolvesNestedChildrenAndRejectsCycles() {
        let hierarchy = CodexSessionHierarchy(parentBySessionID: [
            "child": "root", "grandchild": "child",
            "cycle-a": "cycle-b", "cycle-b": "cycle-a"
        ])

        XCTAssertEqual(hierarchy.rootSessionID(for: "root"), "root")
        XCTAssertEqual(hierarchy.rootSessionID(for: "child"), "root")
        XCTAssertEqual(hierarchy.rootSessionID(for: "grandchild"), "root")
        XCTAssertEqual(hierarchy.subagentCount(for: "root"), 2)
        XCTAssertEqual(hierarchy.rootSessionID(for: "cycle-a"), "cycle-a")
        XCTAssertEqual(hierarchy.rootSessionID(for: "unknown"), "unknown")
    }

    func testHierarchyRetainsKnownLinksWhenALaterScanIsIncomplete() {
        let initial = CodexSessionHierarchy(parentBySessionID: ["child": "root"])
        let merged = initial.merging(CodexSessionHierarchy())

        XCTAssertEqual(merged.rootSessionID(for: "child"), "root")
    }
}
