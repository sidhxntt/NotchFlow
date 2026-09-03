import Foundation
import Testing
@testable import NotchCapabilities

// Every fixture below is the shape recorded by a real CLI, checked against the
// transcripts on disk. The rules these cover all previously matched nothing,
// which is why both agents reported "Working" indefinitely.

// MARK: - Claude

private func claudeEntries(_ objects: [[String: Any]]) -> [[String: Any]] { objects }

private func assistant(text: String = "ok", tools: [String] = []) -> [String: Any] {
    var content: [[String: Any]] = [["type": "text", "text": text]]
    content += tools.map { ["type": "tool_use", "name": $0, "id": "toolu_\($0)"] }
    return ["type": "assistant", "sessionId": "s1", "message": ["role": "assistant", "content": content]]
}

private func userPrompt(_ text: String) -> [String: Any] {
    ["type": "user", "sessionId": "s1", "message": ["role": "user", "content": [["type": "text", "text": text]]]]
}

private func toolResult() -> [String: Any] {
    ["type": "user", "sessionId": "s1",
     "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_Bash"]]]]
}

private func permissionMode(_ mode: String) -> [String: Any] {
    ["type": "permission-mode", "sessionId": "s1", "permissionMode": mode]
}

private func turnEnded() -> [String: Any] {
    ["type": "system", "subtype": "turn_duration", "sessionId": "s1"]
}

/// The bookkeeping Claude Code appends *after* a turn settles. `file-history-snapshot`
/// notably carries no session id at all.
private func trailingNoise() -> [[String: Any]] {
    [["type": "attachment", "sessionId": "s1"],
     ["type": "file-history-snapshot"],
     ["type": "last-prompt", "sessionId": "s1"],
     ["type": "ai-title", "sessionId": "s1"],
     ["type": "mode", "sessionId": "s1", "mode": "normal"]]
}

@Test("a Claude session id survives trailing records that carry none")
func claudeSessionIDIgnoresIdlessTrailingRecords() {
    let entries = claudeEntries([userPrompt("hi"), assistant()] + trailingNoise())

    #expect(ClaudeTranscriptStatus.sessionID(in: entries) == "s1")
}

@Test("a finished Claude turn reads as done even under trailing bookkeeping")
func claudeTurnEndIsFoundBehindTrailingRecords() {
    let entries = claudeEntries([userPrompt("hi"), assistant(tools: ["Bash"]), toolResult(),
                                 assistant(), turnEnded()] + trailingNoise())

    #expect(ClaudeTranscriptStatus.reading(in: entries).status == .done)
}

@Test("a Claude turn whose last answer carries no tool call is done")
func claudeFinalAnswerCompletesTheTurn() {
    let entries = claudeEntries([userPrompt("hi"), assistant()] + trailingNoise())

    #expect(ClaudeTranscriptStatus.reading(in: entries).status == .done)
}

@Test("a Claude turn waiting on a tool result is still working")
func claudePendingToolKeepsWorking() {
    let entries = claudeEntries([userPrompt("hi"), assistant(tools: ["Bash"])])

    #expect(ClaudeTranscriptStatus.reading(in: entries).status == .working)
}

@Test("a new Claude prompt after a finished turn is working again")
func claudeNewPromptReopensTheTurn() {
    let entries = claudeEntries([assistant(), turnEnded(), userPrompt("and now this")])

    #expect(ClaudeTranscriptStatus.reading(in: entries).status == .working)
}

@Test("Claude plan mode reads as Planning")
func claudePlanModeIsPlanning() {
    let entries = claudeEntries([userPrompt("plan it"), permissionMode("plan"),
                                 assistant(tools: ["Read"])])

    #expect(ClaudeTranscriptStatus.reading(in: entries).status == .planning)
}

