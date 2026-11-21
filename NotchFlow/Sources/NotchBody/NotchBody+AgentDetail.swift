import SwiftUI
import AppKit

@MainActor
extension NotchBody {
    // MARK: - Agent run detail page

    /// The task behind the open agent detail page, if any — nil once the task
    /// leaves the tray (dismissed), which drops the page back to idle by itself.
    var agentDetailTask: AgentTaskManager.AgentTask? {
        model.agentDetailTaskID.flatMap { id in
            agentManager.tasks.first { $0.id == id }
        }
    }

    /// Stable id for the tail spacer the detail scroll follows while streaming.
    private static let agentDetailBottomID = "agent-detail-bottom"
    /// The detail scroll's own coordinate space, and how far the content's end
    /// may sit below the viewport before the page stops chasing the tail.
    private static let agentDetailSpace = "agent-detail-scroll"
    private static let agentDetailTailSlack: CGFloat = 28

    /// Whether the trail's last entry is a paragraph the agent is writing right
    /// now. When it is, the trail already shows the words arriving and the
    /// one-line ticker under it would just repeat their tail; a folded reasoning
    /// block or a tool row shows no motion, so there the ticker still earns its
    /// place. Shared by the panel page and its torn-off twin.
    static func trailTailIsStreamingProse(_ log: [AgentLogEntry]) -> Bool {
        guard let last = log.last else { return false }
        return !last.mono && last.kind == .plain && !last.title.hasPrefix("› ")
    }

