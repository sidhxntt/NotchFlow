import Foundation

/// The video call hiding inside a calendar event.
///
/// Every conferencing service puts its join link somewhere different — Zoom in
/// the location field, Meet in the event URL, Teams buried in a paragraph of
/// HTML boilerplate — so finding it means looking in all three places and
/// recognising the shape when it turns up.
public struct MeetingLink: Equatable, Sendable {
    public enum Service: String, Equatable, Sendable {
        case zoom, meet, teams, webex, facetime, generic

        /// What the chip says. Short enough for a notch: the service name is the
        /// useful half, "Join" is the verb.
        public var displayName: String {
            switch self {
            case .zoom:     return "Zoom"
            case .meet:     return "Meet"
            case .teams:    return "Teams"
            case .webex:    return "Webex"
            case .facetime: return "FaceTime"
            case .generic:  return "Call"
            }
        }

        public var symbolName: String {
            self == .facetime ? "video.fill" : "video.fill"
        }
    }

    public let url: URL
    public let service: Service

    public init(url: URL, service: Service) {
        self.url = url
        self.service = service
    }

    /// Find the join link in an event's three plausible hiding places, in the
    /// order they're most likely to be authoritative: the dedicated URL field
    /// first, then location (where Zoom and Webex put it), then the notes.
    ///
    /// Notes are searched last and are the messiest — a Teams invitation is a
    /// wall of HTML with several links in it, only one of which joins the call.
    public static func detect(url: String?, location: String?, notes: String?) -> MeetingLink? {
        for candidate in [url, location, notes] {
            guard let candidate, !candidate.isEmpty else { continue }
            if let found = firstLink(in: candidate) { return found }
        }
        return nil
    }

    /// Scan text for the first URL that is recognisably a meeting.
    ///
    /// `NSDataDetector` rather than a URL regex: it already handles the ways
    /// links appear in calendar text — bare, angle-bracketed, wrapped across
    /// lines, percent-encoded — and getting that right by hand is a losing game.
    static func firstLink(in text: String) -> MeetingLink? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return nil }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var fallback: MeetingLink?

        for match in detector.matches(in: text, options: [], range: range) {
            guard let url = match.url else { continue }
            guard let service = service(for: url) else { continue }
            // A known service wins outright; a bare "join"-shaped link is only
            // used if nothing better turns up in the rest of the text.
            if service == .generic {
                if fallback == nil { fallback = MeetingLink(url: url, service: .generic) }
                continue
            }
            return MeetingLink(url: url, service: service)
        }
        return fallback
    }

    /// Which service a URL belongs to, or nil when it is just a link that
    /// happened to be in the invitation (a doc, an agenda, an unsubscribe
    /// footer). Matching is on HOST, never on the whole string: "zoom" appears
    /// in plenty of text that will not join a call.
    static func service(for url: URL) -> Service? {
        guard let host = url.host?.lowercased() else { return nil }
        let path = url.path.lowercased()

        if host.hasSuffix("zoom.us") || host.hasSuffix("zoomgov.com") {
            // Zoom's own site has marketing pages; only /j/ and /my/ join a call.
            return path.contains("/j/") || path.contains("/my/") || path.contains("/w/") ? .zoom : nil
        }
        if host == "meet.google.com" { return .meet }
        if host.hasSuffix("teams.microsoft.com") || host.hasSuffix("teams.live.com") {
            return path.contains("meetup-join") || path.contains("/l/meeting") ? .teams : nil
        }
        if host.hasSuffix("webex.com") { return path.contains("/meet") || path.contains("/j.php") ? .webex : nil }
        if host == "facetime.apple.com" { return .facetime }
        // A last resort for the services nobody has heard of: an https link whose
        // path is explicitly about joining.
        if url.scheme == "https", path.contains("/join") { return .generic }
        return nil
    }
}

/// When a meeting is close enough to be worth a chip.
public enum MeetingWindow {
    /// Show the join affordance this long before the start. Ten minutes is the
    /// span in which you actually go looking for the link.
    public static let leadTime: TimeInterval = 10 * 60

    /// Keep showing it this long after the start, for the meeting you are
    /// already late to — which is precisely when the chip earns its place.
    public static let graceTime: TimeInterval = 5 * 60

    public static func isImminent(start: Date, now: Date) -> Bool {
        let interval = start.timeIntervalSince(now)
        return interval <= leadTime && interval >= -graceTime
    }
}
