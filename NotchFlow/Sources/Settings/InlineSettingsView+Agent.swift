import AppKit
import ApplicationServices
import CoreLocation
import Carbon.HIToolbox
import Carbon.OpenScripting
import EventKit
import SwiftUI
import UserNotifications

@MainActor
extension InlineSettingsView {
    // MARK: - Agent

    /// The Agent category used to be a keyboard reference and nothing else — a
    /// first-class page that could not change a single thing about how agent runs
    /// behave. These are the knobs the agent surface actually reads: what a run is
    /// armed with, and the three timings the roster judges sessions by. All four
    /// existed already; none of them had a control.
    var agentSettingsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Runner")
                .captionLabel()
            agentEngineRow
            agentModelRow
            agentEffortRow
            Text("Sessions")
                .captionLabel()
                .padding(.top, 2)
            agentPermissionDelayRow
            agentStalledAfterRow
            agentSessionWindowRow
            agentSubagentBadgeRow
        }
    }

    /// Which CLI an armed task runs on. The compose row's model chip sets this as
    /// a side effect of picking a model; this is the direct statement of it, and
    /// the only place an engine can be armed without composing a task first.
    private var agentEngineRow: some View {
        settingRow(label: "Engine",
                   info: "Which agent CLI a new task runs on. Only installed, signed-in CLIs can be armed.",
                   aligned: true) {
            GlassMenu(title: model.agentArmedEngine.displayName) {
                ForEach(AgentEngine.offered, id: \.self) { engine in
                    Button {
                        selectAgentEngine(engine)
                    } label: {
                        menuOption(engine.isKnownUnavailable
                                       ? "\(engine.displayName) — not installed"
                                       : engine.displayName,
                                   selected: engine == model.agentArmedEngine)
                    }
                    .disabled(engine.isKnownUnavailable)
                }
            }
        }
    }

    /// The armed run's model. Listed from the engine's own catalog — never a
    /// hardcoded ladder — so a retired id can't be armed here (see
    /// `AgentEngine.modelChoices`).
    private var agentModelRow: some View {
        let choices = model.agentArmedEngine.modelChoices
        let current = choices.first { $0.id == model.agentModelID }
        return settingRow(label: "Model",
                          info: "The model an armed task runs on. Read from the CLI's own catalog.",
                          aligned: true) {
            GlassMenu(title: current?.label ?? "\(model.agentArmedEngine.displayName) default") {
                ForEach(choices, id: \.self) { choice in
                    Button { model.selectAgentModel(choice) } label: {
                        menuOption(choice.label, selected: choice.id == model.agentModelID)
                    }
                }
            }
        }
    }

    /// Reasoning effort, offered only where the engine+model pair actually takes
    /// one. An engine with no adjustable effort gets a plain caption instead of a
    /// menu naming a dial that isn't connected to anything.
    @ViewBuilder
    private var agentEffortRow: some View {
        let choices = model.agentArmedEngine.effortChoices(forModelID: model.agentModelID)
        settingRow(label: "Reasoning",
                   info: "How hard the model thinks. Only the levels this engine and model accept are listed.",
                   aligned: true) {
            if choices.isEmpty {
                Text("Not adjustable for this model")
                    .font(.sf(12))
                    .foregroundStyle(Tokens.text3)
            } else {
                GlassMenu(title: model.agentEffort.map(Self.effortLabel) ?? "CLI default") {
                    Button { model.agentEffort = nil } label: {
                        menuOption("CLI default", selected: model.agentEffort == nil)
                    }
                    ForEach(choices, id: \.self) { effort in
                        Button { model.agentEffort = effort } label: {
                            menuOption(Self.effortLabel(effort), selected: model.agentEffort == effort)
                        }
                    }
                }
            }
        }
    }

    /// How long an unresolved state-changing tool call waits before the notch
    /// reads it as a permission prompt. Read-only work never raises a cue at any
    /// setting — the eligible-tool list, not this timer, is what decides that.
    private var agentPermissionDelayRow: some View {
        settingRow(label: "Approval cue after",
                   info: "How long a tool call that changes state may sit unresolved before the notch offers the terminal handoff.",
                   aligned: true,
                   forceStacked: true) {
            GlassMenu(title: Self.durationLabel(permissionDelay)) {
                ForEach(AgentPermissionPolicy.delayChoices, id: \.self) { seconds in
                    Button {
                        permissionDelay = seconds
                        AgentPermissionPolicy.delay = seconds
                    } label: {
                        menuOption(Self.durationLabel(seconds), selected: seconds == permissionDelay)
                    }
                }
            }
        }
    }

    /// When a silent turn stops being believed. Raise it for work that runs long
    /// single tools; lower it to see abandoned turns marked sooner.
    private var agentStalledAfterRow: some View {
        settingRow(label: "Mark stalled after",
                   info: "A turn that has written nothing for this long is reported as interrupted rather than working.",
                   aligned: true,
                   forceStacked: true) {
            GlassMenu(title: Self.durationLabel(stalledAfter)) {
                ForEach(AgentSessionTerminal.stalledAfterChoices, id: \.self) { seconds in
                    Button {
                        stalledAfter = seconds
                        AgentSessionTerminal.stalledAfter = seconds
                    } label: {
                        menuOption(Self.durationLabel(seconds), selected: seconds == stalledAfter)
                    }
                }
            }
        }
    }

    /// How far back the transcript scan reaches. This is the cold-start cost dial:
    /// a shorter window is less to read on first launch, a longer one is the only
    /// way a session left open for days stays visible.
    private var agentSessionWindowRow: some View {
        settingRow(label: "Session history",
                   info: "How recently a transcript must have been written to put its session in the roster. Shorter windows make a cold start cheaper.",
                   aligned: true,
                   forceStacked: true) {
            GlassMenu(title: Self.durationLabel(sessionWindow)) {
                ForEach(AgentSessionObservation.activeFileWindowChoices, id: \.self) { seconds in
                    Button {
                        sessionWindow = seconds
                        AgentSessionObservation.activeFileWindow = seconds
                    } label: {
                        menuOption(Self.durationLabel(seconds), selected: seconds == sessionWindow)
                    }
                }
            }
        }
    }

    private var agentSubagentBadgeRow: some View {
        settingRow(label: "Sub-agent counts",
                   info: "Show how many sub-agents a session has running. A wide fan-out fills the roster with badges.",
                   aligned: true,
                   forceStacked: true) {
            Toggle("", isOn: Binding(
                get: { showsSubagents },
                set: {
                    Haptics.levelChange()
                    showsSubagents = $0
                    AgentDisplayPolicy.showsSubagents = $0
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(Tokens.text2)
        }
    }

    private func selectAgentEngine(_ engine: AgentEngine) {
        guard engine != model.agentArmedEngine else { return }
        // Go through the same path the compose row's chip uses, so the model and
        // effort are re-clamped to what the new engine accepts. Arming an engine
        // while keeping the old engine's model id is how a run gets refused
        // outright (see `AgentEffortCatalog`).
        let choice = engine.modelChoices.first
            ?? AgentModelChoice(engine: engine, id: nil, label: engine.displayName)
        model.selectAgentModel(choice)
    }

    private static func effortLabel(_ effort: AgentEffort) -> String {
        switch effort {
        case .low:    return "Low"
        case .medium: return "Medium"
        case .high:   return "High"
        case .xhigh:  return "Extra high"
        case .max:    return "Max"
        case .ultra:  return "Ultra"
        }
    }

    /// Whole units only — every choice these menus offer is a round number of
    /// seconds, minutes, hours, or days, so nothing here has to render a fraction.
    private static func durationLabel(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 60 * 60 {
            let minutes = total / 60
            return minutes == 1 ? "1 minute" : "\(minutes) minutes"
        }
        if total < 24 * 60 * 60 {
            let hours = total / 3600
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }
        let days = total / (24 * 60 * 60)
        return days == 1 ? "1 day" : "\(days) days"
    }
    // MARK: - Copy sensing

    /// Copy sensing: whether the *closed* notch watches ⌘C and offers to file a
    /// copied note/reminder (press ⌘C again to confirm). The prose ("press ⌘C
    /// again to confirm") lives in the ⓘ beside the title.
    var copySenseRow: some View {
        settingRow(label: L("general.copySense"), info: L("general.copySense.hint")) {
            Toggle("", isOn: Binding(
                get: { model.copySenseEnabled },
                set: { Haptics.levelChange(); model.copySenseEnabled = $0 }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(Tokens.text2)
        }
    }

    /// Clipboard history is deliberately separate from copy sensing: sensing
    /// proposes a note/reminder, while history locally retains an item for the
    /// user to restore later from Utilities.
    var clipboardHistoryRow: some View {
        settingRow(label: "Clipboard history", info: "Save copied text, files, and images locally. Nothing is uploaded.") {
            Toggle("", isOn: Binding(
                get: { clipboardHistory.isEnabled },
                set: { Haptics.levelChange(); clipboardHistory.isEnabled = $0 }
            ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Tokens.text2)
        }
    }
}
