import Foundation
import Testing
@testable import NotchCapabilities

@Test("hiding a project removes only its AI activity row")
func hidingAProjectRemovesOnlyThatActivityRow() {
    var visibility = AIActivityProjectVisibility()
    visibility.hide("NotchFlow")

    #expect(visibility.visible(["NotchFlow", "DevXp"]) == ["DevXp"])
}

@Test("hidden AI activity projects can be restored individually or all at once")
func hiddenAIActivityProjectsCanBeRestored() {
    var visibility = AIActivityProjectVisibility()
    visibility.hide("NotchFlow")
    visibility.hide("DevXp")

    visibility.show("NotchFlow")
    #expect(visibility.visible(["NotchFlow", "DevXp"]) == ["NotchFlow"])
    #expect(visibility.hiddenCount == 1)

    visibility.reset()
    #expect(visibility.visible(["NotchFlow", "DevXp"]) == ["NotchFlow", "DevXp"])
    #expect(visibility.hiddenCount == 0)
}

@Test("external-session activity matches its displayed project bucket")
func externalSessionActivityUsesItsCanonicalProjectKey() {
    #expect(AIActivityProject.display(nil) == AIActivityProject.externalSessions)
    #expect(AIActivityProject.matches(eventProject: nil,
                                      displayedProject: AIActivityProject.externalSessions))
    #expect(!AIActivityProject.matches(eventProject: "Project A",
                                       displayedProject: AIActivityProject.externalSessions))
    #expect(AIActivityProject.matches(eventProject: "Project A", displayedProject: nil))
}

@Test("completed planning uses the compact Done label")
func completedPlanningUsesDoneLabel() {
    #expect(AgentSessionStatus.planReady.previewLabel == "Done")
    #expect(AgentSessionStatus.planReady.previewTone == .amber)
}

@Test("a new working marker replaces planning done")
func workingSupersedesPlanningDone() {
    var state = AgentSessionState(
        id: "session-1",
        source: .codex,
        status: .planReady
    )

    state.apply(status: .working)

    #expect(state.status == .working)
}

@Test("a generic done marker does not replace planning done")
func doneDoesNotSupersedePlanningDone() {
    var state = AgentSessionState(
        id: "session-1",
        source: .codex,
        status: .planReady
    )

    state.apply(status: .done)

    #expect(state.status == .planReady)
}

@Test("a completed planning turn becomes planning done")
func completedPlanningTurnBecomesPlanningDone() {
    var state = AgentSessionState(
        id: "session-1",
        source: .codex,
        status: .planning
    )

    state.apply(status: .done)

    #expect(state.status == .planReady)
}

@Test("session state exposes the root project label")
func sessionStateUsesRootProjectLabel() {
    let state = AgentSessionState(
        id: "session-1",
        source: .codex,
        status: .working,
        projectName: "NotchFlow"
    )

    #expect(state.projectName == "NotchFlow")
}

@Test("a terminal Codex approval joins the sole live root in its workspace")
func terminalCodexApprovalJoinsItsWorkspaceRoot() {
    let approval = AgentApproval(
        id: "permission-1",
        threadID: "hook-thread",
        itemID: "command",
        title: "Run command",
        workingDirectory: "/work/NotchFlow",
        source: .codex
    )
    let liveRoot = AgentSessionState(
        id: "transcript-root",
        source: .codex,
        status: .working,
        workingDirectory: "/work/NotchFlow"
    )

    #expect(AgentSessionWorkspaceMatcher.rootID(for: approval, among: [liveRoot]) == "transcript-root")
}

@Test("a Claude marker joins the sole live session in its workspace")
func claudeMarkerJoinsItsWorkspaceSession() {
    let marker = AgentApproval(
        id: "marker-1",
        threadID: "hook-session",
        itemID: "marker",
        title: "Working",
        workingDirectory: "/work/NotchFlow",
        source: .claude
    )
    let liveSession = AgentSessionState(
        id: "transcript-session",
        source: .claude,
        status: .working,
        contextUsed: 88_000,
        contextWindow: 200_000,
        workingDirectory: "/work/NotchFlow"
    )

    #expect(AgentSessionWorkspaceMatcher.rootID(for: marker, among: [liveSession]) == "transcript-session")
}

