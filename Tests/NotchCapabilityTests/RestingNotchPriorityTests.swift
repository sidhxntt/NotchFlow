import Testing
@testable import NotchCapabilities

// These tests are the enforcement of `order.md`. If the document and the ladder
// ever disagree, one of these fails.

/// Every slot active at once. Whatever wins is the top of the ladder, and
/// removing the winner must reveal exactly the next rank down — which walks the
/// entire order in one pass rather than asserting pairs and hoping the
/// transitive closure holds.
private func allActive() -> RestingNotchInputs {
    RestingNotchInputs(panelOpen: false, liveActivityEnabled: true,
                       notifications: true, agentQuestion: true,
                       agentAnnouncement: true, backgroundWork: true,
                       accessoryEvent: true, focusTransition: true,
                       agentSteady: true, nowPlaying: true, clipboardSense: true)
}

private func deactivate(_ slot: RestingNotchSlot, in inputs: inout RestingNotchInputs) {
    switch slot {
    case .notifications:     inputs.notifications = false
    case .agentQuestion:     inputs.agentQuestion = false
    case .agentAnnouncement: inputs.agentAnnouncement = false
    case .work:              inputs.backgroundWork = false
    case .accessory:         inputs.accessoryEvent = false
    case .focusTransition:   inputs.focusTransition = false
    case .agentSteady:       inputs.agentSteady = false
    case .nowPlaying:        inputs.nowPlaying = false
    case .clipboardSense:    inputs.clipboardSense = false
    case .none:              break
    }
}

@Test("the ladder resolves in exactly the order order.md specifies")
func ladderMatchesTheSpecifiedOrder() {
    let expected: [RestingNotchSlot] = [
        .notifications, .agentQuestion, .agentAnnouncement, .work,
        .accessory, .focusTransition, .agentSteady, .nowPlaying, .clipboardSense
    ]

    var inputs = allActive()
    for rank in expected {
        #expect(RestingNotchPriority.slot(for: inputs) == rank)
        deactivate(rank, in: &inputs)
    }
    #expect(RestingNotchPriority.slot(for: inputs) == .none)
}

@Test("the ranks are numbered as order.md numbers them")
func ranksAreNumberedAsDocumented() {
    #expect(RestingNotchSlot.notifications.rawValue == 1)
    #expect(RestingNotchSlot.agentQuestion.rawValue == 2)
    #expect(RestingNotchSlot.agentAnnouncement.rawValue == 3)
    #expect(RestingNotchSlot.work.rawValue == 4)
    #expect(RestingNotchSlot.accessory.rawValue == 5)
    #expect(RestingNotchSlot.focusTransition.rawValue == 6)
    #expect(RestingNotchSlot.agentSteady.rawValue == 7)
    #expect(RestingNotchSlot.nowPlaying.rawValue == 8)
    #expect(RestingNotchSlot.clipboardSense.rawValue == 9)
}

// MARK: - R1, blocked beats busy

@Test("a question outranks work in flight")
func questionOutranksWork() {
    // The regression this exists to catch: work in flight means something is
    // progressing and needs nothing; a question means the agent has stopped.
    // The old ladder had this the other way round.
    let inputs = RestingNotchInputs(agentQuestion: true, backgroundWork: true)

    #expect(RestingNotchPriority.slot(for: inputs) == .agentQuestion)
}

// MARK: - R2, ephemeral beats persistent

@Test("a state-change announcement outranks work, and the steady state does not")
func announcementAndSteadyStateSitEitherSideOfWork() {
    #expect(RestingNotchPriority.slot(for: .init(agentAnnouncement: true, backgroundWork: true))
            == .agentAnnouncement)
    #expect(RestingNotchPriority.slot(for: .init(backgroundWork: true, agentSteady: true))
            == .work)
}

@Test("a long agent run yields to the short announcements it used to blank out")
func steadyAgentWorkYieldsToShortAnnouncements() {
    // The old single `agentState` slot sat at rank 4 and held the shoulders for
    // the whole run, suppressing all three of these until it finished.
    #expect(RestingNotchPriority.slot(for: .init(accessoryEvent: true, agentSteady: true))
            == .accessory)
    #expect(RestingNotchPriority.slot(for: .init(focusTransition: true, agentSteady: true))
            == .focusTransition)
    #expect(RestingNotchPriority.slot(for: .init(agentSteady: true, nowPlaying: true))
            == .agentSteady)
}

@Test("a notification takes the normal preview shoulders while work is active")
func notificationReplacesWorkingAndPlanning() {
    #expect(RestingNotchPriority.slot(for: .init(notifications: true, backgroundWork: true))
            == .notifications)
    #expect(RestingNotchPriority.slot(for: .init(notifications: true, agentSteady: true))
            == .notifications)
}

@Test("the steady state resumes once the announcement above it clears")
func steadyStateResumesAfterTheAnnouncement() {
    var inputs = RestingNotchInputs(accessoryEvent: true, agentSteady: true)
    #expect(RestingNotchPriority.slot(for: inputs) == .accessory)

    inputs.accessoryEvent = false
    #expect(RestingNotchPriority.slot(for: inputs) == .agentSteady)
}

// MARK: - R4 and the fallback

@Test("a clipboard offer never displaces information")
func clipboardOfferRanksLast() {
    #expect(RestingNotchPriority.slot(for: .init(nowPlaying: true, clipboardSense: true))
            == .nowPlaying)
    #expect(RestingNotchPriority.slot(for: .init(clipboardSense: true)) == .clipboardSense)
}

@Test("an open panel shows nothing in the resting notch")
func openPanelSuppressesEverything() {
    var inputs = allActive()
    inputs.panelOpen = true

    #expect(RestingNotchPriority.slot(for: inputs) == .none)
}

@Test("nothing active resolves to none")
func nothingActiveResolvesToNone() {
    #expect(RestingNotchPriority.slot(for: .init()) == .none)
}

// MARK: - Live activity

@Test("Live activity off mutes every collapsed-notch preview")
func liveActivityMutesEveryPreview() {
    for slot in RestingNotchSlot.allCases where slot != .none {
        #expect(RestingNotchPriority.isMuted(slot, liveActivityEnabled: false))
    }
    #expect(!RestingNotchPriority.isMuted(.none, liveActivityEnabled: false))
}

@Test("Live activity on mutes nothing")
func liveActivityOnMutesNothing() {
    for slot in RestingNotchSlot.allCases {
        #expect(!RestingNotchPriority.isMuted(slot, liveActivityEnabled: true))
    }
}

@Test("Live activity off leaves the collapsed notch blank")
func mutedSlotsDoNotFallThroughToAnotherPreview() {
    var inputs = allActive()
    inputs.liveActivityEnabled = false

    #expect(RestingNotchPriority.slot(for: inputs) == .none)
}
