import XCTest
@testable import NotchCapabilities

/// The Claude Code side of the shared approval model: the hook payload decoding
/// (pure — no socket involved) and the same per-session FIFO guarantees the
/// Codex path relies on, exercised through Claude-sourced approvals.
final class ClaudeApprovalQueueTests: XCTestCase {

    // MARK: - Hook payload decoding

    /// The literal payload Claude Code 2.1.226 writes to a `PreToolUse` hook's
    /// stdin, captured from a real run.
    private let bashPayload = """
    {"session_id":"cb898565-d425-4219-85b5-bf9225c8d16d",\
    "transcript_path":"/Users/x/.claude/projects/-private-tmp-t/cb898565.jsonl",\
    "cwd":"/private/tmp/nfhooktest","prompt_id":"a7ab9ce4-1234-479d-929c-6eb5097b1412",\
    "permission_mode":"acceptEdits","hook_event_name":"PreToolUse","tool_name":"Bash",\
    "tool_input":{"command":"echo NOTCHFLOW_MARKER","description":"Echo marker string"},\
    "tool_use_id":"toolu_01L992UFK2EoCVkwXtLZiaz1"}
    """

    func testDecodesABashRequestIntoAClaudeApproval() throws {
        let request = try XCTUnwrap(ClaudeHookRequest.decode(Data(bashPayload.utf8)))

        XCTAssertEqual(request.sessionID, "cb898565-d425-4219-85b5-bf9225c8d16d")
        XCTAssertEqual(request.toolUseID, "toolu_01L992UFK2EoCVkwXtLZiaz1")
        XCTAssertEqual(request.toolName, "Bash")
        XCTAssertEqual(request.command, "echo NOTCHFLOW_MARKER")
        XCTAssertEqual(request.cwd, "/private/tmp/nfhooktest")

        let approval = request.approval()
        // session_id is the queue key (Codex's threadId), tool_use_id the id the
        // decision routes back on, and the command itself is the card's title —
        // verbatim, because that is exactly what is being authorized.
        XCTAssertEqual(approval.threadID, "cb898565-d425-4219-85b5-bf9225c8d16d")
        XCTAssertEqual(approval.id, "toolu_01L992UFK2EoCVkwXtLZiaz1")
        XCTAssertEqual(approval.title, "echo NOTCHFLOW_MARKER")
        XCTAssertEqual(approval.detail, "Echo marker string")
        XCTAssertEqual(approval.workingDirectory, "/private/tmp/nfhooktest")
        XCTAssertEqual(approval.source, .claude)
    }

    func testDecodesCamelCaseClaudeSessionID() throws {
        let payload = Data("""
        {"sessionId":"claude-session","hook_event_name":"PreToolUse","tool_name":"Bash","tool_use_id":"tool-1"}
        """.utf8)

        XCTAssertEqual(try XCTUnwrap(ClaudeHookRequest.decode(payload)).sessionID, "claude-session")
    }

    func testSubagentTranscriptGroupsItsApprovalUnderTheRootSession() throws {
        let payload = """
        {"session_id":"agent-child","transcript_path":"/Users/x/.claude/projects/demo/root-session/subagents/agent-child.jsonl",\
        "hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git status"},"tool_use_id":"toolu_child"}
        """

        let request = try XCTUnwrap(ClaudeHookRequest.decode(Data(payload.utf8)))

        XCTAssertEqual(request.rootSessionID, "root-session")
        XCTAssertEqual(request.approval().sessionGroupID, "root-session")
    }

    func testDecodesAWriteRequestNamingTheFile() throws {
        let payload = """
        {"session_id":"s1","hook_event_name":"PreToolUse","tool_name":"Write",\
        "cwd":"/private/tmp/nfhooktest",\
        "tool_input":{"file_path":"/tmp/nfhooktest/x.txt","content":"hi\\n"},\
        "tool_use_id":"toolu_013gMjB1zs3X5HSBGrJpTiA8"}
        """
        let request = try XCTUnwrap(ClaudeHookRequest.decode(Data(payload.utf8)))
        XCTAssertEqual(request.filePath, "/tmp/nfhooktest/x.txt")

        let approval = request.approval()
        XCTAssertEqual(approval.title, "Write x.txt")
        // The full path is the detail line: the file's name alone is not enough
        // to decide whether an edit is safe.
        XCTAssertEqual(approval.detail, "/tmp/nfhooktest/x.txt")
    }

