import SwiftUI
import Combine
import AppKit   // NSWorkspace — opening Notes/Reminders for a Recent capture
import Carbon.HIToolbox
import UniformTypeIdentifiers   // UTType — is a pasted file URL an image? (agent ⌘V)

@MainActor
extension NotchModel {
    // MARK: - Prompt shortcut naming

    /// Give a ready prompt shortcut an AI-generated display name, if it doesn't
    /// have one yet. Called when a prompt first settles into a ready row (the
    /// Settings editor's save path and the chat-driven create path both funnel
    /// here) — NOT while the user is still typing: a name is generated once per
    /// prompt, silently, and never overwrites an existing one. `displayName`
    /// falls back to the prompt meanwhile, so old shortcuts render fine even
    /// before their naming pass completes.
    ///
    /// The name is written straight back into the persisted store (and broadcast
    /// via `.promptShortcutsChanged`), so the `/` menu and the settings row both
    /// pick it up without a relaunch. Runs asynchronously — naming never blocks a
    /// keystroke or a submit — and tolerates every failure (no key, a dead
    /// network, a stub service) by simply leaving the shortcut unnamed.
    func ensurePromptShortcutName(_ shortcut: PromptShortcut) {
        let instruction = shortcut.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty,
              shortcut.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
              LicenseService.shared.state
                .allowsAsyncProductEffect(isCancelled: false)
        else { return }
        let id = shortcut.id
        guard promptShortcutNameTasks[id] == nil else { return }
        let namingTask = Task { [weak self] in
            guard let self else { return }
            defer { self.promptShortcutNameTasks[id] = nil }
            guard LicenseService.shared.state
                .allowsAsyncProductEffect(isCancelled: Task.isCancelled)
            else { return }
            let name: String
            do {
                name = try await self.ai.complete(prompt: """
                Give this prompt shortcut a short, single-phrase display name for a \
                command menu. Reply with ONLY the name — no quotes, no prefix, no \
                explanation, under 4 words. Prompt: \(instruction)
                """)
            } catch { return }
            guard LicenseService.shared.state
                .allowsAsyncProductEffect(isCancelled: Task.isCancelled)
            else { return }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'‘’"))
            guard !trimmed.isEmpty else { return }
            let capped = trimmed.count > 24 ? String(trimmed.prefix(24)) : trimmed
            var shortcuts = PromptShortcutStore.current
            guard let index = shortcuts.firstIndex(where: { $0.id == id }),
                  shortcuts[index].name == nil else { return }
            shortcuts[index].name = capped
            PromptShortcutStore.save(shortcuts)
            NotificationCenter.default.post(name: .promptShortcutsChanged, object: nil)
        }
        promptShortcutNameTasks[id] = namingTask
    }
    // MARK: - The `/` command menu

    /// One row of the `/` menu. The menu's original four rows are *modes* — a
    /// `/` on the fresh prompt pins the next line's destination, exactly what the
    /// pill and the Tab cycle already reach. A user-defined prompt shortcut is a
    /// second kind of row with the same shape: pin it and Enter runs the input
    /// through that shortcut's instruction. Codex skills are the third kind: they
    /// arm Agent and leave their explicit `$name` invocation in the input.
    enum SlashMatch: Identifiable {
        case mode(SlashCommand)
        case shortcut(PromptShortcut)
        case skill(CodexCLIService.Skill)

        var id: String {
            switch self {
            case .mode(let command): return "mode." + command.rawValue
            case .shortcut(let shortcut): return "shortcut." + shortcut.id.uuidString
            case .skill(let skill): return "skill." + skill.name
            }
        }
    }

    /// The four modes a `/` on the empty prompt can pin the next line to. The set
    /// the pill (Ask ⇄ Agent) and the Tab cycle (Ask → Note → Remind) already
    /// reach between them — this is the one surface that names all four at once,
    /// for the people who'd rather type the destination than learn two keys.
    enum SlashCommand: String, CaseIterable, Identifiable {
        case ask, capture, remind, agent

        var id: String { rawValue }

        /// The destination word — the SAME string the inline ghost and the bucket
        /// pill show, so `/note` and the hint beside the caret can't disagree.
        var title: String { L("hint." + rawValue) }

