import XCTest
@testable import NotchCapabilities

final class ClaudePermissionRequestTests: XCTestCase {
    private func decode(_ json: String) -> ClaudeHookRequest? {
        ClaudeHookRequest.decode(Data(json.utf8))
    }

    func testDecodesPermissionRequestWithoutToolUseID() throws {
        let request = try XCTUnwrap(decode("""
        {"session_id":"term-1","cwd":"/Users/me/app","hook_event_name":"PermissionRequest",
         "tool_name":"Bash","tool_input":{"command":"npm install"}}
        """))
        XCTAssertEqual(request.event, .permissionRequest)
        XCTAssertEqual(request.sessionID, "term-1")
        XCTAssertTrue(request.toolUseID.hasPrefix("permission-"))
        XCTAssertEqual(request.title, "npm install")
    }

    func testTwoPermissionRequestsWithoutIDsGetDistinctIDs() throws {
        let json = #"{"session_id":"s","hook_event_name":"PermissionRequest","tool_name":"Bash"}"#
        let first = try XCTUnwrap(decode(json))
        let second = try XCTUnwrap(decode(json))
        XCTAssertNotEqual(first.toolUseID, second.toolUseID)
    }

    func testMissingEventNameStillMeansPreToolUse() throws {
        let request = try XCTUnwrap(decode(#"{"session_id":"s","tool_name":"Bash","tool_use_id":"t"}"#))
        XCTAssertEqual(request.event, .preToolUse)
    }

    func testMCPToolTitleNamesServerAndAction() throws {
        let request = try XCTUnwrap(decode("""
        {"session_id":"s","hook_event_name":"PermissionRequest","tool_name":"mcp__computer-use__left_click"}
        """))
        XCTAssertEqual(request.title, "computer-use: left click")
    }

    func testPermissionRequestAnswerShape() throws {
        func object(_ line: String) throws -> [String: Any] {
            let parsed = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            return try XCTUnwrap(parsed?["hookSpecificOutput"] as? [String: Any])
        }
        let allow = try object(ClaudeHookResponse.line(for: .allow, event: .permissionRequest))
        XCTAssertEqual(allow["hookEventName"] as? String, "PermissionRequest")
        XCTAssertEqual((allow["decision"] as? [String: Any])?["behavior"] as? String, "allow")

        let deny = try object(ClaudeHookResponse.line(for: .deny, event: .permissionRequest))
        let verdict = try XCTUnwrap(deny["decision"] as? [String: Any])
        XCTAssertEqual(verdict["behavior"] as? String, "deny")
        XCTAssertNotNil(verdict["message"] as? String)

        // PreToolUse keeps its original contract.
        let pre = try object(ClaudeHookResponse.line(for: .allow, event: .preToolUse))
        XCTAssertEqual(pre["permissionDecision"] as? String, "allow")
    }
}
