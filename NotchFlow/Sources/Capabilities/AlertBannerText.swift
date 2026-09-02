import Foundation

/// Which of a banner's static texts is the title and which is the body.
///
/// This looks like it should be positional — first line is the title, the rest
/// is the body — and that is exactly how it was written first. Against the live
/// tree it is wrong: a banner carries THREE texts, and macOS labels each of
/// them in its `AXIdentifier`.
/// A banner carries THREE texts, and macOS labels each of them in its
/// `AXIdentifier`:
///
/// ```
/// AXGroup subrole=AXNotificationCenterBanner
///   AXStaticText id="title"     "Priya"
///   AXStaticText id="subtitle"  "WhatsApp"
///   AXStaticText id="body"      "Incoming call"
/// ```
///
/// Joining everything after the title produces a body such as `"WhatsApp
/// Incoming call"` — the app's own name, then the message. The posting app is
/// already identified separately, so that subtitle is metadata rather than
/// message content.
///
/// So the split reads the identifiers macOS publishes, and only falls back to
/// position when a future release stops publishing them. The line macOS calls
/// `subtitle` is deliberately dropped: it is the posting app naming itself,
/// which the store already learns from the group's description.
public enum AlertBannerText {
    /// One static text as the Accessibility tree gave it to us: what macOS calls
    /// it, and what it says.
    public struct Node: Equatable, Sendable {
        public let identifier: String?
        public let value: String

        public init(identifier: String?, value: String) {
            self.identifier = identifier
            self.value = value
        }
    }

    /// The caller-shaped first line and the message, out of a banner's texts.
    public static func split(_ nodes: [Node]) -> (title: String, body: String) {
        // A recognised subtitle is metadata owned by the posting app, never
        // either user-facing field. Excluding it before either positional
        // fallback matters when macOS keeps one identifier but renames the
        // other: otherwise an unnamed body becomes "WhatsApp Incoming call".
        let contentValues = nodes
            .filter { $0.identifier != "subtitle" }
            .map(\.value)
            .filter { !$0.isEmpty }

        // "title" and "body" are not in any SDK header — they were read off the
        // live tree — so each is resolved independently and each has its own
        // positional fallback. A release that renames one must not take the
        // other down with it.
        let title = value(of: "title", in: nodes) ?? contentValues.first ?? ""
        let body = value(of: "body", in: nodes)
            ?? contentValues.filter { $0 != title }.joined(separator: " ")

        return (title, body)
    }

    private static func value(of identifier: String, in nodes: [Node]) -> String? {
        nodes.first { $0.identifier == identifier && !$0.value.isEmpty }?.value
    }
}