        /// What the text after the slash matches on: the English command word,
        /// a couple of natural aliases, and the command title.
        var keywords: [String] {
            let base: [String]
            switch self {
            case .ask:    base = ["ask", "chat"]
            case .capture: base = ["capture", "note", "notes", "memo"]
            case .remind: base = ["remind", "reminder", "todo"]
            case .agent:  base = ["agent", "code", "task"]
            }
            return base + [title.lowercased()]
        }
    }

    /// Is the `/` menu on screen? Only on a FRESH prompt (with a thread up, every
    /// line is a follow-up), only while the text IS the command — a leading `/`
    /// with no whitespace after it — and only while something still matches. That
    /// last clause is what keeps a real line that happens to open with a path
    /// ("/usr/local, what lives there?") from having its keys eaten: the menu
    /// drops away the moment the query stops naming a mode.
    var slashMenuOpen: Bool {
        guard turns.isEmpty, text.hasPrefix("/") else { return false }
        guard !text.dropFirst().contains(where: { $0.isWhitespace || $0.isNewline })
        else { return false }
        return !slashMatches.isEmpty
    }

    /// The rows the current query leaves standing: the four modes (in the enum's
    /// declared order so the list never reshuffles under the highlight as you
    /// type), then every *ready* prompt shortcut and enabled Codex skill after
    /// them. A bare `/` matches all of them. Agent is offered only when a local
    /// agent CLI is actually installed — the same gate the bucket pill runs on.
    /// Prompt shortcuts match on name and prompt; skills match on invocation and
    /// display name.
    var slashMatches: [SlashMatch] {
        let query = text.hasPrefix("/") ? String(text.dropFirst()).lowercased() : ""
        let modes: [SlashMatch] = SlashCommand.allCases.compactMap { command in
            guard command != .agent || agentAvailable else { return nil }
            guard query.isEmpty || command.keywords.contains(where: { $0.hasPrefix(query) })
            else { return nil }
            return .mode(command)
        }
        let shortcuts: [SlashMatch] = PromptShortcutStore.current.compactMap { shortcut in
            guard shortcut.isReady else { return nil }
            guard query.isEmpty
                  || shortcut.name?.lowercased().hasPrefix(query) == true
                  || shortcut.prompt.lowercased().hasPrefix(query) else { return nil }
            return .shortcut(shortcut)
        }
        let skills: [SlashMatch] = agentSkills.compactMap { skill in
            guard AgentEngine.codex.isAvailable else { return nil }
            guard query.isEmpty
                    || skill.name.lowercased().hasPrefix(query)
                    || skill.displayName.lowercased().hasPrefix(query) else { return nil }
            return .skill(skill)
        }
        return modes + shortcuts + skills
    }

