import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Agent task window body

/// A detached agent run: the full work trail writing itself live, the report on
/// settle, and a follow-up line — the complete card, running in its own window
/// while the notch goes back to resting.
struct DetachedAgentTaskView: View {
    let taskID: UUID
    var pinned: Bool
    var onTogglePin: () -> Void
    var onClose: () -> Void

    @ObservedObject private var manager = AgentTaskManager.shared
    @State private var followUp = ""
    @State private var followUpImages: [NSImage] = []
    /// The task's last seen value — keeps the window readable if the task is
    /// dismissed from the tray while this window is open.
    @State private var lastKnown: AgentTaskManager.AgentTask?
    /// The tail-follow release, same rule the panel's detail page uses: chase the
    /// newest line only while the reader is still at the bottom. Measured rather
    /// than assumed, because this window's viewport is resizable.
    @State private var followsTail = true
    @State private var contentBottom: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0

    private static let bottomID = "detached-agent-bottom"
    private static let scrollSpace = "detached-agent-scroll"
    private static let tailSlack: CGFloat = 28

    private var task: AgentTaskManager.AgentTask? {
        manager.tasks.first { $0.id == taskID } ?? lastKnown
    }

    var body: some View {
        Group {
            if let task {
                content(task)
                    .onChange(of: manager.tasks.first(where: { $0.id == taskID })) { _, latest in
                        if let latest { lastKnown = latest }
                    }
                    .onAppear { lastKnown = manager.tasks.first { $0.id == taskID } }
            } else {
                Text(L("detached.task.gone"))
                    .font(.sf(13))
                    .foregroundStyle(Tokens.text3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // Same rhythm as the panel's agent detail page (NotchBody's uniform 15pt
    // inset, header then the quiet gap), so the tear doesn't reflow the trail.
    private func content(_ task: AgentTaskManager.AgentTask) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(task)
            ScrollViewReader { proxy in
                ScrollView {
                    // The panel detail page's own record body, shared verbatim
                    // (`AgentRecordBody`): every settled round's prompt, trail
                    // and report, then the round in flight. This window used to
                    // render the flat trail plus only the LATEST answer, so a
                    // multi-round run lost every earlier report the moment it
                    // was torn out of the notch.
                    AgentRecordBody(task: task, bottomID: Self.bottomID)
                    // Runways: the trail rests between the header and the
                    // follow-up line, then scrolls into these empty bands — up
                    // behind the header, down behind the input — to fade +
                    // frost out on both edges (see ThreadScroll).
                    .padding(.top, ThreadScroll.runway)
                    .padding(.bottom, ThreadScroll.runway)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GeometryReader { geo in
                        Color.clear.preference(
                            key: DetachedAgentContentBottomKey.self,
                            value: geo.frame(in: .named(Self.scrollSpace)).maxY)
                    })
                }
                .coordinateSpace(name: Self.scrollSpace)
                // Overlay, not a wrapper: the viewport's height is needed to know
                // where "the bottom" is, and measuring it must not touch layout.
                .overlay(GeometryReader { geo in
                    Color.clear.preference(key: DetachedAgentViewportKey.self,
                                           value: geo.size.height)
                })
                .onPreferenceChange(DetachedAgentViewportKey.self) { height in
                    viewportHeight = height
                    refreshTailFollow()
                }
                .onPreferenceChange(DetachedAgentContentBottomKey.self) { bottom in
                    contentBottom = bottom
                    refreshTailFollow()
                }
                // Sticky affordances inside the record (a code block's copy
                // button) park below the top fade band, not in it.
                .environment(\.stickyScrollTopInset, ThreadScroll.runway)
                .scrollEdgeFade(top: true, bottom: true, fade: ThreadScroll.runway)
                .progressiveEdgeBlur(top: ThreadScroll.band, bottom: ThreadScroll.band,
                                     topRadius: ThreadScroll.blurRadius)
                .onChange(of: task.log.count) { _, _ in followTail(proxy) }
                // The trailing block GROWS token by token, which moves the tail
                // without changing the row count.
                .onChange(of: task.log.last?.title) { _, _ in followTail(proxy) }
                .onAppear {
                    followsTail = true
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
                .overlay(alignment: .bottom) {
                    if !followsTail {
                        GlassIconButton(systemName: "arrow.down",
                                        help: L("agent.trail.toBottom"),
                                        size: 26, glyphSize: 11,
                                        showsTooltip: false) {
                            followsTail = true
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(Self.bottomID, anchor: .bottom)
                            }
                        }
                        .padding(.bottom, 4)
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.85), value: followsTail)
            }
            VStack(alignment: .leading, spacing: 8) {
                if !followUpImages.isEmpty {
                    ComposeImagesAttachedLine(images: followUpImages) { index in
                        guard followUpImages.indices.contains(index) else { return }
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                            followUpImages.remove(at: index)
                        }
                    }
                }
                followUpRow(task)
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, DetachedThreadView.cardHorizontalPadding)
        .padding(.top, DetachedThreadView.cardTopPadding)
        .padding(.bottom, DetachedThreadView.cardBottomPadding)
    }

    private func header(_ task: AgentTaskManager.AgentTask) -> some View {
        HStack(spacing: 10) {
            AgentStatusDot(running: task.isRunning, outcome: task.outcome)
            Text("\(task.engine.displayName) · \(task.folder.lastPathComponent)")
                .font(.sf(14, weight: .medium))
                .foregroundStyle(Tokens.text2)
                .lineLimit(1)
            Color.clear
                .frame(maxWidth: .infinity)
            if task.isRunning {
                TimelineView(.periodic(from: task.startedAt, by: 1)) { context in
                    elapsedLabel(context.date.timeIntervalSince(task.startedAt))
                }
                Button(action: { manager.cancel(taskID: task.id) }) {
                    Image(systemName: "stop.circle")
                        .font(.sf(13, weight: .semibold))
                        .foregroundStyle(Tokens.text3)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                elapsedLabel(task.elapsed)
            }
            WindowTrailingCluster(pinned: pinned, togglePin: onTogglePin,
                                  close: onClose)
        }
    }

    private func elapsedLabel(_ elapsed: TimeInterval) -> some View {
        let seconds = max(0, Int(elapsed))
        return Text(NotchModel.formatAgentElapsed(TimeInterval(seconds)))
            .font(.sf(11))
            .monospacedDigit()
            .foregroundStyle(Tokens.text4)
            .lineLimit(1)
            .fixedSize()
    }

    /// Whether the content's end still sits at (or just below) the viewport's
    /// bottom edge — the one thing that decides if the page keeps chasing the
    /// tail. Both measurements arrive independently, so this runs on either.
    private func refreshTailFollow() {
        guard viewportHeight > 0 else { return }
        let atTail = contentBottom - viewportHeight <= Self.tailSlack
        if atTail != followsTail { followsTail = atTail }
    }

    private func followTail(_ proxy: ScrollViewProxy) {
        guard followsTail else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
        }
    }

    private func followUpRow(_ task: AgentTaskManager.AgentTask) -> some View {
        // Mid-run the field stays live: Enter queues the line and the manager
        // dispatches it as the next round on settle — typed input is never
        // dropped. Only a run that settled without ever reporting a session id
        // (nothing to resume, ever) goes dead.
        let dead = !task.isRunning && task.sessionID == nil
        // The panel agent page's own composer (`ComposerBox`), not a second one:
        // same growing silhouette, same focus-lit recess, same ⏎/⌘⏎ hints — the
        // page reads identically on both sides of a tear.
        return ComposerBox(
            text: $followUp,
            onSubmit: { sendFollowUp(task) },
            onPasteImage: { pasteFollowUpImage(task) },
            onCommandSubmit: {
                guard task.isRunning, task.sessionID != nil,
                      hasFollowUpInput
                else { return false }
                sendFollowUp(task, interrupting: true)
                return true
            },
            placeholder: {
                Text(L(task.isRunning ? "agent.followUp.queue"
                                      : "agent.followUp.placeholder"))
            },
            trailing: {
                if hasFollowUpInput {
                    AgentFollowUpKeyHints(
                        showsInterrupt: task.isRunning && task.sessionID != nil)
                        .transition(.opacity)
                }
            })
        .opacity(dead ? 0.45 : 1)
        .disabled(dead)
    }

    /// `interrupting` stops the round in flight and re-opens the session with
    /// this line straight away; the plain path queues it for the next round.
    private func sendFollowUp(_ task: AgentTaskManager.AgentTask,
                              interrupting: Bool = false) {
        var line = followUp.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = followUpImages
        if line.isEmpty {
            guard !images.isEmpty else { return }
            line = NotchModel.agentImageOnlyPrompt(count: images.count)
        }
        followUp = ""
        followUpImages = []
        // Sending says you want to watch what happens next.
        followsTail = true
        Task {
            let jpegs = await Task.detached(priority: .userInitiated) {
                images.compactMap { NotchModel.encodeJPEGForVision($0) }
            }.value
            if interrupting {
                manager.interrupt(taskID: task.id, prompt: line, imagesJPEG: jpegs)
            } else {
                manager.followUp(taskID: task.id, prompt: line, imagesJPEG: jpegs)
            }
        }
    }

    private var hasFollowUpInput: Bool {
        !followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !followUpImages.isEmpty
    }

    private func pasteFollowUpImage(_ task: AgentTaskManager.AgentTask) -> Bool {
        guard task.engine.supportsImageInput,
              let image = NotchModel.pasteboardImage() else { return false }
        guard followUpImages.count < NotchModel.composeImageLimit else { return true }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            followUpImages.append(image)
        }
        return true
    }
}

/// Where the detached agent window's scroll content ends, and how tall its
/// viewport is — together they say whether the page is still at the tail.
private struct DetachedAgentContentBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next != 0 { value = next }
    }
}

private struct DetachedAgentViewportKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next != 0 { value = next }
    }
}
