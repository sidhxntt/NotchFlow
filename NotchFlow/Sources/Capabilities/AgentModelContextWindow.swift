import Foundation

/// How large the model's context window is, for sessions that never say.
///
/// A NotchFlow-launched run is told outright — `claude -p --output-format
/// stream-json` reports `modelUsage.*.contextWindow`, and Codex's app-server
/// reports `model_context_window`. An **externally started** session is read
/// from its transcript instead, and a Claude transcript records no window at
/// all, so the scanner used to substitute a flat 200,000 for every one of them.
///
/// That constant is wrong for anyone on a long-context tier: the meter pinned at
/// "200k / 200k · 100%" in red from the moment the session passed 200k, which is
/// both false and the exact reading a user most needs to trust.
///
/// So the window is derived instead, from two pieces of evidence:
///
///  1. **The model id**, when it names its own tier (`[1m]`, `-1m`).
///  2. **What the session has actually used.** Occupancy is a hard floor: a
///     session holding 340k tokens is definitionally not on a 200k window. Since
///     each vendor ships a small, known set of tiers, the smallest tier that can
///     contain the observed usage is the honest answer — and it needs no
///     knowledge of the user's plan, which nothing on this machine records.
///
/// The result is a window that starts at the vendor's standard tier and promotes
/// itself the first time a session proves it is on a larger one.
public enum AgentModelContextWindow {

    /// The tiers each vendor actually ships, smallest first. Promotion only ever
    /// moves between these, so an unusual reading rounds up to a real product
    /// rather than inventing a bespoke number.
    private static func tiers(for source: AgentApprovalSource) -> [Int] {
        switch source {
        case .claude: return [200_000, 1_000_000]
        case .codex:  return [200_000, 272_000, 400_000, 1_000_000]
        }
    }

    /// The vendor's standard tier, used when the id names nothing more specific.
    private static func standard(for source: AgentApprovalSource) -> Int {
        tiers(for: source)[0]
    }

    /// Ids that state their own window. Matched as a substring of the lowercased
    /// id, most specific first.
    private static let declared: [(needle: String, window: Int)] = [
        ("[1m]", 1_000_000),
        ("-1m", 1_000_000),
        (":1m", 1_000_000)
    ]

    /// The window to show for one session.
    ///
    /// - Parameters:
    ///   - model: the model id the transcript reported, when it named one.
    ///   - source: which CLI, since the tier ladders differ.
    ///   - observedUsed: the session's current occupancy, the floor the window
    ///     must be able to contain.
    public static func window(for model: String?,
                              source: AgentApprovalSource,
                              observedUsed: Int?) -> Int {
        var window = standard(for: source)
        if let model = model?.lowercased() {
            for entry in declared where model.contains(entry.needle) {
                window = entry.window
                break
            }
        }
        guard let used = observedUsed, used > window else { return window }
        // Occupancy outran the assumed tier, so the assumption was wrong. Take
        // the smallest shipped tier that fits; if usage somehow exceeds every
        // known tier, report the usage itself rather than a meter stuck at 100%.
        return tiers(for: source).first { $0 >= used } ?? used
    }

    /// The same decision for a session whose transcript may already carry a real
    /// window. A reported window is always authoritative — except that it, too,
    /// cannot be smaller than what the session is holding.
    public static func window(reported: Int?,
                              model: String?,
                              source: AgentApprovalSource,
                              observedUsed: Int?) -> Int {
        guard let reported, reported > 0 else {
            return window(for: model, source: source, observedUsed: observedUsed)
        }
        guard let used = observedUsed, used > reported else { return reported }
        return tiers(for: source).first { $0 >= used } ?? used
    }
}