@Test("leaving Claude plan mode reads as a completed plan, not an ordinary completion")
func claudeLeavingPlanModeIsPlanReady() {
    let entries = claudeEntries([permissionMode("plan"), assistant(tools: ["Read"]),
                                 permissionMode("acceptEdits"), assistant(), turnEnded()])

    let status = ClaudeTranscriptStatus.reading(in: entries).status
    #expect(status == .planReady)
    #expect(status.previewTone == .amber)
}

@Test("Claude's ExitPlanMode tool completes a plan")
func claudeExitPlanModeToolIsPlanReady() {
    // PascalCase. There is no `exit_plan_mode`, which is what the scanner used
    // to look for — so an accepted plan never showed its yellow check.
    let entries = claudeEntries([permissionMode("plan"), assistant(tools: ["ExitPlanMode"])])

    #expect(ClaudeTranscriptStatus.reading(in: entries).activity == .planReady)
}

@Test("an escaped Claude turn reads as a closed session")
func claudeInterruptionIsAClosedSession() {
    let entries = claudeEntries([userPrompt("go"), assistant(tools: ["Bash"]),
                                 userPrompt("[Request interrupted by user]")] + trailingNoise())

    let status = ClaudeTranscriptStatus.reading(in: entries).status
    #expect(status == .interrupted)
    #expect(status.previewLabel == "Closed")
}

@Test("an ordinary Claude turn is never mistaken for an interruption")
func claudeOrdinaryPromptIsNotAnInterruption() {
    let entries = claudeEntries([assistant(), userPrompt("carry on")])

    #expect(ClaudeTranscriptStatus.reading(in: entries).terminal == nil)
}

@Test("Claude's synthetic placeholder never becomes the displayed model")
func claudeSyntheticModelIsSkipped() {
    let entries: [[String: Any]] = [
        ["type": "assistant", "message": ["model": "claude-opus-5"]],
        ["type": "assistant", "message": ["model": "<synthetic>"]]
    ]

    #expect(ClaudeTranscriptStatus.modelName(in: entries) == "claude-opus-5")
}

@Test("a Claude transcript is parsed straight from its JSONL bytes")
func claudeReadingParsesRawJSONL() {
    let lines = [userPrompt("hi"), assistant(), turnEnded()]
        .compactMap { try? JSONSerialization.data(withJSONObject: $0) }
        .map { String(decoding: $0, as: UTF8.self) }
    let data = Data(lines.joined(separator: "\n").utf8)

    #expect(ClaudeTranscriptStatus.reading(in: data).status == .done)
}

// MARK: - Codex

private func codexEvent(_ kind: String) -> [String: Any] {
    ["type": "event_msg", "payload": ["type": kind]]
}

private func codexTurn(mode: String = "default") -> [String: Any] {
    ["type": "turn_context", "payload": ["collaboration_mode": ["mode": mode]]]
}

@Test("an aborted Codex turn reads as a closed session")
func codexAbortedTurnIsAClosedSession() {
    // `turn_aborted` lives inside the `event_msg` envelope. Matching it on the
    // envelope's own `type` — as the scanner did — never fired, so a cancelled
    // Codex run could not reach this state.
    let entries = [codexTurn(), codexEvent("task_started"), codexEvent("turn_aborted")]

    #expect(CodexTranscriptStatus.terminal(in: entries) == .interrupted)
    #expect(CodexTranscriptStatus.reading(in: entries).status == .interrupted)
}

@Test("a completed Codex turn reads as done")
func codexCompletedTurnIsDone() {
    let entries = [codexTurn(), codexEvent("task_started"), codexEvent("task_complete")]

    #expect(CodexTranscriptStatus.reading(in: entries).status == .done)
}

@Test("an earlier Codex turn's completion never settles the newest turn")
func codexOnlyTheNewestTurnCounts() {
    let entries = [codexTurn(), codexEvent("task_complete"),
                   codexTurn(), codexEvent("task_started")]

    #expect(CodexTranscriptStatus.terminal(in: entries) == nil)
    #expect(CodexTranscriptStatus.reading(in: entries).status == .working)
}