@Test("a terminal Codex approval stays independent when its workspace has multiple live roots")
func terminalCodexApprovalDoesNotMergeConcurrentWorkspaceRoots() {
    let approval = AgentApproval(
        id: "permission-1",
        threadID: "hook-thread",
        itemID: "command",
        title: "Run command",
        workingDirectory: "/work/NotchFlow",
        source: .codex
    )
    let roots = [
        AgentSessionState(id: "root-a", source: .codex, status: .working, workingDirectory: "/work/NotchFlow"),
        AgentSessionState(id: "root-b", source: .codex, status: .planning, workingDirectory: "/work/NotchFlow")
    ]

    #expect(AgentSessionWorkspaceMatcher.rootID(for: approval, among: roots) == "hook-thread")
}

@Test("an ended root approval becomes a Closed marker on its root")
func endedRootApprovalBecomesClosedMarker() {
    let approval = AgentApproval(
        id: "permission-1",
        threadID: "root-thread",
        itemID: "command",
        title: "Run command",
        source: .codex,
        sessionGroupID: "root-thread"
    )

    let marker = AgentSessionMarker.transportEnded(for: approval)

    #expect(marker.sessionID == "root-thread")
    #expect(!marker.isSubagent)
    #expect(marker.status == .interrupted)
}

@Test("an ended sub-agent approval keeps its child identity")
func endedSubagentApprovalKeepsItsChildIdentity() {
    let approval = AgentApproval(
        id: "permission-child",
        threadID: "child-thread",
        itemID: "command",
        title: "Run command",
        source: .codex,
        sessionGroupID: "root-thread"
    )

    let marker = AgentSessionMarker.transportEnded(for: approval)

    // The card is grouped under `root-thread`, but the terminal event belongs
    // to `child-thread`. The activity store must therefore be able to reject
    // it rather than settling the root task.
    #expect(marker.sessionID == "child-thread")
    #expect(marker.isSubagent)
}

@Test("only a root completion marker may complete the Agent tab row")
func onlyRootCompletionMarkerMayCompleteTheAgentTabRow() {
    let hierarchy = CodexSessionHierarchy(parentBySessionID: ["child-thread": "root-thread"])
    let childDone = AgentSessionMarker(sessionID: "child-thread", source: .codex, status: .done)
    let rootDone = AgentSessionMarker(sessionID: "root-thread", source: .codex, status: .done)
    let groupedChildClosed = AgentSessionMarker(
        sessionID: "child-thread", source: .claude, status: .interrupted, isSubagent: true
    )

    #expect(!childDone.mayUpdateRootSession(
        hierarchyRoot: hierarchy.rootSessionID(for: childDone.sessionID)
    ))
    #expect(rootDone.mayUpdateRootSession(hierarchyRoot: "root-thread"))
    #expect(groupedChildClosed.mayUpdateRootSession(hierarchyRoot: "child-thread"))
}

@Test("an active sub-agent keeps a completed root session working")
func activeSubagentKeepsACompletedRootWorking() {
    #expect(AgentSessionStatus.aggregating(root: .done, children: [.working]) == .working)
    #expect(AgentSessionStatus.aggregating(root: .planReady, children: [.planning]) == .working)
}

@Test("a completed root is done after all sub-agents settle")
func completedRootIsDoneAfterAllSubagentsSettle() {
    #expect(AgentSessionStatus.aggregating(root: .done, children: [.done, .planReady]) == .done)
}

@Test("any interrupted agent interrupts the root session")
func anyInterruptedAgentInterruptsTheRootSession() {
    #expect(AgentSessionStatus.aggregating(root: .working, children: [.done, .interrupted]) == .interrupted)
    #expect(AgentSessionStatus.aggregating(root: .interrupted, children: [.done]) == .interrupted)
}

@Test("an interruption overrides a live root session marker")
func interruptionOverridesALiveRootSessionMarker() {
    var state = AgentSessionState(id: "root", source: .codex, status: .working)

    state.apply(status: .interrupted)

    #expect(state.status == .interrupted)
}

