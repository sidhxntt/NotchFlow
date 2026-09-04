import Foundation

/// Local presentation state for projects dismissed from AI Activity. It never
/// touches the workspace or the recorded token archive.
public struct AIActivityProjectVisibility: Sendable {
    private var hiddenIDs = Set<String>()

    public init() {}
    public mutating func hide(_ id: String) { hiddenIDs.insert(id) }
    public mutating func show(_ id: String) { hiddenIDs.remove(id) }
    public mutating func reset() { hiddenIDs.removeAll() }
    public var hiddenCount: Int { hiddenIDs.count }
    public func isVisible(_ id: String) -> Bool { !hiddenIDs.contains(id) }
    public func visible(_ ids: [String]) -> [String] { ids.filter(isVisible) }
}

/// Which agent is asking. Codex and Claude Code reach the notch over completely
/// different transports — Codex over one long-lived JSON-RPC app-server
/// connection, Claude over a short-lived `PreToolUse` hook process per tool call
/// talking to a Unix socket — but they ask the user the *identical* question, so
/// they share one model, one per-session FIFO queue and one card.
public enum AgentApprovalSource: String, Equatable, Sendable {
    case codex
    case claude

    /// What the card calls it. Deliberately the agent's own name: the user needs
    /// to know WHICH agent is about to act, since several can be running at once.
    public var displayName: String {
        switch self {
        case .codex:  return "Codex"
        case .claude: return "Claude"
        }
    }
}

/// One approval the user has to answer before an agent may act.
/// The opaque `id` is whatever the transport needs to route the decision back —
/// Codex's JSON-RPC request id, Claude's `tool_use_id`.
public struct AgentApproval: Equatable, Identifiable, Sendable {
    public let id: String
    /// The session that owns the transport callback. This remains the child
    /// session for sub-agent work, so a decision always returns to the caller
    /// that actually requested it.
    public let threadID: String
    /// The root session that owns this request in the notch. A child agent's
    /// approval groups under its parent without changing its callback route.
    public let sessionGroupID: String
    public let itemID: String
    public let title: String
    /// What is being requested, retained for the agent transport and history.
    public let detail: String?
    /// The actual directory supplied by the agent. Kept separate from the
    /// request detail so the compact UI can show only its final folder name.
    public let workingDirectory: String?
    public let source: AgentApprovalSource

    /// `source` defaults to `.codex` only so `CodexAppServerBridge`, which
    /// predates this generalisation, still constructs these unchanged. New
    /// callers should always pass it explicitly.
    public init(id: String, threadID: String, itemID: String, title: String,
                detail: String? = nil, workingDirectory: String? = nil,
                source: AgentApprovalSource = .codex,
                sessionGroupID: String? = nil) {
        self.id = id
        self.threadID = threadID
        self.sessionGroupID = sessionGroupID ?? threadID
        self.itemID = itemID
        self.title = title
        self.detail = detail
        self.workingDirectory = workingDirectory
        self.source = source
    }

    /// The only directory text shown in the compact approval card.
    public var workingFolderName: String? {
        guard let directory = workingDirectory?
            .trimmingCharacters(in: .whitespacesAndNewlines), !directory.isEmpty
        else { return nil }

        let folder = (directory as NSString).lastPathComponent
        return folder.isEmpty ? nil : folder
    }

    /// Rehomes the *presentation* of an approval after the session scanner
    /// learns a child → root relationship. The original `threadID` stays put.
    public func grouped(under sessionGroupID: String) -> AgentApproval {
        AgentApproval(id: id, threadID: threadID, itemID: itemID, title: title,
                      detail: detail, workingDirectory: workingDirectory,
                      source: source, sessionGroupID: sessionGroupID)
    }
}

/// The visible head of a single agent session's FIFO approval queue.
public struct AgentApprovalSessionQueue: Equatable, Identifiable, Sendable {
    public let threadID: String
    public let approvals: [AgentApproval]

    public var id: String { threadID }
    public var current: AgentApproval { approvals[0] }
    public var pendingCount: Int { approvals.count }

    /// The one secondary line the narrow approval row has room to explain.
    /// Show the real working folder and queue depth, never a long path or
    /// command description that would make the prompt noisy.
    public var compactMetadataLabel: String {
        var parts: [String] = []
        if let folder = current.workingFolderName {
            parts.append(folder)
        }
        if pendingCount > 1 {
            parts.append("\(pendingCount) queued")
        }
        return parts.isEmpty ? current.source.displayName : parts.joined(separator: " · ")
    }
}