@Test("Codex plan mode reads as Planning, and leaving it as a completed plan")
func codexPlanModeTransitions() {
    let planning = [codexTurn(mode: "plan"), codexEvent("task_started")]
    #expect(CodexTranscriptStatus.reading(in: planning).status == .planning)

    let left = [codexTurn(mode: "plan"), codexTurn(mode: "default"), codexEvent("task_complete")]
    #expect(CodexTranscriptStatus.reading(in: left).status == .planReady)
}

@Test("an abort outranks a completion in the same Codex turn")
func codexAbortOutranksCompletion() {
    let entries = [codexTurn(), codexEvent("task_complete"), codexEvent("turn_aborted")]

    #expect(CodexTranscriptStatus.terminal(in: entries) == .interrupted)
}

// MARK: - Activity aggregation

@Test("a provider's context meter reports one session's window, never their sum")
func activityContextWindowIsNotSummed() {
    let sessions = [
        AIActivityProviderSession(id: "a", providerID: "claude", provider: "Claude", model: "Opus",
                                  status: "Working", contextUsed: 40_000, contextWindow: 200_000),
        AIActivityProviderSession(id: "b", providerID: "claude", provider: "Claude", model: "Opus",
                                  status: "Working", contextUsed: 150_000, contextWindow: 200_000)
    ]

    let summary = AIActivityProviderAggregation.summaries(for: sessions)[0]

    #expect(summary.contextWindow == 200_000)
    #expect(summary.contextUsed == 150_000)
    #expect(summary.sessionCount == 2)
}

@Test("a provider with no reported context leaves its meter empty")
func activityContextIsAbsentWithoutReadings() {
    let sessions = [
        AIActivityProviderSession(id: "a", providerID: "claude", provider: "Claude",
                                  model: "Opus", status: "Working")
    ]

    let summary = AIActivityProviderAggregation.summaries(for: sessions)[0]

    #expect(summary.contextUsed == nil)
    #expect(summary.contextWindow == nil)
}

// MARK: - Context window

@Test("an unstated Claude window starts at the standard tier")
func claudeWindowDefaultsToTheStandardTier() {
    #expect(AgentModelContextWindow.window(for: "claude-opus-5", source: .claude,
                                           observedUsed: 40_000) == 200_000)
}

@Test("occupancy past the standard tier promotes the Claude window, never pins the meter at 100%")
func claudeWindowPromotesOnObservedUsage() {
    // The reading from the reported screenshot: a session holding just over
    // 200k on a long-context tier used to render "200k / 200k · 100%" in red.
    let window = AgentModelContextWindow.window(for: "claude-opus-5", source: .claude,
                                                observedUsed: 214_000)

    #expect(window == 1_000_000)

    let state = AgentSessionState(id: "s", source: .claude, status: .working,
                                  contextUsed: 214_000, contextWindow: window)
    #expect(state.contextPercentageLabel == "21%")
    #expect(state.contextTone == .green)
}

@Test("a model id that names its own long-context tier is believed up front")
func modelIDDeclaringItsTierIsBelieved() {
    #expect(AgentModelContextWindow.window(for: "claude-opus-5[1m]", source: .claude,
                                           observedUsed: 10_000) == 1_000_000)
}

@Test("a window the CLI reported outranks the assumed tier")
func reportedWindowWins() {
    #expect(AgentModelContextWindow.window(reported: 258_400, model: "gpt-5.6-terra",
                                           source: .codex, observedUsed: 21_000) == 258_400)
}

@Test("even a reported window is promoted when the session outgrows it")
func reportedWindowIsStillAFloor() {
    #expect(AgentModelContextWindow.window(reported: 200_000, model: "gpt-5.6-terra",
                                           source: .codex, observedUsed: 300_000) == 400_000)
}

