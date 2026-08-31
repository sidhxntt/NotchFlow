import Foundation

/// Which single occupant the resting notch's shoulders are showing.
///
/// The raw values are the ranks in `order.md`, ascending, so the ladder's shape
/// is visible in the type rather than only in the resolver that walks it.
public enum RestingNotchSlot: Int, Equatable, Sendable, CaseIterable, Comparable {
    case call = 1
    case notifications = 2
    /// A session that has stopped and cannot continue until the user answers.
    case agentQuestion = 3
    /// The five-second announcement of an agent state change.
    case agentAnnouncement = 4
    /// An Ask or Agent run started in this app.
    case work = 5
    case accessory = 6
    case focusTransition = 7
    /// An external CLI session still working or planning.
    case agentSteady = 8
    case nowPlaying = 9
    /// An offer, not an event.
    case clipboardSense = 10
    case none = 99

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Everything the ladder needs to know, as plain booleans.
///
/// Flattening the view's state into a value is what makes the priority order
/// testable against `order.md`. The alternative — a chain of `if` statements
/// reading `@ObservedObject` properties inside a SwiftUI `View` — can only be
/// verified by looking at it, and this ladder is exactly the kind of thing that
/// drifts silently: a wrong rank shows up as one ear occasionally missing, which
/// nobody reports as a bug.
public struct RestingNotchInputs: Equatable, Sendable {
    /// The panel is open somewhere, so the resting notch shows nothing at all.
    public var panelOpen: Bool
    /// Settings → Appearance → "Live activity". See `isMuted(by:)` for exactly
    /// which slots it silences.
    public var liveActivityEnabled: Bool

    public var call: Bool
    public var notifications: Bool
    public var agentQuestion: Bool
    public var agentAnnouncement: Bool
    public var backgroundWork: Bool
    public var accessoryEvent: Bool
    public var focusTransition: Bool
    public var agentSteady: Bool
    public var nowPlaying: Bool
    public var clipboardSense: Bool

    public init(panelOpen: Bool = false, liveActivityEnabled: Bool = true,
                call: Bool = false, notifications: Bool = false,
                agentQuestion: Bool = false, agentAnnouncement: Bool = false,
                backgroundWork: Bool = false, accessoryEvent: Bool = false,
                focusTransition: Bool = false, agentSteady: Bool = false,
                nowPlaying: Bool = false, clipboardSense: Bool = false) {
        self.panelOpen = panelOpen
        self.liveActivityEnabled = liveActivityEnabled
        self.call = call
        self.notifications = notifications
        self.agentQuestion = agentQuestion
        self.agentAnnouncement = agentAnnouncement
        self.backgroundWork = backgroundWork
        self.accessoryEvent = accessoryEvent
        self.focusTransition = focusTransition
        self.agentSteady = agentSteady
        self.nowPlaying = nowPlaying
        self.clipboardSense = clipboardSense
    }
}

public enum RestingNotchPriority {

    /// The slots the "Live activity" switch silences.
    ///
    /// Deliberately not every slot. The switch mutes the notch's *flexing* —
    /// the announcements that move the island — and leaves the quiet presence
    /// signals alone. Agent status is in the second group because a long CLI run
    /// is a state the user opted into watching, not an interruption.
    public static func isMuted(_ slot: RestingNotchSlot, liveActivityEnabled: Bool) -> Bool {
        guard !liveActivityEnabled else { return false }
        switch slot {
        case .call, .notifications, .work, .focusTransition:
            return true
        case .agentQuestion, .agentAnnouncement, .agentSteady,
             .accessory, .nowPlaying, .clipboardSense, .none:
            return false
        }
    }

    /// The one occupant, resolved in the order `order.md` specifies.
    ///
    /// Written as a table walked in rank order rather than a chain of early
    /// returns: adding a slot then means adding a row, and it is impossible to
    /// insert one at the wrong height without the rank being visibly wrong.
    public static func slot(for inputs: RestingNotchInputs) -> RestingNotchSlot {
        guard !inputs.panelOpen else { return .none }

        let candidates: [(RestingNotchSlot, Bool)] = [
            (.call,              inputs.call),
            (.notifications,     inputs.notifications),
            (.agentQuestion,     inputs.agentQuestion),
            (.agentAnnouncement, inputs.agentAnnouncement),
            (.work,              inputs.backgroundWork),
            (.accessory,         inputs.accessoryEvent),
            (.focusTransition,   inputs.focusTransition),
            (.agentSteady,       inputs.agentSteady),
            (.nowPlaying,        inputs.nowPlaying),
            (.clipboardSense,    inputs.clipboardSense)
        ]

        for (slot, active) in candidates
        where active && !isMuted(slot, liveActivityEnabled: inputs.liveActivityEnabled) {
            return slot
        }
        return .none
    }
}
