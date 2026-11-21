import SwiftUI
import AppKit

@MainActor
extension NotchBody {
    @ViewBuilder
    var agentApprovalWorkspace: some View {
        // Both agents' pending sessions share one roster. A direct permission is
        // the top-priority row, local Agent runs come next, and passive external
        // sessions complete the picture without competing for attention.
        let codexQueues = codexApprovals.sessionQueues
        let claudeQueues = claudeApprovals.sessionQueues
        let terminalCodexQueues = terminalCodexApprovals.sessionQueues
        let approvalIDs = Set((codexQueues + claudeQueues + terminalCodexQueues).map {
            "\($0.current.source.rawValue):\($0.threadID)"
        })
        let tasks = Array(agentManager.tasks.reversed())
        // A locally launched task becomes visible in the external CLI scanner as
        // soon as its session id is reported. Keep its richer task row as the
        // one roster entry instead of showing it twice.
        let managedSessionIDs = Set(tasks.compactMap { task -> String? in
            guard let sessionID = task.sessionID else { return nil }
            switch task.engine {
            case .codex: return "codex:\(sessionID)"
            case .claude: return "claude:\(sessionID)"
            case .grok, .commandCode, .pi: return nil
            }
        })
        // The surrounding ScrollView owns density. A cap here made a busy
        // machine indistinguishable from one where discovery silently missed
        // sessions, exactly when the Agent tab needs to be most trustworthy.
        let statusSessions = agentSessions.sessions.filter {
            let key = "\($0.source.rawValue):\($0.id)"
            return !approvalIDs.contains(key) && !managedSessionIDs.contains(key)
        }
        let visibleCount = codexQueues.count + claudeQueues.count + terminalCodexQueues.count
            + tasks.count + statusSessions.count
        let bridgeError = terminalCodexApprovals.lastError ?? claudeApprovals.lastError
        let discoveryMessage = agentSessions.discoveryMessage
        let hookConfigurationMessage = terminalCodexApprovals.hookConfigurationMessage

        if visibleCount > 0 {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    agentWorkspaceHeader(count: visibleCount)

                    if let bridgeError {
                        Label(bridgeError, systemImage: "exclamationmark.triangle.fill")
                            .font(.sf(10.5, weight: .medium))
                            .foregroundStyle(Color.orange)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 6)
                            .accessibilityLabel("Agent approval bridge error: \(bridgeError)")
                    }
                    if let discoveryMessage {
                        Label(discoveryMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.sf(10.5, weight: .medium))
                            .foregroundStyle(Color.orange)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 6)
                            .accessibilityLabel("Agent transcript diagnostic: \(discoveryMessage)")
                    }
                    if let hookConfigurationMessage {
                        hookConfigurationNotice(hookConfigurationMessage)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(codexQueues.enumerated()), id: \.element.id) { index, queue in
                                agentPermissionCard(queue, identifier: index + 1, session: sessionState(for: queue)) { decision, approval in
                                    codexApprovals.decide(decision == .approve ? .approve : .deny, for: approval)
                                }
                            }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(terminalCodexQueues.enumerated()), id: \.element.id) { index, queue in
                                agentPermissionCard(queue, identifier: codexQueues.count + index + 1, session: sessionState(for: queue)) { decision, approval in
                                    terminalCodexApprovals.decide(decision == .approve ? .approve : .deny, for: approval)
                                }
                            }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(claudeQueues.enumerated()), id: \.element.id) { index, queue in
                                agentPermissionCard(queue, identifier: codexQueues.count + terminalCodexQueues.count + index + 1, session: sessionState(for: queue)) { decision, approval in
                                    claudeApprovals.decide(decision == .approve ? .approve : .deny, for: approval)
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                                agentWorkspaceTaskRow(task, identifier: codexQueues.count + terminalCodexQueues.count + claudeQueues.count + index + 1)
                                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(statusSessions.enumerated()), id: \.element.id) { index, session in
                                agentSessionStatusCard(session, identifier: codexQueues.count + terminalCodexQueues.count + claudeQueues.count + tasks.count + index + 1)
                                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: visibleCount > 3 ? 238 : nil)
            .padding(.top, 8)
            .fixedSize(horizontal: false, vertical: true)
            // Workspace tabs dissolve between surfaces; the Agent roster should
            // not use the top-edge movement reserved for inline modules.
            .transition(.opacity)
        } else {
            // An empty machine is a valid cold-start state, not an absent
            // workspace. Naming it keeps a zero-row Agent tab from reading as
            // a failed scan when the user has not installed either CLI yet.
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.sf(11, weight: .semibold))
                    .foregroundStyle(Tokens.text3)
                Text("No active agent sessions")
                    .font(.sf(11.5, weight: .medium))
                    .foregroundStyle(Tokens.text2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("No active agent sessions")
            if let bridgeError {
                Label(bridgeError, systemImage: "exclamationmark.triangle.fill")
                    .font(.sf(10.5, weight: .medium))
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .accessibilityLabel("Agent approval bridge error: \(bridgeError)")
            }
            if let discoveryMessage {
                Label(discoveryMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.sf(10.5, weight: .medium))
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .accessibilityLabel("Agent transcript diagnostic: \(discoveryMessage)")
            }
            if let hookConfigurationMessage {
                hookConfigurationNotice(hookConfigurationMessage)
            }
        }
    }

    private func hookConfigurationNotice(_ message: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button(terminalCodexApprovals.canRepairHookConfiguration ? "Repair" : "Reveal") {
                if terminalCodexApprovals.canRepairHookConfiguration {
                    terminalCodexApprovals.repairGlobalHookConfiguration()
                } else {
                    terminalCodexApprovals.revealGlobalHookConfiguration()
                }
            }
            .buttonStyle(.plain)
            .font(.sf(10, weight: .semibold))
            .foregroundStyle(Tokens.text1)
        }
        .font(.sf(10.5, weight: .medium))
        .foregroundStyle(Color.orange)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Agent hook configuration: \(message)")
    }

    private func agentWorkspaceHeader(count: Int) -> some View {
        HStack(spacing: 8) {
            Text("\(count)")
                .font(.sf(20, weight: .semibold).monospacedDigit())
                .foregroundStyle(Tokens.text1)
            Image(systemName: "terminal")
                .font(.sf(11, weight: .semibold))
                .foregroundStyle(Tokens.text3)
                .frame(width: 20, height: 20)
                .overlay(Circle().stroke(Tokens.hairline, lineWidth: 1))

            Spacer(minLength: 8)

            Circle()
                .fill(agentManager.isRunning ? Color.green : Tokens.text4)
                .frame(width: 7, height: 7)
            Text(agentManager.isRunning ? "Agents working" : "Agent activity")
                .font(.sf(11.5, weight: .semibold))
                .foregroundStyle(Tokens.text2)

            Button {
                // The roster clear tidies completed work without touching a
                // session that can still be working or waiting for the user.
                withAnimation(.smooth(duration: 0.32)) {
                    agentManager.dismissCompleted()
                    agentSessions.clearCompletedSessions()
                    model.clearCompletedAgentHistory()
                }
            } label: {
                Image(systemName: "trash")
                    .font(.sf(10, weight: .semibold))
                    .foregroundStyle(Tokens.text3)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .disabled(!hasClearableAgentSessions)
            .opacity(hasClearableAgentSessions ? 1 : 0.35)
            .help("Clear agent history")
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(count) agent sessions")
    }

    private var hasClearableAgentSessions: Bool {
        agentSessions.sessions.contains { $0.status.isClearable }
            || agentManager.tasks.contains { $0.outcome == .success }
    }

    private func sessionState(for queue: AgentApprovalSessionQueue) -> AgentSessionState? {
        agentSessions.sessions.first {
            $0.id == queue.threadID && $0.source == queue.current.source
        }
    }

    /// Which way the card's two buttons answer — the agent-neutral spelling of a
    /// decision, mapped onto each bridge's own enum at the call site.
    enum AgentApprovalChoice { case approve, deny }

    /// The head of one agent session's queue. Selecting a decision only removes
    /// this item; its next request (if any) becomes the head and every other
    /// session remains untouched.
    private func agentPermissionCard(
        _ queue: AgentApprovalSessionQueue,
        identifier: Int,
        session: AgentSessionState?,
        decide: @escaping (AgentApprovalChoice, AgentApproval) -> Void
    ) -> some View {
        let approval = queue.current
        let displaySession = session ?? .init(id: approval.threadID,
                                              source: approval.source,
                                              status: .needsYou)
        return HStack(spacing: 10) {
            // A direct approval is a paused session. Its marker intentionally
            // matches the roster's status slot instead of turning the entire tab
            // into a warning-coloured card.
            Image(systemName: "pause.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.black.opacity(0.78))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Tokens.danger.opacity(0.9)))
                .accessibilityHidden(true)

            agentSourceMark(approval.source)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("\(approval.source.displayName) wants your permission")
                }
                    .font(.sf(14, weight: .medium))
                    .foregroundStyle(Tokens.text1)
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 5) {
                    Text(queue.compactMetadataLabel)
                    Text("·")
                    Text("Session \(identifier)")
                        .font(.sf(10, weight: .semibold).monospacedDigit())
                }
                    .font(.sf(10, weight: .medium))
                .foregroundStyle(Tokens.text3)
                .lineLimit(1)
                .truncationMode(.tail)
            }
            .layoutPriority(1)

            Spacer(minLength: 10)

            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 7) {
                    agentSessionMeter(displaySession)
                        .frame(width: 52)
                    Text(displaySession.contextPercentageLabel)
                        .font(.sf(10, weight: .semibold))
                        .foregroundStyle(Tokens.text3)
                        .monospacedDigit()
                    if let badge = displaySession.subagentBadge {
                        agentSubagentBadge(badge)
                    }
                }

                HStack(spacing: 6) {
                    Button("Deny") {
                        model.setPanelControlInteraction(true)
                        decide(.deny, approval)
                    }
                    .buttonStyle(.plain)
                    .font(.sf(10, weight: .semibold))
                    .foregroundStyle(Tokens.text2)
                    .lineLimit(1)
                    .frame(width: 56, height: 24)
                    .background(Capsule().fill(Color.white.opacity(0.07)))
                    .help("Deny this permission request")

                    Button("Approve") {
                        model.setPanelControlInteraction(true)
                        decide(.approve, approval)
                    }
                    .buttonStyle(.plain)
                    .font(.sf(10, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.82))
                    .lineLimit(1)
                    .frame(width: 76, height: 24)
                    .background(Capsule().fill(Color.green.opacity(0.88)))
                    .help("Approve this permission request")
                }
            }
            .frame(width: 138, alignment: .trailing)
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.035))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Tokens.hairline, lineWidth: 0.5)
        }
    }

    private func agentWorkspaceTaskRow(_ task: AgentTaskManager.AgentTask, identifier: Int) -> some View {
        Button {
            if task.isRunning {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                    model.agentDetailTaskID = task.id
                }
            } else {
                openAgentRecord(task)
            }
        } label: {
            HStack(spacing: 10) {
                AgentStatusDot(running: task.isRunning, outcome: task.outcome)
                    .frame(width: 26, height: 26)

                agentEngineMark(task.engine, size: 13, tint: Tokens.text2)
                    .frame(width: 20, height: 20)
                    .overlay(Circle().stroke(Tokens.hairline, lineWidth: 1))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(task.activity ?? task.prompt)
                        .font(.sf(14, weight: .medium))
                        .foregroundStyle(Tokens.text1)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    HStack(spacing: 5) {
                        Text(task.folder.lastPathComponent)
                        Text("·")
                        Text(task.engine.displayName)
                        Text("·")
                        Text("Session \(identifier)")
                            .font(.sf(10, weight: .semibold).monospacedDigit())
                    }
                    .font(.sf(10, weight: .medium))
                    .foregroundStyle(Tokens.text3)
                    .lineLimit(1)
                }
                .layoutPriority(1)

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 5) {
                    HStack(spacing: 7) {
                        agentTaskMeter(task)
                            .frame(width: 64)
                        Text(agentTaskContextLabel(task))
                            .font(.sf(10, weight: .semibold))
                            .foregroundStyle(Tokens.text3)
                            .monospacedDigit()
                    }

                    if task.isRunning {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(NotchModel.formatAgentElapsed(context.date.timeIntervalSince(task.startedAt)))
                                .font(.sf(10, weight: .medium).monospacedDigit())
                                .foregroundStyle(Tokens.text3)
                        }
                    } else {
                        Text(NotchModel.formatAgentElapsed(task.elapsed))
                            .font(.sf(10, weight: .medium).monospacedDigit())
                            .foregroundStyle(Tokens.text3)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(HistoryRowStyle())
        .accessibilityLabel("\(task.engine.displayName), \(task.activity ?? task.prompt), \(task.folder.lastPathComponent), \(agentTaskContextLabel(task)) context")
    }

    private func agentSourceMark(_ source: AgentApprovalSource) -> some View {
        agentEngineMark(source == .codex ? .codex : .claude, size: 12, tint: Tokens.text2)
            .frame(width: 20, height: 20)
            .overlay(Circle().stroke(Tokens.hairline, lineWidth: 1))
            .accessibilityHidden(true)
    }

    /// A root agent's child count belongs beside its context measure: it explains
    /// why one row can represent several working conversations without creating
    /// noisy duplicate cards in the Notch.
    private func agentSubagentBadge(_ count: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
            Text(count)
        }
        .font(.sf(9, weight: .semibold))
        .foregroundStyle(Tokens.text2)
        .accessibilityLabel("\(count) subagents")
    }

    private func agentTaskMeter(_ task: AgentTaskManager.AgentTask) -> some View {
        let progress = agentTaskContextProgress(task)
        return GeometryReader { proxy in
            Capsule().fill(Color.white.opacity(0.10))
                .overlay(alignment: .leading) {
                    Capsule().fill(contextToneColor(agentTaskContextTone(task)).opacity(0.9))
                        .frame(width: proxy.size.width * progress)
                }
        }
        .frame(height: 3)
    }

    /// The CLI reports a real window mid-run, but not in its first events. Until
    /// it does, derive one the same way the transcript scanner does rather than
    /// assuming 200k and showing a full red bar on a long-context model.
    private func agentTaskContextLimit(_ task: AgentTaskManager.AgentTask) -> Int {
        AgentModelContextWindow.window(reported: task.contextWindow,
                                       model: task.modelID,
                                       source: task.engine == .codex ? .codex : .claude,
                                       observedUsed: task.contextUsed)
    }

    private func agentTaskContextProgress(_ task: AgentTaskManager.AgentTask) -> Double {
        guard let used = task.contextUsed, used > 0 else { return 0 }
        return min(1, Double(used) / Double(max(1, agentTaskContextLimit(task))))
    }

    private func agentTaskContextLabel(_ task: AgentTaskManager.AgentTask) -> String {
        "\(Int((agentTaskContextProgress(task) * 100).rounded()))%"
    }

    private func agentTaskContextTone(_ task: AgentTaskManager.AgentTask) -> AgentContextTone {
        switch agentTaskContextProgress(task) {
        case 0.85...: return .red
        case 0.50...: return .yellow
        default: return .green
        }
    }

    /// A state card is intentionally read-only. It tells the user which session
    /// is waiting, asking a question, presenting a plan, working or done; the
    /// one case with authority (a permission) is promoted to the card above.
    private func agentSessionStatusCard(_ session: AgentSessionState, identifier: Int) -> some View {
        let marker = agentSessions.marker(for: session)
        return VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 10) {
            AgentSessionStatusIcon(status: session.status)
                .frame(width: 26, height: 26)

            agentSourceMark(session.source)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(agentStatusTitle(session.status))
                        .font(.sf(14, weight: .medium))
                        .foregroundStyle(Tokens.text1)
                    Text(session.source.displayName)
                        .font(.sf(10, weight: .medium))
                        .foregroundStyle(Tokens.text3)
                }
                HStack(spacing: 5) {
                    Text(session.projectName ?? "External session")
                    Text("·")
                    Text("Session \(identifier)")
                        .font(.sf(10, weight: .semibold).monospacedDigit())
                }
                    .font(.sf(10, weight: .medium))
                    .foregroundStyle(Tokens.text3)
                    .lineLimit(1)
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 5) {
                HStack(spacing: 7) {
                    agentSessionMeter(session)
                        .frame(width: 64)
                    Text(session.contextPercentageLabel)
                        .font(.sf(10, weight: .semibold))
                        .foregroundStyle(Tokens.text3)
                        .monospacedDigit()
                    if let badge = session.subagentBadge {
                        agentSubagentBadge(badge)
                    }
                }
                Text(session.contextLabel)
                    .font(.sf(9, weight: .medium).monospacedDigit())
                    .foregroundStyle(Tokens.text4)
            }
            .fixedSize(horizontal: true, vertical: false)
        }

            if let prompt = agentSessionPromptText(session, marker: marker) {
                agentSessionPrompt(prompt, options: marker?.options ?? [])
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.035))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Tokens.hairline, lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(agentSessionAccessibilityLabel(session, marker: marker))
    }

    /// The text a status marker adds to its card, when it has one worth showing.
    ///
    /// Only the states that are literally a prompt to the user qualify. A
    /// `busy`/`idle` marker carries the tool path or command that happened to
    /// trigger it, which says nothing about why the session is waiting and would
    /// turn every working row into a churning line of noise.
    private func agentMarkerPrompt(_ marker: AgentSessionMarker) -> String? {
        guard marker.status == .question || marker.status == .planning,
              let detail = marker.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
              !detail.isEmpty
        else { return nil }
        return detail
    }

    /// What this row has to say beyond its status. A live marker wins — it is
    /// the question being asked right now — and a session presenting a plan
    /// falls back to the plan its transcript recorded, which is the only place
    /// the plan text exists.
    private func agentSessionPromptText(_ session: AgentSessionState,
                                        marker: AgentSessionMarker?) -> String? {
        if let marker, let prompt = agentMarkerPrompt(marker) { return prompt }
        guard session.status == .planning || session.status == .planReady else { return nil }
        return session.planSummary
    }

    /// The question the agent is actually asking, with the answers it offered.
    ///
    /// Read-only, like the rest of the card: the notch cannot answer an
    /// `AskUserQuestion` — only the agent's own terminal can — so the options are
    /// shown as labels, not buttons. Showing them still earns its space, because
    /// the whole point of the row is to let the user decide whether this session
    /// is worth switching to, and "which four things is it asking between" is
    /// most of that decision.
    private func agentSessionPrompt(_ prompt: String, options: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(prompt)
                .font(.sf(11, weight: .medium))
                .foregroundStyle(Tokens.text2)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            if !options.isEmpty {
                // Wraps rather than truncating: an option label the user cannot
                // read is the same as no option at all. The hook already caps
                // the list at eight, and the roster scrolls.
                FlowLayout(hSpacing: 5, vSpacing: 5) {
                    ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                        Text(option)
                            .font(.sf(9.5, weight: .semibold))
                            .foregroundStyle(Tokens.text2)
                            .lineLimit(1)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.white.opacity(0.07)))
                            .overlay(Capsule().stroke(Tokens.hairline, lineWidth: 0.5))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Aligns under the row's title rather than the card edge: 26pt status
        // icon + 20pt source mark + the two 10pt gaps the HStack puts between
        // them. The prompt then reads as this session's, not the card's.
        .padding(.leading, 66)
    }

    private func agentSessionAccessibilityLabel(_ session: AgentSessionState,
                                                marker: AgentSessionMarker?) -> String {
        var parts = ["\(agentStatusTitle(session.status)), \(session.source.displayName)",
                     session.projectName ?? "External session"]
        if let prompt = agentSessionPromptText(session, marker: marker) {
            parts.append(prompt)
        }
        if let options = marker?.options, !options.isEmpty {
            parts.append("Options: " + options.joined(separator: ", "))
        }
        return parts.joined(separator: ", ")
    }

    private func agentSessionMeter(_ session: AgentSessionState) -> some View {
        GeometryReader { proxy in
            Capsule().fill(Color.white.opacity(0.10))
                .overlay(alignment: .leading) {
                    Capsule().fill(contextToneColor(session.contextTone).opacity(0.9))
                        .frame(width: proxy.size.width * session.contextProgress)
                }
        }
        .frame(height: 3)
    }

    private func contextToneColor(_ tone: AgentContextTone) -> Color {
        switch tone {
        case .green: return .green
        case .yellow: return .yellow
        case .red: return .red
        }
    }

    private func agentStatusTitle(_ status: AgentSessionStatus) -> String {
        switch status {
        case .working: return "Working"
        case .planning: return "Planning"
        case .needsYou: return "Needs you"
        case .question: return "A question"
        case .planReady: return "Done"
        case .done: return "Done"
        case .interrupted: return "Closed"
        }
    }

    private func agentStatusColor(_ status: AgentSessionStatus) -> Color {
        switch status {
        case .working: return Color.blue
        case .needsYou: return Color.orange
        case .question: return Color.yellow
        case .planning: return Tokens.captureTint
        case .planReady: return Tokens.captureTint
        case .done: return Color.green
        case .interrupted: return Tokens.captureTint
        }
    }

    func agentStatusRow(_ task: AgentTaskManager.AgentTask) -> some View {
        HStack(spacing: 8) {
            // A settled run marks its slot with a glass bead (blue done, red
            // failed, grey cancelled); a working one breathes a soft tint pulse.
            AgentStatusDot(running: task.isRunning, outcome: task.outcome)
            if task.isRunning {
                // What the run is doing right now, crossfading as the CLI reports
                // each step — the panel twin of the resting notch's ticker. The
                // changing words and the ticking clock are the "it's alive" signal.
                CrossfadeText(text: task.activity ?? L("agent.thinking"),
                              font: 14, color: Tokens.text3)
                    .tracking(-0.1)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                // Stopping a minutes-long run is destructive — two-step: the ✕
                // arms an explicit "cancel?" chip (auto-disarms after a beat),
                // and only that second tap actually terminates.
                if confirmingAgentCancelID == task.id {
                    Button {
                        agentManager.cancel(taskID: task.id)
                        confirmingAgentCancelID = nil
                    } label: {
                        Text(L("agent.cancelConfirm"))
                            .font(.sf(11, weight: .medium))
                            .foregroundStyle(Color(red: 1.0, green: 0.45, blue: 0.40))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.red.opacity(0.16)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .transition(.scale(scale: 0.8, anchor: .trailing).combined(with: .opacity))
                    .task {
                        // Un-tapped, the armed confirm quietly relaxes back to
                        // the plain ✕. Cancelled automatically if the chip
                        // leaves the screen first.
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                            if confirmingAgentCancelID == task.id {
                                confirmingAgentCancelID = nil
                            }
                        }
                    }
                } else {
                    agentRowTrailing(task) {
                        agentCardButton("xmark", help: L("agent.cancel")) {
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                                confirmingAgentCancelID = task.id
                            }
                        }
                    }
                }
            } else {
                // Settled: just the task's own name — what was asked, not a
                // report of what came back. The dot already says how it went, and
                // the record behind the tap says the rest. The row body is the tap
                // target that opens it; the ✕ throws the row away without opening
                // (the record stays in Recent either way).
                Text(task.prompt)
                    .font(.sf(14))
                    .tracking(-0.1)
                    .foregroundStyle(task.outcome == .failure
                        ? Tokens.danger.opacity(0.9)
                        : (task.outcome == .cancelled ? Tokens.text3 : Tokens.text2))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                agentRowTrailing(task) {
                    agentCardButton("xmark", help: L("agent.dismiss")) {
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                            agentManager.dismissFinished(taskID: task.id)
                        }
                    }
                }
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        // Match the Recent rows' 9pt vertical pad so an agent line sits in the same
        // rhythm as the history below it, not a taller-looking slot.
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The same faint glass floor + thin-material whisper the Recent rows lift
        // under the pointer (HistoryRowStyle), at that style's unselected-hover
        // presence (0.5), so an agent line highlights exactly like the rows below
        // it instead of being the one row that stays flat under the cursor.
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(hoveredAgentRowID == task.id ? 0.015 : 0))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.thinMaterial)
                        .opacity(hoveredAgentRowID == task.id ? 0.11 : 0)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.16)) {
                if inside { hoveredAgentRowID = task.id }
                else if hoveredAgentRowID == task.id { hoveredAgentRowID = nil }
            }
        }
        .onTapGesture {
            if task.isRunning {
                // A live run opens its detail page — the full work trail,
                // streaming — instead of waiting for the record to exist.
                withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                    model.agentDetailTaskID = task.id
                }
            } else {
                openAgentRecord(task)
            }
        }
    }

    /// The row's trailing slot. At rest it's the run's clock — ticking while the
    /// run works, frozen at its final duration once it settles — because that's
    /// what a glance wants to know. Only under the pointer does it become the ✕
    /// (`control`): the close affordance appears on the row you're aiming at,
    /// instead of a column of ✕s shouting at you down the whole list.
    private func agentRowTrailing<Control: View>(
        _ task: AgentTaskManager.AgentTask,
        @ViewBuilder control: () -> Control
    ) -> some View {
        ZStack(alignment: .trailing) {
            if hoveredAgentRowID == task.id {
                control()
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            } else if task.isRunning {
                // Live: re-read the clock every second while the run works.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    agentElapsedLabel(context.date.timeIntervalSince(task.startedAt))
                }
                .transition(.opacity)
            } else {
                // Settled: `elapsed` is pinned by `finishedAt`, so this is the
                // round's final duration, not a clock that keeps running.
                agentElapsedLabel(task.elapsed)
                    .transition(.opacity)
            }
        }
        // Hold the ✕'s width so swapping between clock and button can't shove
        // the line beside it around.
        .frame(minWidth: 18, minHeight: 18, alignment: .trailing)
    }

    /// The elapsed clock itself, in the same language as the collapsed notch's
    /// right ear: monospaced digits that roll rather than hard-cut on each tick.
    func agentElapsedLabel(_ elapsed: TimeInterval) -> some View {
        let seconds = max(0, Int(elapsed))
        return Text(NotchModel.formatAgentElapsed(TimeInterval(seconds)))
            .font(.sf(11))
            .monospacedDigit()
            .contentTransition(.numericText(value: Double(seconds)))
            .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: seconds)
            .foregroundStyle(Tokens.text4)
            .lineLimit(1)
            .fixedSize()
    }

    /// Open a settled run where it's actually read: its Recent record, in the
    /// result view. The row's job is done once the record is open, so it leaves
    /// the tray with the tap (the record itself stays in Recent regardless).
    /// While the run is live there's nothing filed yet — the tap waits.
    private func openAgentRecord(_ task: AgentTaskManager.AgentTask) {
        guard !task.isRunning else { return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
            model.openThread(id: task.id)
            agentManager.dismissFinished(taskID: task.id)
        }
    }
}
