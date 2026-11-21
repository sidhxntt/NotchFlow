import SwiftUI
import Combine
import AppKit   // NSWorkspace — opening Notes/Reminders for a Recent capture
import Carbon.HIToolbox
import UniformTypeIdentifiers   // UTType — is a pasted file URL an image? (agent ⌘V)

@MainActor
extension NotchModel {
    // MARK: - Agent to Codex (XII: agent-to-Codex)

    /// Enter the agent compose: unfurl the chip row and point the hint at the
    /// agent CLI. With a `folder` (the drop path) that folder is the compose's;
    /// without one (the pill path) the remembered last project seeds it — possibly
    /// nothing, in which case the folder chip says "choose" and Enter opens the
    /// picker. Animated here because both entries (a pill tap, a drop) land
    /// outside any withAnimation context.
    func enterAgentCompose(folder: URL? = nil) {
        guard !AgentEngine.available.isEmpty else { return }
        // A task for the agent is written against a project on disk, not against
        // whatever was highlighted in another window — and `submitAgent` never
        // reads the carried selection, so leaving the chip up would be the panel
        // claiming a context it isn't going to send.
        clearSelectionContext()
        withAnimation(.smooth(duration: 0.3)) {
            if let folder {
                lastAgentFolder = folder
                AgentFolderMRU.record(folder)
                agentComposeFolder = folder
            } else if agentComposeFolder == nil {
                agentComposeFolder = lastAgentFolder
            }
            agentComposeActive = true
            manualPanelOverride = nil
        }
        // The remembered engine may have been uninstalled / signed out since it
        // was last used — fall back to whichever is live, and drop the model
        // pick with it (it named the dead engine's model). Gated on KNOWN dead,
        // never on a probe that simply hasn't landed (see `isKnownUnavailable`).
        if agentArmedEngine.isKnownUnavailable,
           let fallback = AgentEngine.available.first {
            agentArmedEngine = fallback
            agentModelID = nil
        }
    }

    /// The persisted-bucket twin of `enterAgentCompose`: a bucket restored from the
    /// last launch is armed without ever having been *entered* this run, so nothing
    /// seeded it. Run on open — seed the remembered project, and repoint a stale
    /// engine (uninstalled / signed out since it was last used), dropping its model
    /// pick with it. No agent CLI survives at all → fall back to Ask rather than
    /// unfurl a compose row that can't run.
    ///
    /// **Only a KNOWN-dead engine is repointed.** This runs on the first open, which
    /// after a relaunch can land inside the launch probe's window — and there every
    /// engine reads unavailable. Repointing on that made a relaunch quietly reset the
    /// armed model: Command Code + Deepseek came back as Codex on the CLI default,
    /// and because both writes persist through `didSet`, the pick wasn't just drawn
    /// wrong, it was gone. A pick that can't be judged yet is left exactly as it is;
    /// `.cliAvailabilityResolved` runs this again once the probe has an answer.
    func rearmPersistedAgentBucket() {
        guard agentComposeActive else { return }
        // Same "not yet" caution one level up: `agentAvailable` is false during the
        // probe window too, and closing the bucket there would drop the user out of
        // a mode they're still in.
        guard AgentEngine.offered.allSatisfy(\.isAvailabilityResolved) else { return }
        guard agentAvailable else {
            agentComposeActive = false
            return
        }
        if agentComposeFolder == nil { agentComposeFolder = lastAgentFolder }
        if agentArmedEngine.isKnownUnavailable, let fallback = AgentEngine.available.first {
            agentArmedEngine = fallback
            agentModelID = nil
        }
    }

    /// Exit the compose (Shift-Tab, Tab, or the pill's Ask half — NOT a submit; the
    /// bucket outlives the task it sent). Keeps the folder memory — re-entering
    /// lands on the same project; the attached images don't (they belonged to the
    /// task that was being written).
    func exitAgentCompose() {
        withAnimation(.smooth(duration: 0.3)) {
            agentComposeActive = false
            agentComposeImages = []
        }
    }