/// Preserves approval arrival order independently for every agent session.
public struct AgentApprovalQueue: Equatable, Sendable {
    /// One ordered list is the source of truth. Grouping it on read retains the
    /// exact arrival order when late metadata collapses several child queues
    /// into their root session.
    private var approvals: [AgentApproval] = []
    /// Session rows retain the order in which they first appeared, rather than
    /// jumping when an earlier request in another row is resolved.
    private var groupOrder: [String] = []

    public init() {}

    public var sessionQueues: [AgentApprovalSessionQueue] {
        var approvalsByGroup: [String: [AgentApproval]] = [:]
        for approval in approvals {
            if approvalsByGroup[approval.sessionGroupID] == nil {
                approvalsByGroup[approval.sessionGroupID] = []
            }
            approvalsByGroup[approval.sessionGroupID]?.append(approval)
        }
        return groupOrder.compactMap { groupID in
            guard let grouped = approvalsByGroup[groupID], !grouped.isEmpty else { return nil }
            return AgentApprovalSessionQueue(threadID: groupID, approvals: grouped)
        }
    }

    public mutating func enqueue(_ approval: AgentApproval) {
        guard !contains(id: approval.id) else { return }
        if !groupOrder.contains(approval.sessionGroupID) {
            groupOrder.append(approval.sessionGroupID)
        }
        approvals.append(approval)
    }

    public mutating func resolve(id: String) {
        approvals.removeAll { $0.id == id }
        groupOrder.removeAll { groupID in
            !approvals.contains { $0.sessionGroupID == groupID }
        }
    }

    public func contains(id: String) -> Bool {
        approvals.contains { $0.id == id }
    }

    /// Applies newly discovered hierarchy metadata to every queued Codex
    /// approval. Unknown and non-child sessions stay grouped under themselves.
    public mutating func regroup(using hierarchy: CodexSessionHierarchy) {
        approvals = approvals.map { approval in
            approval.grouped(under: hierarchy.rootSessionID(for: approval.threadID))
        }
        var nextOrder: [String] = []
        for groupID in groupOrder {
            let rootID = hierarchy.rootSessionID(for: groupID)
            if !nextOrder.contains(rootID) { nextOrder.append(rootID) }
        }
        for approval in approvals where !nextOrder.contains(approval.sessionGroupID) {
            nextOrder.append(approval.sessionGroupID)
        }
        groupOrder = nextOrder
    }
}

/// Parent links recorded in Codex's session metadata. The hierarchy is a value
/// so parsing, cycle handling, root resolution, and child counting remain
/// deterministic and independently testable from the live session scanner.
public struct CodexSessionHierarchy: Equatable, Sendable {
    private let parentBySessionID: [String: String]

    public init(parentBySessionID: [String: String] = [:]) {
        self.parentBySessionID = parentBySessionID.filter { child, parent in
            !child.isEmpty && !parent.isEmpty && child != parent
        }
    }

    /// Follows a child to its top-level parent. A malformed loop is intentionally
    /// left independent: merging unrelated callbacks is less safe than exposing
    /// a temporary extra row.
    public func rootSessionID(for sessionID: String) -> String {
        var current = sessionID
        var visited: Set<String> = []
        while let parent = parentBySessionID[current] {
            guard visited.insert(current).inserted, !visited.contains(parent) else {
                return sessionID
            }
            current = parent
        }
        return current
    }

    /// Counts every descendant, not merely direct children, under a root.
    public func subagentCount(for rootID: String) -> Int {
        parentBySessionID.keys.count { rootSessionID(for: $0) == rootID }
    }

    /// Counts only the descendants still doing something.
    ///
    /// The badge is a statement about right now, not about history: a root that
    /// fanned out six sub-agents an hour ago has six *finished* children and
    /// nothing running, and reporting "6" there describes the past. The
    /// hierarchy itself deliberately keeps every child it has seen, because a
    /// finished child's approval must still route to the right parent — so the
    /// filtering belongs here at the point of display, not in the hierarchy.
    public func activeSubagentCount(for rootID: String, activeIDs: Set<String>) -> Int {
        parentBySessionID.keys.count { activeIDs.contains($0) && rootSessionID(for: $0) == rootID }
    }