    /// Scroll to the newest line — but only while the reader is still at the
    /// tail. Shared by the two things that move it (a new row, and the trailing
    /// block growing token by token).
    private func followAgentDetailTail(_ proxy: ScrollViewProxy) {
        guard agentDetailFollowsTail else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(Self.agentDetailBottomID, anchor: .bottom)
        }
    }

    /// A live run's detail page: the task prompt, then the full work trail —
    /// the agent's narration as prose, each tool call a collapsible mono row —
    /// with the activity ticker at the tail while it works, and the final
    /// report once it settles. Same information structure as the record a
    /// settled row opens; this is the during-the-run way in.
    func agentDetailView(_ task: AgentTaskManager.AgentTask) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            agentDetailHeader(task)
            ScrollViewReader { proxy in
                ScrollView {
                    // What the record is made of — shared with the torn-off
                    // window so the page reads identically on both sides of a
                    // tear (`AgentRecordBody`).
                    AgentRecordBody(task: task, bottomID: Self.agentDetailBottomID)
                    // Runway: the trail rests below the header, then scrolls up into
                    // this empty band to fade + frost out — the same soft top edge
                    // the detached agent window wears (`ThreadScroll`), so the page
                    // reads identically on both sides of a tear.
                    .padding(.top, ThreadScroll.runway)
                    .padding(.bottom, 10)
                    // Where the content's bottom edge currently sits inside the
                    // viewport — the one measurement that says whether the reader
                    // is at the tail. (macOS 14 is the floor here, so this is the
                    // GeometryReader form rather than `onScrollGeometryChange`.)
                    .background(GeometryReader { geo in
                        Color.clear.preference(
                            key: AgentDetailContentBottomKey.self,
                            value: geo.frame(in: .named(Self.agentDetailSpace)).maxY)
                    })
                }
                .coordinateSpace(name: Self.agentDetailSpace)
                .onPreferenceChange(AgentDetailContentBottomKey.self) { bottom in
                    // Slack = how far the content's end sits BELOW the viewport's
                    // bottom edge. A screenful of tolerance, so the animated
                    // tail-follow's own intermediate frames never read as "the
                    // user scrolled away".
                    let atTail = bottom - agentDetailScrollHeight <= Self.agentDetailTailSlack
                    if atTail != agentDetailFollowsTail { agentDetailFollowsTail = atTail }
                }
                // The shared dissolve at the top edge only — the page pins to the
                // tail, so the newest line rests at the bottom and must stay at
                // full strength (a bottom taper would permanently dim it).
                .scrollEdgeFade(top: true, bottom: false, topFade: ThreadScroll.runway)
                // Frost rests while the run streams (same discipline as the result
                // view's ConditionalTopBlur): the blurred copy re-rasterizes on
                // every content change, and a live trail changes constantly.
                .modifier(ConditionalTopBlur(active: !task.isRunning,
                                             height: ThreadScroll.band,
                                             maxRadius: ThreadScroll.blurRadius))
                // Follow the tail while entries stream in, like a terminal —
                // unless the reader has scrolled up, in which case the page
                // stays where they put it (`agentDetailFollowsTail`).
                .onChange(of: task.log.count) { _, _ in
                    followAgentDetailTail(proxy)
                }
                // The trailing block GROWS token by token now, which moves the
                // tail without changing the row count.
                .onChange(of: task.log.last?.title) { _, _ in
                    followAgentDetailTail(proxy)
                }
                .onAppear {
                    agentDetailFollowsTail = true
                    proxy.scrollTo(Self.agentDetailBottomID, anchor: .bottom)
                }
                // The way back down, offered only once the follow has released —
                // otherwise the page is already there and the chip is noise.
                .overlay(alignment: .bottom) {
                    if !agentDetailFollowsTail {
                        GlassIconButton(systemName: "arrow.down",
                                        help: L("agent.trail.toBottom"),
                                        size: 26, glyphSize: 11,
                                        showsTooltip: false) {
                            agentDetailFollowsTail = true
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(Self.agentDetailBottomID, anchor: .bottom)
                            }
                        }
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.85),
                           value: agentDetailFollowsTail)
            }
            .frame(height: agentDetailScrollHeight)

            // A live follow-up box, same as the detached agent window carries. The
            // run is mid-reply, so Enter can't interrupt it — the line queues and
            // the manager dispatches it as the next round on settle (its "› "
            // marker joins the trail above the moment it lands). The box stays after
            // send, so several instructions can be lined up. Hidden only when the
            // run settled without ever reporting a session id (nothing to resume,
            // ever); a still-running or resumable task keeps it live.
            if task.isRunning || task.sessionID != nil {
                agentDetailFollowUpRow(task)
            }
        }
    }

    /// The agent-detail page's follow-up input. Wired straight to the task's queue
    /// (`AgentTaskManager.followUp`) rather than the panel's submit routing — the
    /// page renders in `.idle` mode with empty `turns`, so `submitCurrent` would
    /// mis-route the line to the chat model. Placeholder says "queue" while a round
    /// is in flight, "ask a follow-up" once it settles.
    /// The page's follow-up box plus the ⌘ metadata chip beside it — the same
    /// pairing a reopened record wears (`followUpRow`). The chip is permanent
    /// here rather than earned: a live run always has an engine and a folder to
    /// name, and a chip that appeared only at settle would move the send button
    /// mid-run.
    private func agentDetailFollowUpRow(_ task: AgentTaskManager.AgentTask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !agentDetailFollowUpImages.isEmpty {
                ComposeImagesAttachedLine(images: agentDetailFollowUpImages) { index in
                    guard agentDetailFollowUpImages.indices.contains(index) else { return }
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                        agentDetailFollowUpImages.remove(at: index)
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 6) {
                agentDetailComposer(task)
                    .frame(maxWidth: .infinity)

                GlassIconButton(systemName: "command",
                                help: L("agent.detail"),
                                size: 39,
                                glyphSize: 13,
                                showsTooltip: false) {
                    agentDetailMetadataOpen.toggle()
                }
                .modifier(MenuCardWindow(
                    open: agentDetailMetadataOpen,
                    upperLeading: true,
                    onDismiss: { _ in agentDetailMetadataOpen = false },
                    card: {
                        AnyView(AgentRunMetadataMenu(
                            engine: task.engine.displayName,
                            folderPath: task.folder.path,
                            completedAt: task.finishedAt,
                            onOpenFolder: {
                                agentDetailMetadataOpen = false
                                NSWorkspace.shared.open(task.folder)
                            })
                            .manageMenuCardBackground())
                    }))
            }
        }
    }

    private func agentDetailComposer(_ task: AgentTaskManager.AgentTask) -> some View {
        // The shared box (`ComposerBox`) — the same control the chat follow-up
        // is, and the same one this page's torn-off window carries.
        ComposerBox(
            text: $agentDetailFollowUp,
            focusTrigger: focused,
            focused: focused,
            onSubmit: { submitAgentDetailFollowUp(task) },
            onPasteImage: { pasteAgentDetailFollowUpImage(task) },
            // ⌘⏎ is the accelerator for the chip below: stop the round in
            // flight and hand the agent this line right now.
            onCommandSubmit: {
                guard task.isRunning, task.sessionID != nil,
                      hasAgentDetailFollowUpInput
                else { return false }
                submitAgentDetailFollowUp(task, interrupting: true)
                return true
            },
            placeholder: {
                Text(L(task.isRunning ? "agent.followUp.queue"
                                      : "agent.followUp.placeholder"))
            },
            trailing: {
                if hasAgentDetailFollowUpInput {
                    // The field already owns both verbs: ⏎ sends/queues and ⌘⏎
                    // interrupts the live round. State them plainly instead of
                    // repeating them as an interrupt pill plus glass arrow.
                    AgentFollowUpKeyHints(
                        showsInterrupt: task.isRunning && task.sessionID != nil)
                        .transition(.opacity)
                }
            })
    }

    /// Queue the line as the run's next instruction and clear the field — the box
    /// itself stays so more can follow. While the round is in flight the manager
    /// holds it and dispatches on settle; a settled-but-resumable task spawns it
    /// straight away. Never dismisses the page.
    ///
    /// `interrupting` is the ⌘⏎ / chip path: stop the round in flight and open
    /// the next one with this line immediately, instead of waiting the current
    /// one out (`AgentTaskManager.interrupt`).
    private func submitAgentDetailFollowUp(_ task: AgentTaskManager.AgentTask,
                                           interrupting: Bool = false) {
        var line = agentDetailFollowUp.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = agentDetailFollowUpImages
        if line.isEmpty {
            guard !images.isEmpty else { return }
            line = NotchModel.agentImageOnlyPrompt(count: images.count)
        }
        agentDetailFollowUp = ""
        agentDetailFollowUpImages = []
        // Sending is a statement that you want to watch what happens next, so it
        // re-arms the tail follow however far up the page had been scrolled.
        agentDetailFollowsTail = true
        Task {
            let jpegs = await Task.detached(priority: .userInitiated) {
                images.compactMap { NotchModel.encodeJPEGForVision($0) }
            }.value
            if interrupting {
                AgentTaskManager.shared.interrupt(taskID: task.id, prompt: line,
                                                  imagesJPEG: jpegs)
            } else {
                AgentTaskManager.shared.followUp(taskID: task.id, prompt: line,
                                                 imagesJPEG: jpegs)
            }
        }
    }

    private var hasAgentDetailFollowUpInput: Bool {
        !agentDetailFollowUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !agentDetailFollowUpImages.isEmpty
    }

    private func pasteAgentDetailFollowUpImage(
        _ task: AgentTaskManager.AgentTask
    ) -> Bool {
        guard task.engine.supportsImageInput,
              let image = NotchModel.pasteboardImage() else { return false }
        guard agentDetailFollowUpImages.count < NotchModel.composeImageLimit else {
            return true
        }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            agentDetailFollowUpImages.append(image)
        }
        return true
    }

    /// The detail page's top bar: back chevron (the page is a peek, not a mode —
    /// backing out never touches the run), status dot + engine·folder title,
    /// then the same elapsed clock the collapsed row shows and the open-folder
    /// jump the settled record offers.
    private func agentDetailHeader(_ task: AgentTaskManager.AgentTask) -> some View {
        HStack(spacing: 10) {
            // Back chevron: the page renders in `.idle` mode, so the bare-← key
            // handler (which gates on `mode != .idle`) can't reach it — a visible
            // button is the only reliable way out (Esc closes the whole panel).
            // Same chevron the result header carries; taps `newChat()`, which
            // drops `agentDetailTaskID` and falls back to the idle prompt.
            backButton
            Spacer(minLength: 0)
            if task.isRunning {
                TimelineView(.periodic(from: task.startedAt, by: 1)) { context in
                    agentElapsedLabel(context.date.timeIntervalSince(task.startedAt))
                }
            } else {
                agentElapsedLabel(task.elapsed)
            }
            // Folder access already lives in the metadata menu beside the
            // follow-up field. Keep only the detach action in the header.
            GlassSegmentCluster(segments: [
                .init(tooltip: shortcutHelp("detached.open", action: .detach),
                      action: { model.openDetachedWindow() }) {
                    Image(systemName: "macwindow.on.rectangle")
                        .font(.sf(12, weight: .semibold))
                },
            ])
        }
        // The detail header is also the run's tear-off grip — drag the page out
        // and the task splits into its own window. The hand cursor rides the
        // WHOLE strip, buttons included, because the whole strip really is
        // draggable: the icons win the tap, the drag arms past its minimum.
        .contentShape(Rectangle())
        .grabCursor()
        .gesture(detachDragGesture)
    }

    /// A small quiet icon button for the agent card's corner actions — a bare
    /// glyph, no drawn backing: the card already carries enough chrome, so the
    /// buttons read as marks, not more boxes. The 18pt frame keeps the target.
    func agentCardButton(_ systemName: String, help: String,
                                    action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.sf(9.5, weight: .semibold))
                .foregroundStyle(Tokens.text4)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .notchTooltip(help, edge: .bottom)
        .accessibilityLabel(help)
    }

    /// Shared open/close feel for the modules that unfurl below the prompt
    /// (recent list, transient panels): the whole block grows in from the top and
    /// fades, rather than popping in instantly.
    var moduleTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .top)
                .combined(with: .opacity)
                .combined(with: .scale(scale: 0.97, anchor: .top)),
            removal: .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
        )
    }
}