    func testDecodesANotebookEditByItsNotebookPath() throws {
        let payload = """
        {"session_id":"s1","hook_event_name":"PreToolUse","tool_name":"NotebookEdit",\
        "tool_input":{"notebook_path":"/tmp/work/Analysis.ipynb","new_source":"1+1"},\
        "tool_use_id":"toolu_9"}
        """
        let request = try XCTUnwrap(ClaudeHookRequest.decode(Data(payload.utf8)))
        XCTAssertEqual(request.filePath, "/tmp/work/Analysis.ipynb")
        XCTAssertEqual(request.approval().title, "Edit notebook Analysis.ipynb")
    }

    func testAMultiLineCommandStaysOnOneLine() throws {
        let payload = """
        {"session_id":"s1","hook_event_name":"PreToolUse","tool_name":"Bash",\
        "tool_input":{"command":"cd /tmp   &&\\n  rm -rf build"},"tool_use_id":"toolu_9"}
        """
        let request = try XCTUnwrap(ClaudeHookRequest.decode(Data(payload.utf8)))
        XCTAssertEqual(request.approval().title, "cd /tmp && rm -rf build")
        // No description and no cwd in this payload — the card shows no sub-line
        // rather than inventing one.
        XCTAssertNil(request.approval().detail)
    }

    func testRejectsPayloadsThatCannotBeQueuedOrAnswered() {
        // No session_id: nothing to key a queue on.
        XCTAssertNil(ClaudeHookRequest.decode(Data("""
        {"hook_event_name":"PreToolUse","tool_name":"Bash","tool_use_id":"t1"}
        """.utf8)))
        // No tool_use_id: nothing to route a decision back to.
        XCTAssertNil(ClaudeHookRequest.decode(Data("""
        {"session_id":"s1","hook_event_name":"PreToolUse","tool_name":"Bash"}
        """.utf8)))
        // A different hook event is a misconfiguration; a permission decision
        // would be a nonsense answer to it.
        XCTAssertNil(ClaudeHookRequest.decode(Data("""
        {"session_id":"s1","hook_event_name":"PostToolUse","tool_name":"Bash","tool_use_id":"t1"}
        """.utf8)))
        XCTAssertNil(ClaudeHookRequest.decode(Data("not json".utf8)))
    }

    // MARK: - The decision written back to the hook

    func testDecisionLineMatchesTheHookContract() throws {
        for (decision, expected) in [(ClaudeHookDecision.allow, "allow"),
                                     (ClaudeHookDecision.deny, "deny")] {
            let line = ClaudeHookResponse.line(decision, reason: "because")
            XCTAssertFalse(line.contains("\n"), "the hook reads exactly one line")
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            let specific = try XCTUnwrap(object["hookSpecificOutput"] as? [String: Any])
            XCTAssertEqual(specific["hookEventName"] as? String, "PreToolUse")
            XCTAssertEqual(specific["permissionDecision"] as? String, expected)
            XCTAssertEqual(specific["permissionDecisionReason"] as? String, "because")
        }
    }

    func testDefaultReasonsNameTheUserAsTheDecider() {
        XCTAssertTrue(ClaudeHookResponse.line(for: .deny).contains("NotchFlow"))
        XCTAssertTrue(ClaudeHookResponse.line(for: .allow).contains("NotchFlow"))
    }

    // MARK: - Queue behaviour, Claude side

    private func claudeApproval(_ id: String, session: String, title: String) -> AgentApproval {
        AgentApproval(id: id, threadID: session, itemID: id, title: title, source: .claude)
    }