    /// Session parentage is immutable for a run. Retain previously observed
    /// links when a bounded scan omits an older but still-pending child.
    public func merging(_ newer: CodexSessionHierarchy) -> CodexSessionHierarchy {
        CodexSessionHierarchy(parentBySessionID: parentBySessionID.merging(newer.parentBySessionID) {
            _, latest in latest
        })
    }
}

// The Codex names these types were born with. Kept as aliases so the Codex
// bridge, its tests and the existing call sites read exactly as before while
// the model itself is now shared with Claude Code.
public typealias CodexApproval = AgentApproval
public typealias CodexApprovalSessionQueue = AgentApprovalSessionQueue
public typealias CodexApprovalQueue = AgentApprovalQueue

// MARK: - Session state presentation

/// The compact, per-session status shown by the Agent tab and resting notch.
public enum AgentSessionStatus: String, Equatable, Sendable {
    case working, planning, needsYou, question, planReady, done, interrupted

    fileprivate var priority: Int {
        switch self {
        case .needsYou: return 4
        case .question: return 3
        case .planning, .planReady: return 2
        case .working: return 1
        case .done, .interrupted: return 0
        }
    }

    public var symbolName: String {
        switch self {
        case .working: return "ellipsis"
        case .needsYou: return "hand.raised.fill"
        case .question: return "questionmark.bubble.fill"
        case .planning: return "ellipsis"
        case .planReady: return "checkmark.circle.fill"
        case .done: return "checkmark.circle.fill"
        case .interrupted: return "exclamationmark.triangle.fill"
        }
    }

    /// The folded notch is a short visual announcement, so each state owns one
    /// stable title-cased label and one colour semantic for its icon and rim.
    public var previewLabel: String {
        switch self {
        case .working: return "Working"
        case .needsYou: return "Needs You"
        case .question: return "Question"
        case .planning: return "Planning"
        case .planReady: return "Done"
        case .done: return "Done"
        case .interrupted: return "Closed"
        }
    }

    public var previewTone: AgentSessionPreviewTone {
        switch self {
        case .working: return .blue
        case .needsYou: return .orange
        case .question: return .yellow
        case .planning, .planReady: return .amber
        case .done: return .green
        case .interrupted: return .amber
        }
    }

    /// Whether a transcript scan can reach this conclusion on its own.
    ///
    /// This is what decides who wins when a pushed marker and a transcript scan
    /// disagree. Everything here is written into the session log, so a scan that
    /// ran *after* the marker arrived is the better witness and the marker is
    /// spent. The two exceptions are questions and pending permissions: nothing
    /// in the transcript records that the agent is blocked waiting on the user,
    /// so those markers stay authoritative until they are explicitly resolved.
    public var isTranscriptObservable: Bool {
        switch self {
        case .working, .planning, .planReady, .done, .interrupted: return true
        case .needsYou, .question: return false
        }
    }

    /// Nothing further is expected of this session: it finished, it finished a
    /// plan, or it closed. The complement is not "busy" but "still live" — a
    /// session waiting on the user is unsettled too.
    public var isSettled: Bool {
        switch self {
        case .done, .planReady, .interrupted: return true
        case .working, .planning, .needsYou, .question: return false
        }
    }

    /// The roster's delete action deliberately affects only settled sessions:
    /// a regular completion, a completed plan (both shown as Done), or Closed.
    public var isClearable: Bool { isSettled }

    /// Chooses the one state shown for a root and all of its delegated work.
    /// A root can emit its terminal event before its children have returned, so
    /// live children keep the shared row honest as Working. An interruption is
    /// terminal for the whole delegation tree and therefore outranks every
    /// other state.
    public static func aggregating(root: AgentSessionStatus,
                                   children: [AgentSessionStatus]) -> AgentSessionStatus {
        if root == .interrupted || children.contains(.interrupted) { return .interrupted }
        if children.contains(where: { !$0.isSettled }) { return .working }
        return root
    }

    /// Turn terminal events override the provisional activity state. A completed
    /// plan retains its distinct completed-plan presentation; an aborted or
    /// stale uncompleted turn is explicitly shown as interrupted.
    public func resolved(terminal: AgentSessionTerminal?) -> AgentSessionStatus {
        guard let terminal else { return self }
        switch terminal {
        case .completed:
            return self == .planning || self == .planReady ? .planReady : .done
        case .interrupted:
            return .interrupted
        }
    }
}

