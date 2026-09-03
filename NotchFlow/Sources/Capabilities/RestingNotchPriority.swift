import Foundation

/// Which single occupant the resting notch's shoulders are showing.
///
/// The raw values are the ranks in `order.md`, ascending, so the ladder's shape
/// is visible in the type rather than only in the resolver that walks it.
public enum RestingNotchSlot: Int, Equatable, Sendable, CaseIterable, Comparable {
    case notifications = 1
    /// A session that has stopped and cannot continue until the user answers.
    case agentQuestion = 2
    /// The five-second announcement of an agent state change.
    case agentAnnouncement = 3
    /// An Ask or Agent run started in this app.
    case work = 4
    case accessory = 5
    case focusTransition = 6
    /// An external CLI session still working or planning.
    case agentSteady = 7
    case nowPlaying = 8
    /// An offer, not an event.
    case clipboardSense = 9
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
    /// Settings → Appearance → "Live activity". When off, it keeps the
    /// collapsed notch clear by silencing every preview slot.
    public var liveActivityEnabled: Bool

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
                notifications: Bool = false,
                agentQuestion: Bool = false, agentAnnouncement: Bool = false,
                backgroundWork: Bool = false, accessoryEvent: Bool = false,
                focusTransition: Bool = false, agentSteady: Bool = false,
                nowPlaying: Bool = false, clipboardSense: Bool = false) {
        self.panelOpen = panelOpen
        self.liveActivityEnabled = liveActivityEnabled
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

    /// The slots the "Live activity" switch silences. The setting is the single
    /// master control for previews in the collapsed notch, so off leaves it blank.
    public static func isMuted(_ slot: RestingNotchSlot, liveActivityEnabled: Bool) -> Bool {
        guard !liveActivityEnabled else { return false }
        return slot != .none
    }

    /// The one shoulder occupant, resolved in the order `order.md` specifies.
    public static func slot(for inputs: RestingNotchInputs) -> RestingNotchSlot {
        return resolvedSlot(for: inputs)
    }

    /// Written as a table walked in rank order rather than a chain of early
    /// returns: adding a slot then means adding a row, and it is impossible to
    /// insert one at the wrong height without the rank being visibly wrong.
    private static func resolvedSlot(for inputs: RestingNotchInputs) -> RestingNotchSlot {
        guard !inputs.panelOpen else { return .none }

        let candidates: [(RestingNotchSlot, Bool)] = [
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
