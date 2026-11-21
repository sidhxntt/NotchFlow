import Foundation
import AppKit

/// Runs a **agent implementation task**: the user picks a folder, describes a
/// task, and a local agent CLI (Codex or Claude Code — `AgentEngine`) works
/// *in that folder* — reading and writing files — until it's done, then reports
/// its result back (XII: agent-to-Codex).
///
/// This is deliberately a different animal from `CodexCLIService` (the chat
/// backend), even though both shell out to the same `codex` binary:
///  · **write access** — the chat runs `-s read-only` in a throwaway temp dir; a
///    agent task runs `-s workspace-write -C <folder>` so Codex can actually
///    implement things in the user's project. (Network stays off inside the
///    sandbox — codex's own workspace-write default — so an unattended task can't
///    reach out; it can still read/write every file under the folder.)
///  · **lifetime** — a chat turn is seconds and dies with the panel; an agent
///    task is minutes and must survive the panel closing, so the process is owned
///    by this singleton, not by a view's stream. Closing the notch never cancels
///    it — and neither does quitting the app: the CLI's output goes to a file,
///    not a pipe, so the run keeps working unattended and the next launch
///    re-attaches to it (`recoverInterruptedRuns`).
///  · **user config** — the chat isolates itself (`--ignore-user-config`) for a
///    fast predictable answer; an agent task *honors* the user's own codex
///    setup (model, reasoning effort, skills), because capability matters more
///    than latency here. The session is also persisted (no `--ephemeral`), so the
///    user can pick the run up later with `codex resume` in a terminal.
///
/// Tasks run in parallel — submitting while others are working just spawns
/// another process (same folder included, by explicit decision: the CLIs cope
/// the way they do in a terminal). Each run owns its own process, parser and
/// teardown; nothing is shared between runs. Progress (the current command /
/// file edit) streams into its task's `activity` for the in-panel card;
/// completion posts a native notification (the user has almost certainly
/// walked away from a minutes-long task) and the result stays in `tasks`
/// until dismissed.
@MainActor
final class AgentTaskManager: ObservableObject {
    static let shared = AgentTaskManager()

    /// Hard ceiling on a single agent run. Generous — real implementation
    /// tasks take minutes — but bounded, so a hung codex can't spin forever.
    static let timeout: TimeInterval = 1800   // 30 min

    /// How a finished task ended.
    enum Outcome: Equatable { case success, failure, cancelled }

    /// One settled round of a task: the prompt that kicked it off and the
    /// answer it produced. A task accumulates one per follow-up — the full
    /// conversation `recordAgentHistory` files into Recent.
    struct AgentExchange: Equatable {
        let prompt: String
        let answer: String
        /// The images pasted into this round, parked in the history image store at
        /// spawn (filenames under `NotchModel.historyImagesDirectory`). They ride
        /// into the Recent row `recordAgentHistory` files, so a task whose whole
        /// description was a screenshot still reads as one when reopened.
        var imageFiles: [String] = []
        /// This round's slice of the work trail — the entries appended between
        /// the round's spawn and its settle. Rides the round into its history
        /// record, so a reopened run shows the same tool rows the live detail
        /// page did.
        var log: [AgentLogEntry] = []
    }

    /// Every live or finished-but-undismissed task, in spawn order.
    @Published var tasks: [AgentTask] = []
    @Published var externalApprovals: [ExternalApproval] = []

    /// Fired on the main actor when a run settles as success or failure (never
    /// cancel — the user just did that by hand). `AppDelegate` wires this to
    /// `NotchModel.recordAgentHistory`, which files the run into Recent so a
    /// dismissed card isn't the end of the record.
    var onSettled: ((AgentTask) -> Void)? = nil
    var runs: [UUID: RunState] = [:]
    var appServerPrompts: [UUID: String] = [:]
    var pendingFollowUps: [UUID: [QueuedFollowUp]] = [:]

    var externalReadOffsets: [String: UInt64] = [:]
    var externalSessionInfo: [String: (folder: URL, sessionID: String?)] = [:]
    var externalTrackedTools: [String: ExternalTrackedTool] = [:]
    var externalMonitorTimer: Timer?

    init() {
        scanExternalApprovalSessions()
        startExternalApprovalMonitoring()
    }

    deinit { externalMonitorTimer?.invalidate() }
}