/// The terminal outcome reported by an agent transcript. A session remains open
/// until its transcript explicitly records an abort or a completed turn.
public enum AgentSessionTerminal: Equatable, Sendable {
    case completed, interrupted

    /// How long a turn may go silent and still be believed to be working.
    ///
    /// A live agent writes to its transcript constantly — assistant deltas, tool
    /// calls, tool results. Measured across 21,957 real mid-turn gaps on this
    /// machine: half are under 2.2s, 90% under 14s, 99% under 125s. The tail
    /// beyond that is not slow work, it is turns that never finished — a CLI
    /// killed mid-tool, a permission prompt left unanswered, a session abandoned.
    ///
    /// 180s sits above the 99th percentile, so genuinely slow work is not
    /// libelled, and below the scanner's own five-minute activity window, so the
    /// rule still has room to act before the session ages out of the roster
    /// entirely. It is the default, not a law: a user whose work runs long single
    /// tools (a full test suite under one Bash call) can raise it from
    /// Settings → Agent, and one who wants stalls surfaced faster can lower it.
    public static let defaultStalledAfter: TimeInterval = 180
    public static let stalledAfterChoices: [TimeInterval] = [60, 180, 300, 600]
    private static let stalledAfterKey = "agentStalledAfter"

    public static var stalledAfter: TimeInterval {
        get {
            (UserDefaults.standard.object(forKey: stalledAfterKey) as? Double)
                .map { $0 > 0 ? $0 : defaultStalledAfter } ?? defaultStalledAfter
        }
        set { UserDefaults.standard.set(newValue, forKey: stalledAfterKey) }
    }

    /// A turn that stopped without finishing is not a working turn.
    ///
    /// `inactiveFor` was previously accepted and ignored, which is why a session
    /// that was merely *open* — sitting idle at the prompt, or holding a turn
    /// that had died — kept reporting Working for as long as it stayed in the
    /// roster. An explicit completion or abort still wins over the clock.
    public static func inferred(completed: Bool, aborted: Bool,
                                inactiveFor idle: TimeInterval) -> AgentSessionTerminal? {
        if aborted { return .interrupted }
        if completed { return .completed }
        return idle >= stalledAfter ? .interrupted : nil
    }
}

/// Colour semantics shared by the folded agent preview's status icon and its
/// luminous notch edge. SwiftUI colour values stay in the app target while this
/// value type makes the behaviour independently testable.
public enum AgentSessionPreviewTone: Equatable, Sendable {
    case blue, yellow, amber, green, orange
}

/// Colour semantics for a context capacity bar. Kept independent of SwiftUI so
/// the threshold behaviour remains testable on every Agent surface.
public enum AgentContextTone: Equatable, Sendable {
    case green, yellow, red
}

/// Chooses the one context value that belongs in a session meter. Codex records
/// both a lifetime token total and a latest-turn snapshot; only the latter can
/// be compared honestly with the model's fixed context-window size.
public enum AgentContextUsage {
    public static func preferred(lastTurnTokens: Int?, lifetimeTokens: Int?) -> Int? {
        lastTurnTokens ?? lifetimeTokens
    }
}

/// One observed chat or CLI session before the AI Activity monitor folds it
/// under its provider. It remains view-neutral so aggregation is testable.
public struct AIActivityProviderSession: Identifiable, Equatable, Sendable {
    public let id: String
    public let providerID: String
    public let provider: String
    public let model: String
    public let status: String
    public let contextUsed: Int?
    public let contextWindow: Int?
    public let isCurrentChat: Bool
    public let isBaseline: Bool
    public let usageProvider: String

    public init(id: String, providerID: String, provider: String, model: String,
                status: String, contextUsed: Int? = nil, contextWindow: Int? = nil,
                isCurrentChat: Bool = false, isBaseline: Bool = false,
                usageProvider: String? = nil) {
        self.id = id; self.providerID = providerID; self.provider = provider
        self.model = model; self.status = status
        self.contextUsed = contextUsed; self.contextWindow = contextWindow
        self.isCurrentChat = isCurrentChat; self.isBaseline = isBaseline
        self.usageProvider = usageProvider ?? provider
    }
}

public struct AIActivityProviderSummary: Identifiable, Equatable, Sendable {
    public let id: String
    public let provider: String
    public let model: String
    public let status: String
    public let sessionCount: Int
    public let contextUsed: Int?
    public let contextWindow: Int?
    public let usageProvider: String
}