    func testEachClaudeSessionKeepsItsOwnFIFOOrder() {
        var queue = AgentApprovalQueue()
        queue.enqueue(claudeApproval("a1", session: "sess-a", title: "npm test"))
        queue.enqueue(claudeApproval("b1", session: "sess-b", title: "rm -rf build"))
        queue.enqueue(claudeApproval("a2", session: "sess-a", title: "git commit"))
        queue.enqueue(claudeApproval("a3", session: "sess-a", title: "git push"))

        XCTAssertEqual(queue.sessionQueues.map(\.threadID), ["sess-a", "sess-b"])
        XCTAssertEqual(queue.sessionQueues[0].approvals.map(\.title),
                       ["npm test", "git commit", "git push"])
        XCTAssertEqual(queue.sessionQueues[0].current.title, "npm test")
        XCTAssertEqual(queue.sessionQueues[1].pendingCount, 1)
    }

    func testResolvingOneClaudeSessionDoesNotAdvanceAnother() {
        var queue = AgentApprovalQueue()
        queue.enqueue(claudeApproval("a1", session: "sess-a", title: "npm test"))
        queue.enqueue(claudeApproval("b1", session: "sess-b", title: "rm -rf build"))
        queue.enqueue(claudeApproval("a2", session: "sess-a", title: "git commit"))

        queue.resolve(id: "a1")

        XCTAssertEqual(queue.sessionQueues.map(\.threadID), ["sess-a", "sess-b"])
        XCTAssertEqual(queue.sessionQueues[0].current.title, "git commit")
        XCTAssertEqual(queue.sessionQueues[0].pendingCount, 1)
        // sess-b is untouched — its head is still the request nobody answered.
        XCTAssertEqual(queue.sessionQueues[1].current.title, "rm -rf build")
        XCTAssertEqual(queue.sessionQueues[1].pendingCount, 1)
    }

    func testAnEmptiedSessionLeavesTheQueueEntirely() {
        var queue = AgentApprovalQueue()
        queue.enqueue(claudeApproval("a1", session: "sess-a", title: "npm test"))
        queue.enqueue(claudeApproval("b1", session: "sess-b", title: "rm -rf build"))

        queue.resolve(id: "a1")

        XCTAssertEqual(queue.sessionQueues.map(\.threadID), ["sess-b"])
        XCTAssertFalse(queue.contains(id: "a1"))
    }

    func testTheSameToolUseIDIsNeverQueuedTwice() {
        var queue = AgentApprovalQueue()
        queue.enqueue(claudeApproval("toolu_1", session: "sess-a", title: "npm test"))
        queue.enqueue(claudeApproval("toolu_1", session: "sess-a", title: "npm test"))
        // …not even when a second session claims the same id.
        queue.enqueue(claudeApproval("toolu_1", session: "sess-b", title: "npm test"))

        XCTAssertEqual(queue.sessionQueues.count, 1)
        XCTAssertEqual(queue.sessionQueues[0].pendingCount, 1)
    }

    /// A repeat id would be dropped by the dedupe above, which for a hook means a
    /// process parked until its timeout. `approval(idOverride:)` is how the bridge
    /// keeps that request answerable.
    func testAnOverriddenIDStillCarriesTheOriginalToolUseID() throws {
        let request = try XCTUnwrap(ClaudeHookRequest.decode(Data(bashPayload.utf8)))
        let approval = request.approval(idOverride: "toolu_01L992UFK2EoCVkwXtLZiaz1#2")

        XCTAssertEqual(approval.id, "toolu_01L992UFK2EoCVkwXtLZiaz1#2")
        XCTAssertEqual(approval.itemID, "toolu_01L992UFK2EoCVkwXtLZiaz1")
    }

    // MARK: - Both agents share one queue type

    func testCodexAndClaudeApprovalsCoexistWithoutInterfering() {
        var queue = AgentApprovalQueue()
        queue.enqueue(AgentApproval(id: "1", threadID: "codex-thread", itemID: "i",
                                    title: "mkdir first", source: .codex))
        queue.enqueue(claudeApproval("toolu_1", session: "claude-session", title: "npm test"))

        XCTAssertEqual(queue.sessionQueues.map(\.threadID), ["codex-thread", "claude-session"])
        XCTAssertEqual(queue.sessionQueues[0].current.source.displayName, "Codex")
        XCTAssertEqual(queue.sessionQueues[1].current.source.displayName, "Claude")

        queue.resolve(id: "1")
        XCTAssertEqual(queue.sessionQueues.map(\.threadID), ["claude-session"])
    }
}