@Test("a timely done marker settles a working session")
func timelyDoneMarkerSettlesAWorkingSession() {
    // The CLI's own idle marker has to be able to land, or a session that has
    // gone quiet reads Working until the marker ages out. Whether a marker is
    // still timely is decided by the store against the last scan — see
    // `isTranscriptObservable` — not by this function.
    var state = AgentSessionState(
        id: "session-1",
        source: .codex,
        status: .working
    )

    state.apply(status: .done)

    #expect(state.status == .done)
}

@Test("only states a transcript records can be superseded by a later scan")
func onlyTranscriptRecordedStatesAreSupersededByAScan() {
    // A pending permission and a question exist nowhere in the session log, so
    // no scan can refute them; every other state is written down and a later
    // scan is the better witness.
    #expect(AgentSessionStatus.working.isTranscriptObservable)
    #expect(AgentSessionStatus.planning.isTranscriptObservable)
    #expect(AgentSessionStatus.planReady.isTranscriptObservable)
    #expect(AgentSessionStatus.done.isTranscriptObservable)
    #expect(AgentSessionStatus.interrupted.isTranscriptObservable)
    #expect(!AgentSessionStatus.needsYou.isTranscriptObservable)
    #expect(!AgentSessionStatus.question.isTranscriptObservable)
}

@Test("a stale working marker does not replace a completed session")
func staleWorkingMarkerDoesNotReplaceCompletedSession() {
    var state = AgentSessionState(
        id: "session-1",
        source: .codex,
        status: .done
    )

    state.apply(status: .working)

    #expect(state.status == .done)
}

@Test("a stale working marker does not reopen a closed session")
func staleWorkingMarkerDoesNotReopenClosedSession() {
    var state = AgentSessionState(
        id: "session-1",
        source: .codex,
        status: .interrupted
    )

    state.apply(status: .working)

    #expect(state.status == .interrupted)
}

@Test("an interrupted terminal event is distinct from a completed turn")
func interruptedTerminalEventUsesInterruptedStatus() {
    #expect(AgentSessionStatus.working.resolved(terminal: .interrupted) == .interrupted)
    #expect(AgentSessionStatus.planning.resolved(terminal: .completed) == .planReady)
    #expect(AgentSessionStatus.interrupted.previewLabel == "Closed")
}

@Test("an inactive turn remains open until an explicit abort or completion")
func inactiveTurnNeedsAnExplicitTerminalEvent() {
    #expect(AgentSessionTerminal.inferred(completed: false, aborted: false, inactiveFor: 34.9) == nil)
    #expect(AgentSessionTerminal.inferred(completed: false, aborted: false, inactiveFor: 35) == nil)
    #expect(AgentSessionTerminal.inferred(completed: false, aborted: true, inactiveFor: 0) == .interrupted)
    #expect(AgentSessionTerminal.inferred(completed: true, aborted: false, inactiveFor: 35) == .completed)
}

@Test("a quiet long-running transcript remains observable")
func longRunningTranscriptRetentionExceedsTheOldFiveMinuteCutoff() {
    let now = Date(timeIntervalSinceReferenceDate: 10_000_000)

    #expect(AgentSessionObservation.isWithinActiveWindow(now.addingTimeInterval(-6 * 60), now: now))
    #expect(AgentSessionObservation.isWithinActiveWindow(now.addingTimeInterval(-23 * 60 * 60), now: now))
    #expect(!AgentSessionObservation.isWithinActiveWindow(now.addingTimeInterval(-25 * 60 * 60), now: now))
}

@Test("a future transcript date is not treated as indefinitely active")
func futureTranscriptDateIsNotActive() {
    let now = Date(timeIntervalSinceReferenceDate: 10_000_000)

    #expect(!AgentSessionObservation.isWithinActiveWindow(now.addingTimeInterval(60), now: now))
}

@Test("only completed and Closed session cards are clearable")
func onlyCompletedAndClosedSessionCardsAreClearable() {
    #expect(AgentSessionStatus.done.isClearable)
    #expect(AgentSessionStatus.planReady.isClearable)
    #expect(AgentSessionStatus.interrupted.isClearable)
    #expect(!AgentSessionStatus.working.isClearable)
    #expect(!AgentSessionStatus.needsYou.isClearable)
}