public enum AIActivityProviderAggregation {
    /// Adds one idle baseline for every provider not otherwise represented.
    /// A provider with any current chat or session remains exactly one summary.
    public static func summaries(for sessions: [AIActivityProviderSession],
                                 including providers: [AIActivityProviderSession]) -> [AIActivityProviderSummary] {
        var expanded = sessions
        for provider in providers where !expanded.contains(where: { $0.providerID == provider.providerID }) {
            expanded.append(provider)
        }
        return summaries(for: expanded)
    }

    public static func summaries(for sessions: [AIActivityProviderSession]) -> [AIActivityProviderSummary] {
        var order: [String] = []
        var grouped: [String: [AIActivityProviderSession]] = [:]
        for session in sessions {
            if grouped[session.providerID] == nil { order.append(session.providerID) }
            grouped[session.providerID, default: []].append(session)
        }
        return order.compactMap { providerID in
            guard let members = grouped[providerID], let first = members.first else { return nil }
            let current = members.first(where: \.isCurrentChat)
            let externalCount = members.filter { !$0.isCurrentChat && !$0.isBaseline }.count
            let realCount = members.filter { !$0.isBaseline }.count
            let status = current == nil
                ? realCount == 0 ? "No activity" : "\(realCount) \(realCount == 1 ? "session" : "sessions")"
                : externalCount == 0 ? "Current chat" : "Current chat · \(externalCount) \(externalCount == 1 ? "session" : "sessions")"
            // A context window is a per-session ceiling, not a quantity that
            // adds up: summing three 200k windows into "600k" turns the meter's
            // denominator into a number no model has. Report the busiest single
            // session instead, so "used / window" stays a statement someone
            // could check against the CLI itself.
            let busiest = members.max { ($0.contextUsed ?? 0) < ($1.contextUsed ?? 0) }
            let used = busiest?.contextUsed
            return .init(id: providerID, provider: first.provider,
                         model: (current ?? first).model, status: status,
                         sessionCount: realCount,
                         contextUsed: used,
                         contextWindow: used == nil ? nil : busiest?.contextWindow,
                         usageProvider: first.usageProvider)
        }
    }
}

/// A single, time-stamped change in Codex's cumulative transcript counters.
/// The counters themselves are session totals, so only a change between two
/// records can safely be attributed to a particular point in time.
public struct CodexTranscriptUsageEvent: Equatable, Sendable {
    public let id: String
    public let timestamp: Date
    public let input: Int
    public let output: Int

    public init(id: String, timestamp: Date, input: Int, output: Int) {
        self.id = id
        self.timestamp = timestamp
        self.input = input
        self.output = output
    }
}