@Test("usage beyond every known tier reports itself rather than a full meter")
func usageBeyondEveryTierReportsItself() {
    let window = AgentModelContextWindow.window(for: "claude-opus-5", source: .claude,
                                                observedUsed: 1_400_000)

    #expect(window == 1_400_000)
}

@Test("a session with no reported window never renders as full")
func missingWindowNeverRendersFull() {
    let state = AgentSessionState(id: "s", source: .claude, status: .working,
                                  contextUsed: 900_000, contextWindow: nil)

    #expect(state.contextLimit == 900_000)
    #expect(state.contextProgress == 1)

    let small = AgentSessionState(id: "s", source: .claude, status: .working,
                                  contextUsed: 20_000, contextWindow: nil)
    #expect(small.contextLimit == 200_000)
    #expect(small.contextPercentageLabel == "10%")
}

// MARK: - Plan summary

private func exitPlanMode(_ plan: String) -> [String: Any] {
    ["type": "assistant", "sessionId": "s1",
     "message": ["role": "assistant",
                 "content": [["type": "tool_use", "name": "ExitPlanMode",
                              "id": "toolu_plan", "input": ["plan": plan]]]]]
}

@Test("a presented plan is read from the ExitPlanMode call")
func planSummaryComesFromExitPlanMode() {
    let entries = claudeEntries([permissionMode("plan"),
                                 exitPlanMode("## Plan\n\n1. Fix the scanner\n2. Add tests")])

    #expect(ClaudeTranscriptStatus.planSummary(in: entries) == "Plan Fix the scanner Add tests")
}

@Test("the newest plan wins when a session replanned")
func newestPlanWins() {
    let entries = claudeEntries([exitPlanMode("First attempt"),
                                 userPrompt("try again"),
                                 exitPlanMode("Second attempt")])

    #expect(ClaudeTranscriptStatus.planSummary(in: entries) == "Second attempt")
}

@Test("a transcript with no plan reports none")
func noPlanReportsNil() {
    #expect(ClaudeTranscriptStatus.planSummary(in: claudeEntries([userPrompt("hi"), assistant()])) == nil)
}

@Test("a long plan is capped rather than flooding the row")
func longPlanIsCapped() {
    let plan = String(repeating: "step and more detail ", count: 60)
    let summary = ClaudeTranscriptStatus.planSummary(in: claudeEntries([exitPlanMode(plan)]))

    #expect(summary?.count == 221)          // 220 + the ellipsis
    #expect(summary?.hasSuffix("…") == true)
}

@Test("a plan that is only markdown scaffolding reports none")
func emptyScaffoldingPlanReportsNil() {
    #expect(ClaudeTranscriptStatus.condense("###\n\n- \n\n* ") == nil)
}

@Test("a session carries its plan summary onto the card")
func sessionStateCarriesThePlanSummary() {
    let state = AgentSessionState(id: "s", source: .claude, status: .planReady,
                                  planSummary: "Fix the scanner")

    #expect(state.planSummary == "Fix the scanner")
}

// MARK: - Codex session identity

/// The real shape of a spawned sub-agent's `session_meta` payload: `source` is a
/// nested object rather than a flag, and `session_id` holds the PARENT's id
/// while `id` holds this rollout's own.
private func codexSubagentMeta() -> [String: Any] {
    ["session_id": "parent-019ff608",
     "id": "child-01a01058",
     "parent_thread_id": "parent-019ff608",
     "thread_source": "subagent",
     "source": ["subagent": ["thread_spawn": ["parent_thread_id": "parent-019ff608",
                                              "depth": 1,
                                              "agent_nickname": "Dirac"]]]]
}

private func codexRootMeta(source: String = "cli") -> [String: Any] {
    ["session_id": "root-019ff608", "id": "root-019ff608",
     "thread_source": "user", "source": source]
}

