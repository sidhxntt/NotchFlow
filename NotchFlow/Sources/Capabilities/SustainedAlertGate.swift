import Foundation

/// Turns a sampled threshold into one notification only after the condition
/// remains true continuously for a chosen duration. A recovery rearms it.
public struct SustainedAlertGate: Sendable {
    public var duration: TimeInterval
    private var breachedSince: Date?
    private var hasAlerted = false

    public init(duration: TimeInterval) { self.duration = max(0, duration) }

    public mutating func observe(isBreached: Bool, at date: Date = Date()) -> Bool {
        guard isBreached else {
            breachedSince = nil
            hasAlerted = false
            return false
        }
        if breachedSince == nil { breachedSince = date }
        guard !hasAlerted, let breachedSince, date.timeIntervalSince(breachedSince) >= duration else {
            return false
        }
        hasAlerted = true
        return true
    }
}
