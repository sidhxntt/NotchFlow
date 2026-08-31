import Foundation

/// The canonical project key for locally recorded AI activity. A missing
/// project is not an absent category: it is an external session, and readers
/// must compare against this displayed key rather than the raw optional value.
public enum AIActivityProject {
    public static let externalSessions = "External sessions"

    public static func display(_ project: String?) -> String {
        project ?? externalSessions
    }

    public static func matches(eventProject: String?, displayedProject: String?) -> Bool {
        displayedProject.map { display(eventProject) == $0 } ?? true
    }
}