    /// Refresh on every fresh `/` so installing or editing a skill does not need an
    /// app relaunch. Repeated keystrokes share the same in-flight request.
    func refreshAgentSkills(forceReload: Bool = false) {
        guard agentSkillsTask == nil,
              LicenseService.shared.state
                .allowsAsyncProductEffect(isCancelled: false)
        else { return }
        let cwd = (agentComposeFolder ?? lastAgentFolder
                   ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)).path
        agentSkillsTask = Task { [weak self] in
            guard LicenseService.shared.state
                .allowsAsyncProductEffect(isCancelled: Task.isCancelled)
            else { return }
            let loaded = await CodexCLIService.loadSkills(cwd: cwd,
                                                          forceReload: forceReload)
            guard let self,
                  LicenseService.shared.state
                    .allowsAsyncProductEffect(isCancelled: Task.isCancelled)
            else { return }
            // A transient app-server failure must not blank a previously good
            // menu. A successful Codex list always includes system skills, so an
            // empty response is safely treated as failure once we have a cache.
            if !loaded.isEmpty || self.agentSkills.isEmpty {
                self.agentSkills = loaded
            }
            self.agentSkillsTask = nil
            if self.slashHighlight >= self.slashMatches.count {
                self.slashHighlight = max(self.slashMatches.count - 1, 0)
            }
        }
    }

    /// ↓ / ↑ inside the menu, wrapping at both ends so the rows are a ring.
    /// Returns whether the key was consumed — `false` with no menu open, which is
    /// what lets ↑/↓ fall through to history recall exactly as before.
    func slashMenuStep(_ delta: Int) -> Bool {
        guard slashMenuOpen else { return false }
        let count = slashMatches.count
        guard count > 0 else { return false }
        slashHighlight = ((slashHighlight + delta) % count + count) % count
        return true
    }

    /// Enter / Tab on an open menu: apply the highlighted row instead of sending
    /// "/no" off to the AI.
    func confirmSlashCommand() -> Bool {
        guard slashMenuOpen else { return false }
        let matches = slashMatches
        guard matches.indices.contains(slashHighlight) else { return false }
        applySlashCommand(matches[slashHighlight])
        return true
    }

    /// Esc on an open menu: drop the command word, and the menu with it, back to
    /// the blank prompt — one step out, not a panel close.
    func dismissSlashMenu() -> Bool {
        guard slashMenuOpen else { return false }
        text = ""
        return true
    }

    /// Land on a row. Clear the command word FIRST (the field is now empty and
    /// ready for the real line), then pin where Enter will send it — that order
    /// matters, since emptying the field is exactly what clears
    /// `manualPanelOverride` and `promptShortcutMode`. The pin then behaves like
    /// a Tab override that was pressed a keystroke early: it holds through the
    /// whole line and lifts on submit. Note/Remind announce themselves through
    /// the prompt's placeholder until there's text for the inline ghost to trail;
    /// Agent flips the pill; a prompt shortcut names itself in the hint; a skill
    /// arms Codex Agent — keeping the armed model — and leaves its explicit
    /// invocation ready to extend.
    func applySlashCommand(_ match: SlashMatch) {
        text = ""
        slashHighlight = 0
        switch match {
        case .mode(let command):
            switch command {
            case .ask:
                setAgentBucket(false)
                promptShortcutMode = nil
                pinSubmitPanel(nil)
            case .capture:
                setAgentBucket(false)
                promptShortcutMode = nil
                pinSubmitPanel(.note)
            case .remind:
                setAgentBucket(false)
                promptShortcutMode = nil
                pinSubmitPanel(.reminder)
            case .agent:
                promptShortcutMode = nil
                manualPanelOverride = nil
                setAgentBucket(true)
            }
        case .shortcut(let shortcut):
            setAgentBucket(false)
            manualPanelOverride = nil
            promptShortcutMode = shortcut
        case .skill(let skill):
            promptShortcutMode = nil
            manualPanelOverride = nil
            setAgentBucket(true)
            armCodexForSkill()
            text = "$\(skill.name) "
        }
    }

    /// A skill has to run on Codex — the list comes from Codex's app-server and
    /// `$name` is its invocation syntax — so picking one arms Codex. What it must
    /// NOT do is cost the user their model: this used to blank `agentModelID`
    /// unconditionally, which dropped the chip from "GPT-5.2 high" to a bare
    /// "Codex high" AND persisted that loss to the remembered pick. Already on
    /// Codex, nothing moves. Coming from another engine, the armed model belongs
    /// to that engine, so it can't carry over — restore Codex's own last-used
    /// pick instead of falling to the CLI default.
    private func armCodexForSkill() {
        guard agentArmedEngine != .codex else { return }
        if let id = AgentModelMRU.entries(for: .codex).first?.model,
           let choice = AgentEngine.codex.modelChoices.first(where: { $0.id == id }) {
            selectAgentModel(choice)
        } else {
            agentArmedEngine = .codex
            agentModelID = nil
        }
    }

    /// The idle prompt's placeholder key. A mode pinned by `/` (or by Tab on a
    /// line since deleted) has nothing else to show on an empty field — the
    /// inline ghost only exists beside typed glyphs — so the placeholder carries
    /// it: "Write a note…", "Remind me to…". A pinned prompt shortcut shows its
    /// name in place of the key. Agent compose keeps its own.
    var idlePlaceholderKey: String {
        if agentComposeActive { return "agent.placeholder" }
        if let shortcut = promptShortcutMode { return shortcut.displayName }
        switch manualPanelOverride {
        case .note:     return "note.placeholder"
        case .reminder: return "remind.placeholder"
        default:        return "input.placeholder"
        }
    }

    /// True when Enter on the current input goes to an agent CLI: an armed
    /// compose on the idle prompt, or a follow-up on an agent thread whose
    /// session is resumable (`submit` hands that line to `continueAgentThread`).
    /// With a thread on screen the THREAD decides — an ask thread's follow-up
    /// goes to the chat model even while the Agent bucket sits armed underneath,
    /// and an agent thread's goes to its agent regardless of the bucket. The
    /// ghost hint, its colours, and `submitCurrent` all read this one switch, so
    /// the word beside the caret can never disagree with where the line lands.
    var submitGoesToAgent: Bool {
        if !turns.isEmpty { return agentThreadContinuation != nil }
        return agentComposeActive
    }

    /// The word in the inline hint — the destination spelled out: "Note" when this
    /// line will be saved to Apple Notes, "Remind" when it'll be filed in Apple
    /// Reminders, "Ask" when it'll go to the AI. Flips live with the classifier as
    /// the text crosses intents, so the hint beside the caret literally says where
    /// Enter sends the line.
    var submitLabel: String {
        // Agent-bound input (armed compose, or an agent thread's follow-up)
        // owns the hint: Enter sends the line to the agent CLI.
        if submitGoesToAgent { return L("hint.agent") }
        switch effectiveSubmitPanel {
        case .chat:              return L("hint.ask")
        // Note and Remind are ONE destination wearing two faces: the word is the
        // same "Capture" for both, and which leaf it lands in rides the dimmer
        // suffix (`submitLabelSuffix`). Two peer words with two marks read as two
        // modes to choose between — which is the choice the date detector already
        // makes for you.
        case .note, .reminder:   return L("hint.capture")
        }
    }

    /// The dimmer trailing detail rendered after `submitLabel` — the Remind
    /// recurrence ("Remind · Daily"), or nothing for Ask/Note. Ask deliberately
    /// carries no model name here: the model is already named in the pill row
    /// below the field, and repeating it in the ghost read as clutter. Kept
    /// separate from the destination word so the inline hint can paint it a shade
    /// lighter than the word: the word answers "where does Enter send this", the
    /// suffix is the softer footnote "…how often".
    var submitLabelSuffix: String {
        // The agent hint names the runner, not a chat model: "Agent Codex" /
        // "Agent Claude" — the thread's own engine on a follow-up, the armed
        // one in a compose.
        if submitGoesToAgent {
            return " " + (agentThreadContinuation ?? agentArmedEngine).displayName
        }
        switch effectiveSubmitPanel {
        case .chat:     return ""
        case .note:     return ""
        case .reminder: return submitHintSuffix
        }
    }

    /// Present-progressive "thinking" words shown beside the dots while the AI is
    /// still composing and no token has landed yet — the bare pre-stream wait. Picked
    /// at random per question so the moment of thought reads with a little mood
    /// instead of a fixed "Thinking…". Drawn from the Orange Moon imagery.
    static let thinkingWords = [
        "Gazing...", "Glowing...", "Drifting...", "Imagining...", "Whispering...",
        "Hoping...", "Waiting...", "Wandering...", "Lingering...",
        "Floating...", "Shimmering...", "Musing...", "Pondering...", "Yearning...",
        "Reminiscing...", "Fading...", "Echoing...", "Searching...", "Wondering...",
    ]

    /// The handful of rounds that already name their own job: a translation that
    /// says "Whispering…" is hiding what it is plainly doing. These are the verbs
    /// people fire at a selection — the prompt-shortcut work — so the wait word
    /// says the work instead of a mood, pinned for the whole round (no rotation).
    ///
    /// Cues are English imperative verbs, matched anywhere in the line: the
    /// instruction can sit on either side of the quoted text. Verbs
    /// only, on purpose — a question *about* a translation ("who did the best
    /// translation of Dante") keeps the mood rotation. Order is priority, so
    /// "translate and summarize this" reads "Translating…".
    ///
    /// Deliberately NOT here: write / draft / plan / brainstorm and the rest of
    /// the generation asks. Those are the ordinary conversation, and pinning every
    /// one of them to a literal verb would retire the mood words entirely.
    static let taskWords: [(word: String, orb: OrbState, cues: [String])] = [
        ("Translating...", .connecting, [
            "translate", "translating",
        ]),
        // "summar" on purpose: covers summarize / summarise / summary / summaries
        // in one cue.
        ("Summarizing...", .composing, [
            "summar", "tl;dr", "tldr", "recap",
        ]),
        ("Proofreading...", .composing, [
            "proofread", "typos",
        ]),
        ("Rewriting...", .composing, [
            "rewrite", "reword", "rephrase", "paraphrase",
        ]),
        ("Explaining...", .composing, [
            "explain", "eli5",
        ]),
    ]

    /// The pinned wait word for this question, or nil when it's an ordinary round
    /// that should roll a mood word.
    static func taskStyle(for question: String) -> (word: String, orb: OrbState)? {
        let q = question.lowercased()
        guard let match = taskWords.first(where: { entry in entry.cues.contains { q.contains($0) } })
        else { return nil }
        return (match.word, match.orb)
    }

    /// Text-only convenience for compact shortcut presentation, which shares
    /// the same task classifier but does not render an orb itself.
    static func taskWord(for question: String) -> String? {
        taskStyle(for: question)?.word
    }

    /// What the wait line's orb should wear right now: the activity's semantic
    /// mode while a tool runs, else the pinned task's own mode. Ordinary mood
    /// words and bare waits keep the reference "Thinking…." ribbon.
    var thinkingOrbState: OrbState {
        thinkingActivity != nil ? thinkingActivityOrb : pinnedThinkingOrb
    }

    /// The single source of truth for the pre-stream status line beside the dots:
    ///   • before any tool runs → empty (the wait is pure dots, no word);
    ///   • while a tool runs     → the live activity line ("Searching the web…");
    ///   • after a tool, no tool currently running → the rotating mood word.
    /// One value, so a word and an activity line can never show at once.
    var thinkingStatus: String {
        if let thinkingActivity { return thinkingActivity }
        return hasUsedToolThisRound ? thinkingWord : ""
    }

    /// The live tool-activity line on its own, exposed read-only so the streaming
    /// turn can render it as an INDEPENDENT row (under the growing answer — see
    /// `AssistantTurnView.showActivityRow`) rather than folding it into the
    /// dots/answer cross-fade. Non-nil exactly while a tool is running ("Searching
    /// the web…", "Reading the results…"); nil otherwise. Kept separate from
    /// `thinkingStatus` because the activity line must stay visible even after the
    /// model has emitted a preface — sharing the dots' `hasText` gate is what hid
    /// it mid-search.
    var currentActivity: String? { thinkingActivity }

    /// The rotating mood word on its own (no activity merged in), exposed read-only
    /// so `StreamingTurnContent`'s dots row shows *only* the mood word — never the
    /// activity label, which now lives in its own row.
    var currentThinkingWord: String { thinkingWord }

    /// Pick a fresh thinking word, avoiding an immediate repeat. A pinned task word
    /// wins outright — the round says what it's doing and never drifts off it.
    private func rerollThinkingWord(for answerID: UUID? = nil) {
        if let pinnedThinkingWord {
            thinkingWord = pinnedThinkingWord
            if let answerID { mirrorThinkingWord(for: answerID) }
            return
        }
        let pool = NotchModel.thinkingWords.filter { $0 != thinkingWord }
        thinkingWord = pool.randomElement() ?? NotchModel.thinkingWords.randomElement() ?? thinkingWord
        if let answerID { mirrorThinkingWord(for: answerID) }
    }

    /// How long each mood word lingers before rotating to the next. Slow enough to
    /// read as a settling mood, not a ticker.
    private static let thinkingWordInterval: TimeInterval = 4.0

    /// `question` is the line this round is answering: a task-shaped one (translate,
    /// summarize, …) pins the wait word to that job instead of rolling a mood word.
    func startThinkingWordRotation(for question: String = "", answerID: UUID) {
        thinkingWordTimer?.invalidate()
        thinkingActivity = nil
        thinkingStartedAt = Date()
        // Each round starts in pure-dots mode; only a tool flips it into word mode.
        hasUsedToolThisRound = false
        if let taskStyle = Self.taskStyle(for: question) {
            pinnedThinkingWord = taskStyle.word
            pinnedThinkingOrb = taskStyle.orb
        } else {
            pinnedThinkingWord = nil
            pinnedThinkingOrb = .composing
        }
        rerollThinkingWord(for: answerID)
        mirrorThinkingState(for: answerID)
        // A pinned word is the whole round's word — nothing to rotate.
        guard pinnedThinkingWord == nil else {
            thinkingWordTimer = nil
            return
        }
        let t = Timer(timeInterval: NotchModel.thinkingWordInterval, repeats: true) { [weak self] _ in
            self?.rerollThinkingWord(for: answerID)
        }
        t.tolerance = 0.4
        RunLoop.main.add(t, forMode: .common)
        thinkingWordTimer = t
    }

    func stopThinkingWordRotation(for answerID: UUID) {
        clearRuntimeThinkingState(for: answerID)
        guard thinkingAnswerID == answerID else { return }
        thinkingWordTimer?.invalidate()
        thinkingWordTimer = nil
        thinkingActivity = nil
        thinkingStartedAt = nil
        hasUsedToolThisRound = false
        pinnedThinkingWord = nil
        pinnedThinkingOrb = .composing
    }

    /// The first-token freeze: stop the mood-word rotation (the pre-stream wait
    /// is over) but leave `thinkingActivity` and the elapsed clock ALONE. This is
    /// what the reveal flush calls — it fires on every flush, which can happen
    /// while a tool from the same round is still running (the model spoke a
    /// preface before searching), and clearing the activity there is exactly what
    /// used to kill the "Searching the web…" line the moment any text landed.
    /// Terminal paths (finish/error/stop) use `stopThinkingWordRotation(for:)`, which
    /// clears everything.
    func freezeThinkingWord(for answerID: UUID) {
        guard thinkingAnswerID == answerID else { return }
        thinkingWordTimer?.invalidate()
        thinkingWordTimer = nil
    }

    /// Funnel the harness's activity label into the single `thinkingStatus` value. A
    /// non-nil label means a tool is running — which also latches the round into "word
    /// mode" so that after the tool clears, the wait shows the mood word (not back to
    /// bare dots). `nil` clears the live line, falling back to the mood word.
    func setThinkingActivity(_ label: String?, orb: OrbState = .composing) {
        if label != nil { hasUsedToolThisRound = true }
        thinkingActivity = label
        thinkingActivityOrb = orb
        if let thinkingAnswerID { mirrorThinkingState(for: thinkingAnswerID) }
    }

    /// Copy the panel's live wait state onto the answer turn itself. The turn is
    /// the unit mirrored into a detached window, so both surfaces consume the
    /// same values instead of the window inventing its own fallback state.
    private func mirrorThinkingState(for answerID: UUID) {
        updateRuntimeTurn(answerID) { turn in
            turn.thinkingWord = thinkingWord
            turn.toolActivity = thinkingActivity
            turn.thinkingOrbState = thinkingOrbState
            turn.thinkingStartedAt = thinkingStartedAt
        }
    }

    /// Word rotation must not overwrite a detached tool's semantic orb. The
    /// detached harness mirrors that orb directly; only the word changes on this
    /// timer tick.
    private func mirrorThinkingWord(for answerID: UUID) {
        updateRuntimeTurn(answerID) { $0.thinkingWord = thinkingWord }
    }

    private func clearRuntimeThinkingState(for answerID: UUID) {
        updateRuntimeTurn(answerID) { turn in
            turn.thinkingStartedAt = nil
            turn.pendingQuestion = nil
        }
    }

    /// Mutate runtime-only presentation state everywhere this answer may live:
    /// the panel, its in-flight snapshot, and the detached window mirror.
    func updateRuntimeTurn(_ answerID: UUID,
                                   _ update: (inout Turn) -> Void) {
        if let i = turns.firstIndex(where: { $0.id == answerID }) {
            update(&turns[i])
        }
        guard let roundIndex = inFlightRounds.firstIndex(where: { $0.answerID == answerID }),
              let turnIndex = inFlightRounds[roundIndex].thread.firstIndex(where: {
                  $0.id == answerID
              }) else { return }
        update(&inFlightRounds[roundIndex].thread[turnIndex])
        let round = inFlightRounds[roundIndex]
        detachedThreadStores[round.threadID]?.turns = round.thread
    }
}