@Test("a spawned Codex sub-agent is recognised as a child")
func codexSubagentIsRecognised() {
    // `source.subagent` is a dictionary, so reading it as a Bool — which the
    // scanner used to do — matched none of the 192 real rollouts on disk.
    let identity = CodexTranscriptStatus.identity(in: codexSubagentMeta())

    #expect(identity?.isSubagent == true)
    #expect(identity?.parentID == "parent-019ff608")
}

@Test("a Codex sub-agent keeps its own id, not its parent's")
func codexSubagentKeepsItsOwnID() {
    // Preferring `session_id` gave every concurrent sibling the parent's id,
    // which collides as a ForEach key in the roster.
    #expect(CodexTranscriptStatus.identity(in: codexSubagentMeta())?.id == "child-01a01058")
}

@Test("a user-started Codex session is not a child, whatever its source string")
func codexRootIsNotAChild() {
    for source in ["cli", "vscode", "exec"] {
        let identity = CodexTranscriptStatus.identity(in: codexRootMeta(source: source))
        #expect(identity?.isSubagent == false)
        #expect(identity?.parentID == nil)
        #expect(identity?.id == "root-019ff608")
    }
}

@Test("a sub-agent with only the nested parent link still joins its parent")
func codexNestedParentLinkIsEnough() {
    var meta = codexSubagentMeta()
    meta.removeValue(forKey: "parent_thread_id")
    meta.removeValue(forKey: "thread_source")

    let identity = CodexTranscriptStatus.identity(in: meta)
    #expect(identity?.isSubagent == true)
    #expect(identity?.parentID == "parent-019ff608")
}

@Test("a rollout with no identity at all is skipped")
func codexMetaWithoutAnIDIsSkipped() {
    #expect(CodexTranscriptStatus.identity(in: ["source": "cli"]) == nil)
}

@Test("a recognised hierarchy counts sub-agents against their root")
func codexHierarchyCountsSubagents() {
    // The end-to-end consequence: with `isSubagent` always false the hierarchy
    // stayed empty, so the badge never appeared and approvals never grouped.
    let children = [codexSubagentMeta()].compactMap { CodexTranscriptStatus.identity(in: $0) }
    let hierarchy = CodexSessionHierarchy(parentBySessionID: Dictionary(
        uniqueKeysWithValues: children.compactMap { identity in
            identity.parentID.map { (identity.id, $0) }
        }))

    #expect(hierarchy.subagentCount(for: "parent-019ff608") == 1)
    #expect(hierarchy.rootSessionID(for: "child-01a01058") == "parent-019ff608")
}

// MARK: - An open session is not a working session

private func localCommand(_ text: String) -> [String: Any] {
    ["type": "user", "sessionId": "s1", "message": ["role": "user", "content": text]]
}

@Test("running a local slash command leaves an idle session settled, not Working")
func localCommandOutputIsNotAPrompt() {
    // `/model` appends these two records and touches the file. Read as prompts,
    // they made an idle session look like it owed an answer to something that
    // was never a question.
    let entries = claudeEntries([
        userPrompt("do the thing"), assistant(), turnEnded(),
        localCommand("<command-name>/model</command-name><command-message>model</command-message>"),
        localCommand("<local-command-stdout>Set model to Opus 5</local-command-stdout>")
    ])

    #expect(ClaudeTranscriptStatus.reading(in: entries).status == .done)
}

@Test("injected meta context is not a prompt either")
func injectedMetaIsNotAPrompt() {
    var meta = userPrompt("<system-reminder>background context</system-reminder>")
    meta["isMeta"] = true
    let entries = claudeEntries([assistant(), turnEnded(), meta])

    #expect(ClaudeTranscriptStatus.reading(in: entries).status == .done)
}

@Test("a real prompt after a local command still reads as Working")
func aRealPromptAfterChromeStillWorks() {
    let entries = claudeEntries([
        assistant(), turnEnded(),
        localCommand("<local-command-stdout>Set model to Opus 5</local-command-stdout>"),
        userPrompt("now do this")
    ])

    #expect(ClaudeTranscriptStatus.reading(in: entries).status == .working)
}

