import Foundation
import AppKit

@MainActor
extension AgentTaskManager {
    /// One agent task, live or finished. The manager keeps every undismissed
    /// task in `tasks`, in spawn order.
    struct AgentTask: Equatable, Identifiable {
        /// Fresh per run — except on a resume, which revives an interrupted run
        /// under the id its Recent row already carries (see `resume`), so the row
        /// it settles back into is the same one, not a fork. (A `var` purely so
        /// the memberwise init can take it; nothing ever reassigns it.)
        var id = UUID()
        let engine: AgentEngine
        /// The model this run actually rides — the armed row's explicit pick to
        /// begin with, then overwritten by the id the CLI itself reports on its
        /// session event, so a run on the CLI-config default still names a
        /// concrete model in the detail's info line rather than "default".
        var modelID: String? = nil
        let folder: URL
        /// The task description the run STARTED with. Follow-up prompts live in
        /// `exchanges` (and in the work trail); this stays the card's headline.
        let prompt: String
        /// Reset on every round, so the elapsed clock (and "finished in …")
        /// times the round, not the whole conversation.
        var startedAt: Date
        /// The CLI's own conversation handle — claude's `session_id` (init
        /// event) / codex's `thread_id` (thread.started). Once known, the
        /// settled card grows a follow-up input that resumes this session.
        /// Re-captured every round: claude forks a NEW id on --resume.
        var sessionID: String? = nil
        /// Tokens occupying the model's context window after the latest turn
        /// (input + cache reads/creation), from the CLI's own usage events.
        var contextUsed: Int? = nil
        /// The window those tokens sit in, when the CLI reports it (claude's
        /// result event does; codex usually doesn't — absolute count only).
        var contextWindow: Int? = nil
        /// Every settled round so far, in order — the follow-up conversation.
        var exchanges: [AgentExchange] = []
        /// The latest activity line while running ("$ npm test", "Editing Foo.swift").
        var activity: String? = nil
        /// A state-changing tool that is still waiting for its result. This is
        /// the small bit of state NotchFlow uses to decide whether the user
        /// needs to check the interactive terminal.
        var activePermissionTool: String? = nil
        var activePermissionEntryID: UUID? = nil
        var activePermissionStartedAt: Date? = nil
        /// Set only after `AgentPermissionPolicy.delay`; it is a handoff cue,
        /// never an in-notch approval prompt.
        var pendingPermissionTool: String? = nil
        /// Distinct files codex reported changing, by name — the finished card's
        /// "N files changed" summary.
        var changedFiles: [String] = []
        /// The full work trail (every tool call + its output, in order) behind
        /// the one-line `activity` — the card's tap-to-expand detail. Capped at
        /// `logCap`; oldest entries fall off a marathon run.
        var log: [AgentLogEntry] = []
        var finishedAt: Date? = nil
        var outcome: Outcome? = nil          // nil while running
        /// Codex's final message — the reported result of the implementation.
        var result: String = ""
        /// The failure reason when `outcome == .failure`.
        var failureReason: String? = nil
        /// The armed row's original model/effort picks, replayed verbatim on
        /// every follow-up spawn (`modelID` gets overwritten by the id the CLI
        /// itself reports, which isn't necessarily a valid flag value to send
        /// back).
        var armedModel: String? = nil
        var armedEffort: AgentEffort? = nil
        /// True only for a task rebuilt by `recoverInterruptedRuns` — the app died
        /// mid-run. Its Recent row keeps the CLI session behind it, so the row can
        /// offer the in-app resume (`resume`) instead of only naming a terminal
        /// command. Cleared by definition once the resumed run settles normally.
        var interrupted = false

        var isRunning: Bool { outcome == nil }
        var elapsed: TimeInterval { max(0, (finishedAt ?? Date()).timeIntervalSince(startedAt)) }
    }

    /// A permission prompt observed in an interactive Codex or Claude session.
    /// The agent owns the decision; Notch only makes the blocked state visible
    /// and opens that session's project in Terminal.
    struct ExternalApproval: Equatable, Identifiable {
        let id: String
        let engine: AgentEngine
        let toolName: String
        let folder: URL
        let sessionID: String?
        let startedAt: Date
    }