    /// ⌘V in the prompt attaches a clipboard image to the active compose. Ask and
    /// Agent keep separate attachment sets, but share the same explicit-paste,
    /// append, cap, and delete interaction. Text-only clipboards fall through to
    /// the editor's ordinary paste behavior.
    func handleComposePasteImage() -> Bool {
        guard let image = Self.pasteboardImage() else { return false }
        if agentComposeActive {
            guard agentComposeImages.count < Self.composeImageLimit else { return true }
        } else {
            if let engine = agentThreadContinuation {
                guard engine.supportsImageInput else { return false }
            } else {
                guard activeModelSupportsVision else { return false }
            }
            guard askComposeImages.count < Self.composeImageLimit else { return true }
        }
        // A pasted image is real input, exactly like typed text — so fold the
        // Recent list the same way the `text` setter does. Without this the
        // list lingers open over the compose until the user also types
        // something (for example, after pasting an image).
        collapseHistory()
        noteUserTyping()
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            if agentComposeActive {
                agentComposeImages.append(image)
            } else {
                // An image attachment is an explicit Ask intent; don't let a short
                // caption such as "save this" silently route the pixels to Notes.
                manualPanelOverride = .chat
                askComposeImages.append(image)
            }
        }
        return true
    }

    /// The stand-in instruction an image-only send carries: the CLIs read the
    /// prompt from stdin/args, so "no text" still has to say *something* — and
    /// what it should say is "the images are the task".
    static func agentImageOnlyPrompt(count: Int) -> String {
        count > 1
            ? "See the attached images — they describe the task."
            : "See the attached image — it describes the task."
    }

    /// The image on the clipboard, or `nil` if it doesn't carry one. Keyed on the
    /// pasteboard actually declaring an IMAGE payload — not on "it has no text".
    /// The distinction is the whole feature: most apps that copy an image put a
    /// string alongside the pixels (a source URL, an alt text, a file path), so a
    /// "text ⇒ not an image" rule only ever recognizes a bare ⌃⇧⌘4 screenshot and
    /// pastes that URL as text everywhere else. Two shapes count:
    ///   · pixels on the board (screenshot, in-app image copy) — text riding along
    ///     is metadata about the image, so the image still wins;
    ///   · an image FILE copied in Finder, which puts a file URL and no pixels.
    /// Anything else (plain text, RTF/HTML from a doc, a non-image file) returns
    /// `nil` and pastes as text.
    static func pasteboardImage() -> NSImage? {
        let pb = NSPasteboard.general
        if pb.availableType(from: [.png, .tiff]) != nil,
           let image = NSImage(pasteboard: pb), image.isValid {
            return image
        }
        if let url = (pb.readObjects(forClasses: [NSURL.self]) as? [URL])?.first,
           let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
           let image = NSImage(contentsOf: url), image.isValid {
            return image
        }
        return nil
    }

    /// A thumbnail's × in the attached-images strip — drop that one, keep the
    /// rest and keep composing.
    func removeAgentComposeImage(at index: Int) {
        guard agentComposeImages.indices.contains(index) else { return }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            agentComposeImages.remove(at: index)
        }
    }

    func removeAskComposeImage(at index: Int) {
        guard askComposeImages.indices.contains(index) else { return }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            askComposeImages.remove(at: index)
        }
    }

    /// A project folder dropped on the island — the compose's second doorway.
    /// The folder is exactly the argument the mode is missing, so one drop both
    /// enters the compose and answers "where". Wherever the panel was (a thread,
    /// settings), the drop lands it on the idle prompt — that's where the task
    /// gets written; a thread on screen files into Recent like ⌘N.
    func handleAgentFolderDrop(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }
        // The drop landing — the trackpad answers the release like Finder's snap.
        Haptics.alignment()
        withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
            if showWhatsNew { showWhatsNew = false }
            if mode != .idle { newChat() }
        }
        enterAgentCompose(folder: url)
    }

    /// Pick (or change) the compose's folder. The picker is a separate window,
    /// so `isFolderPickerOpen` holds the island open while it's up (same trick
    /// as the model picker popover). `then` runs on a successful pick — the
    /// no-remembered-folder Enter path uses it to fire the run straight from
    /// the picker's OK, making the picker the first run's confirmation gate.
    func pickAgentFolder(then completion: ((URL) -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = L("agent.pick.message")
        // Reopen at the user's last project when selecting a different agent folder.
        panel.directoryURL = lastAgentFolder
        isFolderPickerOpen = true
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            Task { @MainActor in
                guard let self else { return }
                self.isFolderPickerOpen = false
                if response == .OK, let url = panel.url {
                    self.selectAgentFolder(url)
                    completion?(url)
                }
            }
        }
    }

    /// Point the compose at `url` — the one path every folder change goes through
    /// (the file panel's OK, and the chip menu's recent rows), so the remembered
    /// project and the recents list can never drift from what the chip shows.
    func selectAgentFolder(_ url: URL) {
        lastAgentFolder = url
        AgentFolderMRU.record(url)
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            agentComposeFolder = url
        }
        refreshAgentSkills(forceReload: true)
    }

    /// The compose row's model menu: picking a model picks its engine with it
    /// (the menu mixes every available engine's entries into one list).
    func selectAgentModel(_ choice: AgentModelChoice) {
        agentArmedEngine = choice.engine
        agentModelID = choice.id
        // Drop an effort the new model doesn't take. The run already clamps this
        // at spawn (see `startAgentRun`), but leaving it armed made the chip read
        // "Kimi K3 max" for a model with no adjustable effort at all — a level the
        // run would silently discard. The chip should never name a dial that isn't
        // connected to anything.
        if let effort = agentEffort,
           !choice.engine.effortChoices(forModelID: choice.id).contains(effort) {
            agentEffort = nil
        }
        // An explicit pick counts as "recently used" right away, so the picker's
        // top section reflects it on the next open even before a run goes out —
        // the same rule the Ask chip's recents follow.
        AgentModelMRU.record(engine: choice.engine, model: choice.id)
    }

    /// Enter on a composed line: start the agent run. With no folder yet
    /// (first-ever agent) the picker opens and its OK starts the run — the
    /// natural confirmation gate; nothing ever launches silently. The run is
    /// owned by the manager — closing the panel doesn't touch it; a notification
    /// announces the finish. Submitting does NOT end the compose: the bucket is a
    /// mode you stay in, so the next task starts armed on the same project.
    /// The Agent-bucket meaning of Command-Return: start this task and follow it
    /// straight into its live detail page. Kept separate from plain Return, which
    /// deliberately leaves the compose bucket visible for quickly starting more
    /// independent tasks.
    @discardableResult
    func submitAgentAndOpenDetail() -> Bool {
        guard NotchCapabilityStore.shared.agenticModeEnabled else { return false }
        guard agentComposeActive else { return false }
        return submitAgent(openDetail: true)
    }

    @discardableResult
    func submitAgent(openDetail: Bool = false) -> Bool {
        guard LicenseService.shared.state.allowsProductServices else { return false }
        guard NotchCapabilityStore.shared.agenticModeEnabled else { return false }
        var prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Attached images alone are a valid task — a screenshot of the bug IS
        // the description. The CLIs still need some text next to the pixels, so
        // a wordless send rides a minimal stand-in instruction.
        if prompt.isEmpty {
            guard !agentComposeImages.isEmpty else { return false }
            prompt = Self.agentImageOnlyPrompt(count: agentComposeImages.count)
        }
        // No single-task gate: tasks run in parallel — a submit while others
        // are working just spawns another run.
        if let folder = agentComposeFolder {
            startAgentRun(folder: folder, prompt: prompt, openDetail: openDetail)
        } else {
            pickAgentFolder { [weak self] folder in
                self?.startAgentRun(folder: folder, prompt: prompt,
                                    openDetail: openDetail)
            }
        }
        return true
    }

    private func startAgentRun(folder: URL, prompt: String,
                               openDetail: Bool = false) {
        guard LicenseService.shared.state.allowsProductServices else { return }
        // Pass the model pick only if it still belongs to the armed engine —
        // a stale cross-engine leftover would 404 the run.
        let engine = agentArmedEngine
        let model = engine.modelChoices.contains { $0.id == agentModelID }
            ? agentModelID : nil
        // Same staleness rule for the effort: a level the picked engine+model
        // doesn't offer (e.g. ultra left over from another model) drops to the
        // CLI default rather than erroring the run.
        let effort = agentEffort.flatMap {
            engine.effortChoices(forModelID: model).contains($0) ? $0 : nil
        }
        // What actually ran is the truest "recent" signal there is — including the
        // CLI-default pick (`model == nil`), which is a choice like any other.
        AgentModelMRU.record(engine: engine, model: model)
        // Captured before the send clears them. Encoding a Retina
        // screenshot (downscale + JPEG) is real CPU — and there may now be
        // several — so it runs off-main, same as the chat path: the spawn waits
        // a beat but ⏎ stays instant. An image that fails to encode is dropped,
        // not fatal to the run.
        let images = agentComposeImages
        Task {
            var jpegs: [Data] = []
            if !images.isEmpty {
                jpegs = await Task.detached(priority: .userInitiated) {
                    images.compactMap { Self.encodeJPEGForVision($0) }
                }.value
            }
            if let taskID = AgentTaskManager.shared.start(
                folder: folder, prompt: prompt, engine: engine, model: model,
                effort: effort, imagesJPEG: jpegs
            ), openDetail {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                    self.agentDetailTaskID = taskID
                }
            }
        }
        text = ""
        // The bucket survives its own send: sending a task doesn't mean you're done
        // sending tasks, so the compose stays armed on the same project and engine.
        // Only the attachments go — they belonged to the task just sent.
        withAnimation(.smooth(duration: 0.3)) { agentComposeImages = [] }
    }

    /// File a settled agent run into Recent as an ask-shaped record — the
    /// task description as the user turn, Codex's report as the answer — so the
    /// result outlives the card (dismiss, app restart) and reopens like any
    /// conversation. The answer footer carries "Codex · <folder>" so the row's
    /// thread reads as what it is. Keyed by the task id, so the finished banner's
    /// tap can route straight to this row. Reopening also makes the result
    /// follow-up-able: questions about it go to the chat model with the report
    /// in context.
    func recordAgentHistory(_ task: AgentTaskManager.AgentTask) {
        // Every settled round is an exchange — cancels and interrupted runs
        // included, so a run that ended badly still leaves a record; a follow-up
        // settles the same task id again with a longer thread, replacing the
        // previous record in place.
        guard let last = task.exchanges.last else { return }
        let footer = "\(task.engine.displayName) · \(task.folder.lastPathComponent)"
        var thread: [Turn] = []
        for exchange in task.exchanges {
            var promptTurn = Turn(role: "user", text: exchange.prompt)
            // The screenshots pasted into this round — often the whole task ("fix
            // this"), so the record is unreadable without them.
            promptTurn.imageFiles = exchange.imageFiles
            promptTurn.isAgent = true
            thread.append(promptTurn)
            var answerTurn = Turn(role: "assistant", text: exchange.answer)
            answerTurn.answerModel = footer
            // Marked as the agent's turn so the reopened thread knows what it is:
            // no regenerate on the report (the chat model can't redo the run),
            // and the follow-up field says who a question actually goes to.
            answerTurn.isAgent = true
            // The round's work trail rides the record, so the reopened thread
            // shows the same tool rows the live detail page does — patches and
            // plans included, hence `kind`. Trimmed on the way in: the archive is
            // one JSON file rewritten after every answer, so a marathon round
            // keeps its newest 200 steps and each captured output its first
            // 1200 chars (a patch needs more room than a command's tail did).
            if !exchange.log.isEmpty {
                answerTurn.agentLog = exchange.log.suffix(200).map {
                    AgentLogEntry(id: $0.id, title: $0.title, mono: $0.mono,
                                  detail: $0.detail.map { String($0.prefix(1200)) },
                                  kind: $0.kind)
                }
            }
            thread.append(answerTurn)
        }
        var item = HistoryItem(id: task.id, q: task.prompt, a: last.answer,
                               t: Date(), turns: thread, source: .agent)
        // The run's working folder, full path — what the reopened thread's and the
        // archive's open-folder buttons jump to. (The footer string above only
        // carries the last path component, for reading.)
        item.link = task.folder.path
        switch task.outcome {
        case .success:   item.agentOutcome = "success"
        case .failure:   item.agentOutcome = "failure"
        case .cancelled: item.agentOutcome = "cancelled"
        case nil:        break   // unreachable: only settled tasks are filed
        }
        // The CLI session handle rides EVERY settled row that has one — it's what
        // lets the reopened thread's follow-up go back to the agent, resuming the
        // run in place (`continueAgentThread`). `agentInterrupted` marks the rows
        // whose run the app died during; only those grow the explicit resume
        // button (`openAgentResume`).
        if let session = task.sessionID {
            item.agentResume = .init(engine: task.engine.rawValue,
                                     folderPath: task.folder.path,
                                     session: session)
        }
        item.agentInterrupted = task.interrupted
        history.removeAll { $0.id == task.id }
        history.insert(item, at: 0)
        // Straight to disk — NOT through the 0.4s save debounce — and the run's
        // in-flight crash marker clears only once the row is written. The
        // debounced path left a window (marker already cleared at settle, row
        // not yet on disk) where a crash erased the run without a trace.
        let settledTaskID = task.id
        saveHistoryNow { AgentTaskManager.clearInFlight(taskID: settledTaskID) }
    }

    /// Whether the on-screen thread is (or grew out of) an agent run's record.
    /// Drives the affordances that must read differently there: the follow-up
    /// placeholder names the chat model as the answerer, and the result header
    /// grows an open-folder button.
    var threadIsAgentRun: Bool { turns.contains { $0.isAgent } }

    /// The working folder of the agent run behind the on-screen thread — non-nil
    /// only for a reopened `.agent` row that kept its folder path. Drives the
    /// result header's open-folder button (parity with the live card's footer).
    var currentThreadAgentFolder: String? {
        guard threadIsAgentRun,
              let item = history.first(where: { $0.id == threadHistoryID }),
              item.source == .agent, let path = item.link, !path.isEmpty else { return nil }
        return path
    }

    /// When the agent run behind the on-screen thread finished — the reopened
    /// record's own timestamp (`recordAgentHistory` stamps it at settle). Drives
    /// the settled report footer's completion stamp. `nil` for non-agent threads
    /// and threads not backed by a saved record.
    var currentThreadCompletedAt: Date? {
        guard threadIsAgentRun,
              let item = history.first(where: { $0.id == threadHistoryID }),
              item.source == .agent else { return nil }
        return item.t
    }

    /// Jump to the reopened run's working folder in Finder — the result header's
    /// folder button. Deliberate app-leave, same as the capture jumps.
    func openThreadAgentFolder() {
        guard let path = currentThreadAgentFolder else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// The interrupted agent run behind the thread that's open right now, if any.
    /// Drives the result view's resume row: the open Recent row still holds the CLI
    /// session its run was killed in, so the answer can carry a button that picks it
    /// back up — no terminal, no copied command. `nil` for every other thread.
    var openAgentResume: (engine: AgentEngine, resume: HistoryItem.AgentResume)? {
        guard let item = history.first(where: { $0.id == threadHistoryID }),
              item.agentInterrupted,
              let resume = item.agentResume,
              let engine = AgentEngine(rawValue: resume.engine) else { return nil }
        return (engine, resume)
    }

    /// Re-issue the round the interruption cut off, in the CLI session it left
    /// behind — the button under an interrupted run's answer, and the GUI half of
    /// `AgentEngine.resumeCommand`. The task revives under this row's own id, so
    /// when it settles it re-files the SAME Recent row (interrupted marker and all
    /// replaced) instead of forking a second copy of the conversation. The panel
    /// drops back to idle, where the revived run rides the bucket row's badge like
    /// any other working task.
    func resumeAgentThread() {
        guard LicenseService.shared.state.allowsProductServices else { return }
        guard let item = history.first(where: { $0.id == threadHistoryID }),
              let resume = item.agentResume,
              let engine = AgentEngine(rawValue: resume.engine) else { return }

        // Rebuild the rounds from the saved thread. Everything before the last one
        // settled normally and stays in the transcript; the last IS the interrupted
        // round (its answer is the "Task interrupted" notice) — its prompt is what
        // goes back to the CLI, so the work resumes where it was cut off.
        var rounds: [AgentTaskManager.AgentExchange] = []
        var askedTurn: Turn? = nil
        for turn in item.conversation {
            if turn.role == "user" {
                askedTurn = turn
            } else if let asked = askedTurn {
                rounds.append(.init(prompt: asked.text, answer: turn.text,
                                    imageFiles: asked.imageFiles,
                                    log: turn.agentLog ?? []))
                askedTurn = nil
            }
        }
        guard let cut = rounds.popLast() else { return }
        // The screenshots that round rode in on go back out with it — they were
        // often the whole task ("fix this").
        let jpegs = cut.imageFiles.compactMap { try? Data(contentsOf: Self.historyImageURL($0)) }

        AgentTaskManager.shared.resume(taskID: item.id, engine: engine,
                                       folder: URL(fileURLWithPath: resume.folderPath),
                                       headline: item.q, session: resume.session,
                                       priorRounds: rounds, prompt: cut.prompt,
                                       imagesJPEG: jpegs)
        newChat()
    }

    /// The engine that can pick the on-screen agent thread's CLI session back up
    /// for a follow-up — non-nil only when the thread's record kept its session
    /// handle and that engine is still installed. Drives the follow-up routing
    /// (`submit` hands such a line to `continueAgentThread`) and the placeholder
    /// that says who answers.
    var agentThreadContinuation: AgentEngine? {
        guard threadIsAgentRun,
              let item = history.first(where: { $0.id == threadHistoryID }),
              let resume = item.agentResume,
              let engine = AgentEngine(rawValue: resume.engine),
              engine.isAvailable else { return nil }
        return engine
    }

    /// True while the on-screen agent thread's task is running a round right
    /// now (a follow-up already dispatched from this thread, or the settled
    /// tray card re-opened mid-round). Enter still routes to
    /// `continueAgentThread` — the manager queues the line for the next round —
    /// so the follow-up placeholder says "queued" instead of promising an
    /// immediate continue. (Freshness rides on views also observing
    /// `AgentTaskManager`, whose task changes re-render them.)
    var agentThreadTaskRunning: Bool {
        guard threadIsAgentRun else { return false }
        return AgentTaskManager.shared.tasks
            .first { $0.id == threadHistoryID }?.isRunning == true
    }

    /// Route a result-view follow-up back into the run's CLI session. The record
    /// in Recent IS the run's conversation now, so Enter on its thread means
    /// "next instruction to the agent", not "ask the chat model about this". The
    /// round then runs like any background task — the panel drops to idle, the
    /// status row carries the live activity — and on settle it re-files the SAME
    /// Recent row (task id == row id), so reopening lands on the grown thread.
    func continueAgentThread(prompt: String, images: [NSImage] = []) {
        guard let item = history.first(where: { $0.id == threadHistoryID }),
              let resume = item.agentResume,
              let engine = AgentEngine(rawValue: resume.engine) else { return }
        let dispatch: ([Data]) -> Void = { jpegs in
            let manager = AgentTaskManager.shared
            if manager.tasks.contains(where: { $0.id == item.id }) {
                // The run's task is still in the tray (its status row not yet
                // dismissed) — a plain follow-up round on it. Settled → spawns
                // now; still running → the manager queues it for the next round,
                // so a line typed mid-run is never dropped.
                manager.followUp(taskID: item.id, prompt: prompt, imagesJPEG: jpegs)
            } else {
                // The task is gone (row dismissed, or the app relaunched since):
                // rebuild the prior rounds from the record and spawn a resumed run
                // under the row's own id.
                var rounds: [AgentTaskManager.AgentExchange] = []
                var askedTurn: Turn? = nil
                for turn in item.conversation {
                    if turn.role == "user" {
                        askedTurn = turn
                    } else if let asked = askedTurn {
                        rounds.append(.init(prompt: asked.text, answer: turn.text,
                                            imageFiles: asked.imageFiles,
                                            log: turn.agentLog ?? []))
                        askedTurn = nil
                    }
                }
                manager.resume(taskID: item.id, engine: engine,
                               folder: URL(fileURLWithPath: resume.folderPath),
                               headline: item.q, session: resume.session,
                               priorRounds: rounds, prompt: prompt,
                               imagesJPEG: jpegs)
            }
        }
        if images.isEmpty {
            dispatch([])
        } else {
            Task {
                let jpegs = await Task.detached(priority: .userInitiated) {
                    images.compactMap { Self.encodeJPEGForVision($0) }
                }.value
                dispatch(jpegs)
            }
        }
        newChat()
    }

    /// "42s" / "12m 05s" — the one elapsed format for background work: the
    /// agent card, the no-report fallback answer, and the resting notch's
    /// busy ear all read the same clock.
    static func formatAgentElapsed(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return s < 60 ? "\(s)s" : String(format: "%dm %02ds", s / 60, s % 60)
    }
}