@Test("a turn that has gone silent past the stall window is no longer Working")
func aStalledTurnStopsClaimingToWork() {
    // Measured across 21,957 real mid-turn gaps: p99 is 125s. Silence past 180s
    // is a turn that died, not slow work.
    let entries = claudeEntries([userPrompt("go"), assistant(tools: ["Bash"])])

    #expect(ClaudeTranscriptStatus.reading(in: entries, inactiveFor: 5).status == .working)
    #expect(ClaudeTranscriptStatus.reading(in: entries, inactiveFor: 120).status == .working)
    #expect(ClaudeTranscriptStatus.reading(in: entries, inactiveFor: 181).status == .interrupted)
}

@Test("silence never overrides a turn that explicitly finished")
func silenceDoesNotRewriteAFinishedTurn() {
    let entries = claudeEntries([userPrompt("go"), assistant(), turnEnded()])

    #expect(ClaudeTranscriptStatus.reading(in: entries, inactiveFor: 9_000).status == .done)
}

@Test("a parsed Claude reading can be reused while its silence clock advances")
func cachedClaudeReadingStillExpires() {
    let reading = ClaudeTranscriptStatus.reading(in: claudeEntries([
        userPrompt("go"), assistant(tools: ["Bash"])
    ]))

    #expect(reading.resolved(inactiveFor: 5) == .working)
    #expect(reading.resolved(inactiveFor: 181) == .interrupted)
}

@Test("a stalled Codex turn stops claiming to work too")
func codexStalledTurnStopsClaimingToWork() {
    let entries = [codexTurn(), codexEvent("task_started")]

    #expect(CodexTranscriptStatus.reading(in: entries, inactiveFor: 60).status == .working)
    #expect(CodexTranscriptStatus.reading(in: entries, inactiveFor: 181).status == .interrupted)

    let finished = [codexTurn(), codexEvent("task_complete")]
    #expect(CodexTranscriptStatus.reading(in: finished, inactiveFor: 9_000).status == .done)
}

@Test("the stall window sits above real work and below the roster's own cutoff")
func stallWindowIsBoundedOnBothSides() {
    // Above the measured p99 mid-turn gap (125s) so slow work is not libelled,
    // and below the scanner's five-minute file window so the rule can still act.
    #expect(AgentSessionTerminal.stalledAfter > 125)
    #expect(AgentSessionTerminal.stalledAfter < 300)
}

// MARK: - Sub-agents are counted in the present tense

@Test("only sub-agents still running count toward the badge")
func onlyLiveSubagentsAreCounted() {
    let hierarchy = CodexSessionHierarchy(parentBySessionID: [
        "child-a": "root", "child-b": "root", "child-c": "root"
    ])

    // All six finished an hour ago: the badge must not say "3".
    #expect(hierarchy.activeSubagentCount(for: "root", activeIDs: []) == 0)
    #expect(hierarchy.activeSubagentCount(for: "root", activeIDs: ["child-b"]) == 1)
    #expect(hierarchy.activeSubagentCount(for: "root", activeIDs: ["child-a", "child-c"]) == 2)
    // The hierarchy itself still knows all three, so a finished child's approval
    // continues to route to its parent.
    #expect(hierarchy.subagentCount(for: "root") == 3)
}

@Test("a settled session yields no badge at all")
func settledSessionsHaveNoBadge() {
    for status in [AgentSessionStatus.done, .planReady, .interrupted] {
        #expect(status.isSettled)
    }
    for status in [AgentSessionStatus.working, .planning, .needsYou, .question] {
        #expect(!status.isSettled)
    }
    #expect(AgentSessionState(id: "s", source: .codex, status: .working,
                              subagentCount: 0).subagentBadge == nil)
}