    var isRunning: Bool { tasks.contains(where: \.isRunning) }
    var runningTasks: [AgentTask] { tasks.filter(\.isRunning) }
    var hasPendingApproval: Bool {
        CodexAppServerBridge.shared.hasPendingApprovals
            || ClaudeHookBridge.shared.hasPendingApprovals
            || CodexTerminalHookBridge.shared.hasPendingApprovals
    }

    /// The mutable bookkeeping behind ONE spawned round: its process handle,
    /// cancel flag, temp image files, and the prompt/images `settle` pairs into
    /// the round's exchange. Keyed by task id in `runs` — created at launch,
    /// discarded at settle — so parallel runs never share a slot.
    final class RunState {
        var process: Process? = nil
        /// The spawned pid — kept beside `process` because a re-attached run
        /// (adopted from a previous app instance by `recoverInterruptedRuns`)
        /// has no `Process` handle: the pid is all it signals and watches.
        var pid: pid_t? = nil
        /// Wall clock at spawn. On recovery it's compared against the kernel's
        /// own start time for the pid, so a recycled pid can't impersonate the run.
        var spawnedAt: Date? = nil
        /// Tails the round's stdout log file (the CLI writes to a file, not a
        /// pipe — see `launch`), feeding the parser while the app is alive.
        var stdoutTailer: RunLogTailer? = nil
        /// Exit watch for a re-attached run — kqueue via a dispatch process
        /// source, because the process is not our child and has no
        /// termination handler.
        var exitWatch: DispatchSourceProcess? = nil
        /// Set by `cancel()` so the termination handler files the run as
        /// cancelled rather than failed.
        var cancelRequested = false
        /// Set by `interrupt()` — a cancel that is really a hand-over: the round
        /// still files as cancelled (it WAS stopped mid-work, and whatever it
        /// already reported is worth keeping), but instead of ending the task,
        /// `settle` immediately opens a new round in the same session carrying
        /// this instruction.
        var interruptPrompt: String?
        var interruptImages: [Data] = []
        /// The temp files the round's pasted images were written to for codex's
        /// `exec -i` — deleted when the run settles.
        var tempImageURLs: [URL] = []
        /// The prompt driving this round — the task description on round one,
        /// the follow-up text after.
        var currentPrompt = ""
        /// The temporary `› prompt` row shown while a follow-up is in flight.
        /// Once this round settles, its exchange renders the same prompt as a
        /// real user bubble, so `settle` removes this marker from both the flat
        /// trail and whichever earlier exchange temporarily owned it.
        var promptMarkerID: UUID?
        /// The round's images, as filenames in the history image store.
        var currentImageFiles: [String] = []
        /// Where in the task's work trail this round began — `settle` slices the
        /// round's own entries out with it (for the exchange's `log`). Walked
        /// back when the log cap trims the front of a marathon trail.
        var logStartIndex = 0
    }

    /// Follow-ups typed while the task's round was still in flight — the CLI
    /// can't take a new instruction mid-round, and dropping the line on the
    /// floor loses user input. Each queues here (its "› " marker joins the
    /// trail immediately) and `settle` dispatches them in order, one per
    /// settle, each as its own round in the same session. A cancel clears the
    /// task's queue: the user said stop, so nothing auto-restarts.
    struct QueuedFollowUp {
        let prompt: String
        let imagesJPEG: [Data]
        let markerID: UUID
    }

    struct ExternalTrackedTool {
        let engine: AgentEngine
        let toolName: String
        let folder: URL
        let sessionID: String?
        let startedAt: Date
    }

    func resumeAfterEntitlementRestored() {
        guard externalMonitorTimer == nil else { return }
        scanExternalApprovalSessions()
        startExternalApprovalMonitoring()
    }

    func startExternalApprovalMonitoring() {
        externalMonitorTimer = Timer.scheduledTimer(
            withTimeInterval: 0.5,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.scanExternalApprovalSessions() }
        }
    }
}