/// Extracts provider-reported usage from Codex JSONL transcripts without
/// guessing at token counts or assigning a whole session lifetime to today.
public enum CodexTranscriptUsage {
    public static func incrementalEvents(in data: Data,
                                         identifierPrefix: String) -> [CodexTranscriptUsageEvent] {
        var prior: (input: Int, output: Int)?
        var events: [CodexTranscriptUsageEvent] = []

        for (index, line) in String(decoding: data, as: UTF8.self).split(separator: "\n").enumerated() {
            guard let item = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  item["type"] as? String == "event_msg",
                  let payload = item["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let totals = info["total_token_usage"] as? [String: Any],
                  let input = number(totals["input_tokens"]),
                  let output = number(totals["output_tokens"]),
                  let timestamp = timestamp(item["timestamp"]) else { continue }

            defer { prior = (input, output) }
            guard let prior else { continue }
            let inputDelta = max(0, input - prior.input)
            let outputDelta = max(0, output - prior.output)
            guard inputDelta + outputDelta > 0 else { continue }
            let ordinal = number(item["ordinal"]).map(String.init) ?? String(index)
            events.append(.init(id: "\(identifierPrefix):\(ordinal)", timestamp: timestamp,
                                input: inputDelta, output: outputDelta))
        }
        return events
    }

    private static func number(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        return (value as? NSNumber)?.intValue
    }

    private static func timestamp(_ value: Any?) -> Date? {
        guard let value = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}

/// Extracts one real Claude usage reading per provider message. Claude writes
/// multiple streaming snapshots with the same message id, so those snapshots
/// are intentionally counted once.
public enum ClaudeTranscriptUsage {
    public static func events(in data: Data, identifierPrefix: String) -> [CodexTranscriptUsageEvent] {
        var seen = Set<String>()
        var events: [CodexTranscriptUsageEvent] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let item = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  item["type"] as? String == "assistant",
                  let message = item["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let identifier = (message["id"] as? String) ?? (item["uuid"] as? String),
                  seen.insert(identifier).inserted
            else { continue }
            let input = number(usage["input_tokens"]) + number(usage["cache_read_input_tokens"]) + number(usage["cache_creation_input_tokens"])
            let output = number(usage["output_tokens"])
            guard input + output > 0,
                  let timestamp = date(item["timestamp"] as? String)
            else { continue }
            events.append(.init(id: "\(identifierPrefix):\(identifier)", timestamp: timestamp, input: input, output: output))
        }
        return events
    }

    private static func number(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        return (value as? NSNumber)?.intValue ?? 0
    }

    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

/// The latest model-window occupancy reported by a Codex transcript.
public struct CodexTranscriptContext: Equatable, Sendable {
    public let used: Int
    public let window: Int?

    public static func latest(in data: Data) -> CodexTranscriptContext? {
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").reversed() {
            guard let item = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  item["type"] as? String == "event_msg",
                  let payload = item["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any] else { continue }
            let latest = info["last_token_usage"] as? [String: Any]
            let lifetime = info["total_token_usage"] as? [String: Any]
            guard let used = AgentContextUsage.preferred(
                lastTurnTokens: number(latest?["total_tokens"]),
                lifetimeTokens: number(lifetime?["total_tokens"])
            ) else { continue }
            return .init(used: used, window: number(info["model_context_window"]))
        }
        return nil
    }

    private static func number(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        return (value as? NSNumber)?.intValue
    }
}

/// Session-scoped state fed by a live CLI session log and the direct approval
/// bridges. It keeps every agent independent: one attention state never hides
/// another session's work, usage, or child-agent count.
public struct AgentSessionState: Equatable, Identifiable, Sendable {
    public let id: String
    public let source: AgentApprovalSource
    /// The concrete model reported by the session transcript, when the CLI
    /// exposes one. This is intentionally distinct from a configured default.
    public let modelName: String?
    /// Final component of the session's recorded working directory, used as
    /// the compact root-project label in the Agent workspace.
    public let projectName: String?
    /// The complete workspace path is retained for identity reconciliation;
    /// the UI continues to show only `projectName`.
    public let workingDirectory: String?
    public var status: AgentSessionStatus
    public var contextUsed: Int?
    public var contextWindow: Int?
    public var subagentCount: Int
    /// The plan this session is presenting, when its transcript records one.
    /// Only the agent's own proposal — never the user's prompt.
    public var planSummary: String?

    public init(id: String, source: AgentApprovalSource, status: AgentSessionStatus,
                contextUsed: Int? = nil, contextWindow: Int? = nil,
                subagentCount: Int = 0, projectName: String? = nil, modelName: String? = nil,
                workingDirectory: String? = nil, planSummary: String? = nil) {
        self.id = id; self.source = source; self.status = status; self.projectName = projectName
        self.modelName = modelName
        self.workingDirectory = workingDirectory
        self.contextUsed = contextUsed; self.contextWindow = contextWindow
        self.subagentCount = max(0, subagentCount)
        self.planSummary = planSummary
    }

    /// The denominator the meter and its label agree on.
    ///
    /// A session that reported no window at all falls back to the vendor's
    /// standard tier — but never to a number smaller than what the session is
    /// already holding, which would render as a permanently full red bar.
    public var contextLimit: Int {
        max(1, contextWindow ?? max(contextUsed ?? 0, 200_000))
    }

    public var contextProgress: Double {
        guard let used = contextUsed, used > 0 else { return 0 }
        return min(1, Double(used) / Double(contextLimit))
    }

    public var contextLabel: String {
        let limit = contextLimit
        let used = min(max(0, contextUsed ?? 0), limit)
        return "\(Self.format(used)) / \(Self.format(limit))"
    }

    /// The compact, rounded value used beside the Agent tab's context meter.
    /// Keeping this with `contextProgress` means every agent surface reports the
    /// same percentage rather than each rounding a `Double` independently.
    public var contextPercentageLabel: String {
        "\(Int((contextProgress * 100).rounded()))%"
    }

    public var contextTone: AgentContextTone {
        switch contextProgress {
        case 0.85...: return .red
        case 0.50...: return .yellow
        default: return .green
        }
    }

    public var subagentBadge: String? {
        guard AgentDisplayPolicy.showsSubagents, subagentCount > 0 else { return nil }
        return "\(subagentCount)"
    }

    public mutating func apply(status next: AgentSessionStatus) {
        // Plan exit is its own completed state. Preserve its yellow checkmark
        // when a generic terminal marker arrives for the same turn; a later
        // Working marker clears it before any real work completion can apply.
        if status == .planReady && next == .done { return }
        if status == .planning && next == .done {
            status = .planReady
            return
        }
        // A completion marker is allowed to land. Whether it is still *timely*
        // is not this function's decision — `AgentSessionActivityStore` drops
        // markers a later scan has already superseded, so anything reaching
        // here is newer than the transcript's own reading. Rejecting `.done`
        // outright, as this used to, made the CLI's own idle marker a no-op and
        // left quiet sessions reading Working until the marker aged out.
        //
        // The converse can happen after a run settles: its earlier Working
        // marker remains cached while the transcript has already recorded the
        // terminal event. Keep the scanner-confirmed outcome intact — for a
        // closed session as much as a completed one, or a hook marker left
        // behind by the very run that was cancelled would report it as still
        // working for the marker's whole lifetime.
        //
        // A completed *plan* is deliberately not covered: work resuming after a
        // plan is a real transition, handled by `workResumesAfterPlan` below.
        if (status == .done || status == .interrupted) && next == .working { return }
        let workResumesAfterPlan = next == .working && (status == .planning || status == .planReady)
        if next == .done || next == .interrupted || next.priority >= status.priority || workResumesAfterPlan {
            status = next
        }
    }

    private static func format(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fm", Double(count) / 1_000_000) }
        if count >= 1_000 { return "\(count / 1_000)k" }
        return "\(count)"
    }
}

/// Resolves the presentation owner for a direct terminal permission. A CLI
/// hook can arrive using an ephemeral identifier while the transcript scanner
/// has already observed the resumed root. We only bridge that gap when exactly
/// one active Codex root owns the same workspace; concurrent roots therefore
/// remain separate rather than being guessed into a single row.
public enum AgentSessionWorkspaceMatcher {
    public static func rootID(for approval: AgentApproval, among sessions: [AgentSessionState]) -> String {
        guard let workingDirectory = normalized(approval.workingDirectory)
        else { return approval.sessionGroupID }

        if sessions.contains(where: { $0.source == approval.source && $0.id == approval.sessionGroupID }) {
            return approval.sessionGroupID
        }

        let candidates = sessions.filter {
            $0.source == approval.source
                && $0.status != .done
                && $0.status != .interrupted
                && normalized($0.workingDirectory) == workingDirectory
        }
        return candidates.count == 1 ? candidates[0].id : approval.sessionGroupID
    }

    private static func normalized(_ path: String?) -> String? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
        let normalized = (path as NSString).standardizingPath
        return normalized == "/" ? normalized : normalized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

/// A deliberately short-lived folded-notch signal. The expanded Agent tab keeps
/// its completed session card; this only prevents a settled session from
/// permanently occupying the physical-notch preview.
public struct AgentSessionPreview: Equatable, Sendable {
    public static let duration: TimeInterval = 5

    public let session: AgentSessionState
    public let shownAt: Date

    public init(session: AgentSessionState, shownAt: Date = Date()) {
        self.session = session
        self.shownAt = shownAt
    }

    public func isVisible(at date: Date = Date()) -> Bool {
        let age = date.timeIntervalSince(shownAt)
        return age >= 0 && age < Self.duration
    }
}

/// What the agent roster is allowed to draw. Display-only: the counts and states
/// behind these are still computed, so turning one off hides a cue rather than
/// changing what the app believes about a session.
public enum AgentDisplayPolicy {
    private static let subagentsKey = "agentShowsSubagents"

    /// Whether a session row carries its live sub-agent count. On by default; a
    /// fan-out of 96 children (measured on this machine) turns the roster into a
    /// wall of badges, so it is worth being able to silence.
    public static var showsSubagents: Bool {
        get { UserDefaults.standard.object(forKey: subagentsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: subagentsKey) }
    }
}

/// Retention policy for externally observed agent transcripts. The transcript
/// modification time is activity evidence, not an expiry for the agent itself:
/// a single tool call can legitimately take far longer than five minutes.
public enum AgentSessionObservation {
    /// How far back a transcript's last write may be and still put its session in
    /// the roster. A day by default. Adjustable from Settings → Agent because the
    /// right answer depends on the machine: on one holding gigabytes of rollouts
    /// a shorter window is the difference between a fast cold start and a slow
    /// one, while someone who keeps a session open across days needs the longer
    /// reach to see it at all.
    public static let defaultActiveFileWindow: TimeInterval = 24 * 60 * 60
    public static let activeFileWindowChoices: [TimeInterval] = [
        6 * 60 * 60, 12 * 60 * 60, 24 * 60 * 60, 3 * 24 * 60 * 60, 7 * 24 * 60 * 60
    ]
    private static let activeFileWindowKey = "agentActiveFileWindow"

    public static var activeFileWindow: TimeInterval {
        get {
            (UserDefaults.standard.object(forKey: activeFileWindowKey) as? Double)
                .map { $0 > 0 ? $0 : defaultActiveFileWindow } ?? defaultActiveFileWindow
        }
        set { UserDefaults.standard.set(newValue, forKey: activeFileWindowKey) }
    }

    public static func isWithinActiveWindow(_ modifiedAt: Date, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(modifiedAt)
        return age >= 0 && age <= activeFileWindow
    }
}

/// A non-approval interaction emitted by the NotchFlow-compatible
/// hook. A question or plan marker can inform the status UI but never grants a
/// tool permission — that authority remains with an approval bridge.
public struct AgentSessionMarker: Equatable, Sendable {
    public let sessionID: String
    public let source: AgentApprovalSource
    public let status: AgentSessionStatus
    /// A terminal hook marker can be displayed with its root's approval card
    /// while still belonging to a child session. This flag preserves that
    /// distinction until the activity store decides whether it may settle the
    /// visible root session.
    public let isSubagent: Bool
    public let detail: String?
    public let options: [String]
    /// Kept for safe transcript matching only; the UI renders the transcript's
    /// compact project name rather than this full path.
    public let workingDirectory: String?

    public init(sessionID: String, source: AgentApprovalSource, status: AgentSessionStatus,
                isSubagent: Bool = false, detail: String? = nil, options: [String] = [],
                workingDirectory: String? = nil) {
        self.sessionID = sessionID; self.source = source; self.status = status
        self.isSubagent = isSubagent
        self.detail = detail; self.options = options; self.workingDirectory = workingDirectory
    }

    /// A direct hook process has ended. Its visible status must settle instead
    /// of leaving a provisional Working marker in the roster. A live transcript
    /// scan still wins over this lower-priority terminal marker.
    public static func transportEnded(for approval: AgentApproval) -> AgentSessionMarker {
        AgentSessionMarker(sessionID: approval.threadID, source: approval.source,
                           status: .interrupted,
                           isSubagent: approval.threadID != approval.sessionGroupID,
                           detail: approval.detail,
                           workingDirectory: approval.workingDirectory)
    }

    /// Child activity may share a root card, but a terminal child completion
    /// cannot complete that root's turn. An interruption is different: it is
    /// terminal for the whole delegation tree. `hierarchyRoot` is the marker's
    /// Codex root when known and its own id for every independent session.
    public func mayUpdateRootSession(hierarchyRoot: String) -> Bool {
        if status == .interrupted { return true }
        return !status.isSettled || (!isSubagent && sessionID == hierarchyRoot)
    }

    public static func decode(_ data: Data) -> AgentSessionMarker? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawSource = object["source"] as? String,
              let source = AgentApprovalSource(rawValue: rawSource),
              let sessionID = nonEmpty(object["session_id"]),
              let action = object["action"] as? String else { return nil }
        let status: AgentSessionStatus
        switch action {
        case "marker":
            switch object["kind"] as? String {
            case "question": status = .question
            case "plan": status = .planning
            case "plan_done", "planDone": status = .planReady
            case "idle": status = .done
            default: return nil
            }
        case "start", "busy", "busydone": status = .working
        case "done": status = .done
        default: return nil
        }
        return AgentSessionMarker(sessionID: sessionID, source: source, status: status,
                                  detail: nonEmpty(object["detail"]),
                                  options: (object["options"] as? [Any] ?? []).compactMap { nonEmpty($0) },
                                  workingDirectory: nonEmpty(object["cwd"]))
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
