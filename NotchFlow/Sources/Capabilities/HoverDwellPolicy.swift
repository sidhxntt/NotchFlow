import Foundation

/// The intentional pause before hover opens the notch. Keeping this policy free
/// of AppKit lets its user-facing distinctions stay covered by unit tests.
public enum HoverDwellPolicy {
    public enum Level: String, CaseIterable, Sendable {
        case click
        case low
        case balanced
        case instant
    }

    /// `nil` means this level does not open from hover at all. A positive delay
    /// requires the pointer to dwell on the resting notch; zero opens at once.
    public static func openingDelay(for level: Level) -> TimeInterval? {
        switch level {
        case .click:    nil
        case .low:      0.5
        case .balanced: 0.25
        case .instant:  0
        }
    }
}
