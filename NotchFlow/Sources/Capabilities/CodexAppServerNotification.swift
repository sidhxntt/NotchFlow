import Foundation

/// A notification emitted by Codex's JSON-RPC app server.
///
/// Notifications intentionally have no JSON-RPC `id`; approvals are requests
/// and therefore do. Keeping the distinction explicit prevents a request-id
/// guard from accidentally dropping task progress and completion updates.
public struct CodexAppServerNotification: Equatable, Sendable {
    public let method: String
    public let threadID: String?
    public let delta: String?
    public let turnStatus: String?

    public static func decode(_ data: Data) -> CodexAppServerNotification? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return decode(object)
    }

    public static func decode(_ object: [String: Any]) -> CodexAppServerNotification? {
        guard object["id"] == nil,
              let method = object["method"] as? String,
              let params = object["params"] as? [String: Any]
        else { return nil }

        let threadID = params["threadId"] as? String
        let delta = params["delta"] as? String
        let turnStatus = (params["turn"] as? [String: Any])?["status"] as? String
        return CodexAppServerNotification(method: method, threadID: threadID,
                                          delta: delta, turnStatus: turnStatus)
    }
}
