import SwiftUI
import AppKit

@MainActor
extension NotchBody {
    // MARK: - Agent to Codex (XII: agent-to-Codex)

    /// An engine's real brand mark, tinted like the surrounding text — the vendors'
    /// own glyphs, never an SF-symbol stand-in. Shared with the ⌘⇧I agent picker
    /// (`AgentEngineMark`), which lists the same engines' models.
    func agentEngineMark(_ engine: AgentEngine, size: CGFloat,
                                    tint: Color) -> some View {
        AgentEngineMark(engine: engine, size: size, tint: tint)
    }

    /// The bucket row under the idle prompt — fixed chrome once a local agent
    /// CLI is installed: the Ask|Agent pill, and (while Agent is armed) the
    /// compose chips unfurled beside it. The pill is the panel's one explicit
    /// top-level choice; everything the classifier does (note/remind routing)
    /// happens invisibly inside its Ask half.
    var bucketRow: some View {
        HStack(spacing: 6) {
            // Chat owns its own compact destination control. Agent has a dedicated
            // top-level workspace tab, so the composer never exposes a second way
            // to arm an agent run here.
            if !recentListShown {
                BucketTogglePill(model: model)
                if model.effectiveSubmitPanel == .chat {
                    // Notes and reminders never invoke an AI model, so their
                    // compose row should not advertise or offer one. The chip
                    // belongs only to Ask; switching back brings it back.
                    askModelChip
                        .transition(.opacity)
                }
            }
            // The Recent (+ pin) cluster rides this row's trailing edge — on the
            // same line as the Ask|Agent pill, pushed right by the spacer — instead
            // of hovering a row up in the input's trailing slot. It STAYS while
            // typing: the input's trailing slot carries no send hint any more, so
            // hiding the chevron mid-sentence only dropped the way into Recent and
            // left a hole on that edge. Handed over to the manage bar's trailing edge
            // once Recent is up (see `manageBar`), so the way out of the list sits in
            // the bottom-right corner.
            if !recentListShown {
                let cluster = idleTrailingCluster()
                // The first-launch-after-update cue rides the same trailing edge,
                // just inside the Recent chevron — glass beside glass. It keeps the
                // row alive on its own when the cluster has nothing to draw (a first
                // run with no history and no pin).
                // A waiting build says so in words right here, on the home page —
                // not as a dot behind the ⋯ menu (see `updateCue`).
                let pending = model.hasText ? nil : pendingUpdateVersion
                // One chip on that edge, never two: an update waiting outranks the
                // notes for the build already running, so "What's New" stands down
                // until the update is taken.
                let showsCue = !model.hasText && whatsNew.unseenVersion != nil
                                && pending == nil
                if !cluster.isEmpty || showsCue || pending != nil {
                    Spacer(minLength: 8)
                    if let pending {
                        updateCue(version: pending, height: 30,
                                  hovered: $updateCueIdleHovered)
                            .transition(.scale(scale: 0.7).combined(with: .opacity))
                    }
                    if showsCue {
                        whatsNewCue
                            .transition(.scale(scale: 0.7).combined(with: .opacity))
                    }
                    if !cluster.isEmpty { cluster }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 10)
        // The second grip on the idle page (see `detachGrip`): the bucket row's
        // free strip between the pill and the Recent cluster pulls the whole
        // prompt out into its own window.
        .background(detachGrip)
    }

    /// Whether the bucket row still has anything to draw. With Recent expanded the
    /// Ask|Agent pill and its compose chips hide, and the Recent cluster moves down
    /// to the manage bar, so the row can end up empty — and an empty row would still
    /// spend its 10pt top padding, padding out the immersive header for nothing.
    var bucketRowHasContent: Bool {
        !recentListShown && !model.usingPromptShortcutContext
    }

    /// The idle prompt's Recent-list disclosure (and, once pinned, the tack) as a
    /// glass cluster, configured against the model. Built here once and hosted in
    /// one of two places: the bucket row's trailing edge when a local agent CLI
    /// gives us that row, else the input row's own trailing slot.
    func idleTrailingCluster(chipSize: CGFloat = 30) -> IdleTrailingCluster {
        IdleTrailingCluster(
            pinned: model.isAnswerPinned,
            recentOpen: model.showHistory,
            showsRecent: recentHasContent,
            runningCount: model.agentComposeActive ? agentManager.runningTasks.count : 0,
            chipSize: chipSize,
            togglePin: {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                    model.toggleAnswerPin()
                }
            },
            toggleRecent: {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                    model.showHistory.toggle()
                    // Closing via the chevron drops any keyboard highlight; opening
                    // starts un-highlighted (the caret stays in the input).
                    model.highlightedHistoryIndex = nil
                }
            }
        )
    }

    /// The Ask bucket's model chip — the Ask-side twin of the agent compose chips,
    /// riding the same slot beside the pill. It names the model in effect and, on
    /// tap, opens the Ask recents quick menu (`AskRecentModelPickerView`) — the
    /// agent card's little glass sibling listing the five most recently used
    /// models, instead of detouring through the full cross-provider catalog (which
    /// stays reachable from Settings). The popover hangs off the chip itself — a
    /// menu should pop from the control that opened it, not float detached under
    /// the island the way the keyboard-summoned pickers do. Reads the selection
    /// straight from the store like the settings chip, so the chip can never show
    /// a stale model.
    ///
    /// With nothing configured it names the gap instead — "Choose model…" in the
    /// danger ink, the one chip in the row that is reporting a problem rather than
    /// a setting. It used to print the selected provider's *default* model there,
    /// which meant a fresh install advertised "Gpt-5.5" with no key behind it: the
    /// one place that should have said "set this up" was the place claiming it
    /// already was.
    ///
    /// Where the tap goes then depends on what's already on the machine. A signed-in
    /// `codex` / `claude` / `grok` / `cmd` / `pi` CLI is a *working backend that
    /// needs no key* — so
    /// if any are there, the menu lists them (tagged CLI) and one click is the whole
    /// setup. Only with none of them does it fall through to Settings.
    private var askModelChip: some View {
        AgentComposeChip(title: model.isConfigured
                            ? ModelRatings.prettyName(for: selectedModelID,
                                                      provider: selectedProvider)
                            : L("model.choose"),
                         tint: model.isConfigured ? nil : Tokens.danger.opacity(0.62),
                         action: {
            if model.isConfigured || !availableCLIProviders.isEmpty {
                model.showAskModelPicker.toggle()
            } else {
                model.settingsSection = "Model"
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                    model.openSettings()
                }
            }
        }, icon: { EmptyView() })
        .fixedSize()
        // Hung in its own clear panel, exactly like the `/` card — the chip's
        // screen rect is re-read on every layout pass, so a pick that re-titles
        // (and resizes) the chip carries the card with it instead of stranding it.
        .modifier(MenuCardWindow(
            open: model.showAskModelPicker,
            onDismiss: { _ in model.showAskModelPicker = false },
            card: {
                AnyView(AskRecentModelPickerView(
                    rows: askRecentModelRows,
                    selectedProvider: selectedProvider,
                    selectedModelID: selectedModelID,
                    onSelect: { row in
                        ModelCatalogStore.select(provider: row.provider, model: row.id)
                    },
                    // "More models…" hands off to Settings' Model pane — the full
                    // cross-provider catalog the recents menu deliberately doesn't carry.
                    onMoreModels: {
                        model.settingsSection = "Model"
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                            model.openSettings()
                        }
                    },
                    onDone: { model.showAskModelPicker = false })
                    .preferredColorScheme(.dark)
                    .menuCardBackground())
            }))
    }

    /// The rows the Ask chip's quick menu shows: the selection in effect first, then
    /// the most recently asked-through models (`AskModelMRU`), skipping duplicates
    /// and providers that can't serve right now, capped at the MRU's five. No
    /// padding: fewer than five recents just means a shorter menu — every row is
    /// something the user actually used or picked, never a catalog filler.
    ///
    /// With nothing configured there are no recents worth listing — the "selection
    /// in effect" is a provider default nobody chose and every MRU slot is empty —
    /// so the menu becomes the CLI offer instead: whichever of the local agent CLIs
    /// is installed and signed in, ready to use as-is.
    private var askRecentModelRows: [AskRecentModelPickerView.Row] {
        guard model.isConfigured else {
            return availableCLIProviders.map {
                AskRecentModelPickerView.Row(provider: $0,
                                             id: APIKeyStore.effectiveModel(for: $0)
                                                 ?? $0.defaultModel)
            }
        }
        var rows = [AskRecentModelPickerView.Row(provider: selectedProvider, id: selectedModelID)]
        for e in AskModelMRU.entries {
            let row = AskRecentModelPickerView.Row(provider: e.provider, id: e.model)
            guard !rows.contains(row), ModelCatalogStore.ready(e.provider) else { continue }
            rows.append(row)
        }
        return Array(rows.prefix(AskModelMRU.capacity))
    }

    /// The agent CLIs that are installed *and* signed in right now — real backends
    /// that need no key, so with nothing else configured they are the shortest way
    /// out of an unusable Ask. Each service's `isAvailable` is a warm cache after
    /// the launch warm-up, so reading it during a render costs nothing.
    private var availableCLIProviders: [Provider] {
        var out: [Provider] = []
        if ClaudeCLIService.isAvailable { out.append(.claudeCode) }
        if CodexCLIService.isAvailable { out.append(.codex) }
        if GrokCLIService.isAvailable { out.append(.grokCode) }
        if PiCLIService.isAvailable { out.append(.piCode) }
        return out
    }

    /// The folder chip menu's rows: the project in effect first, then the other
    /// recently worked-in ones (`AgentFolderMRU`, dead paths already dropped). No
    /// padding — every row is a project the user actually worked in.
    private var agentFolderRows: [URL] {
        var rows: [URL] = []
        if let current = model.agentComposeFolder { rows.append(current) }
        for f in AgentFolderMRU.entries where !rows.contains(f) { rows.append(f) }
        return Array(rows.prefix(AgentFolderMRU.capacity))
    }

    /// The agent compose chips beside the pill: the task's three facts as glass
    /// chips in the clipboard presets' own language — the folder the agent will
    /// work in (tap to re-pick; "choose" until one has ever been picked), the
    /// model (one menu mixing every engine's entries; picking a model picks its
    /// engine), and the reasoning effort. The way out is the pill's Ask half.
    /// The input above is composing the task description; Enter starts the run.
    private var agentComposeChips: some View {
        HStack(spacing: 6) {
            AgentComposeChip(title: Self.compactFolderTitle(
                                        model.agentComposeFolder?.lastPathComponent)
                                    ?? L("agent.folder.choose"),
                                action: {
                // With projects to switch between, the chip is a menu like its
                // model neighbours; with nothing to list (first-ever agent, or a
                // single remembered project) a one-row menu would be theatre —
                // go straight to the file panel.
                if agentFolderRows.count > 1 {
                    model.showAgentFolderPicker = true
                } else {
                    model.pickAgentFolder()
                }
            }, icon: { EmptyView() })
            .fixedSize()
            // Same chip-hung card as the model menus, in its own clear panel.
            .modifier(MenuCardWindow(
                open: model.showAgentFolderPicker,
                onDismiss: { _ in model.showAgentFolderPicker = false },
                card: {
                    AnyView(AgentFolderPickerView(
                        folders: agentFolderRows,
                        selected: model.agentComposeFolder,
                        onSelect: { model.selectAgentFolder($0) },
                        onBrowse: { model.pickAgentFolder() },
                        onDone: { model.showAgentFolderPicker = false })
                        .preferredColorScheme(.dark)
                        .menuCardBackground())
                }))

            // Model + reasoning effort read as ONE chip — "Claude Opus xhigh".
            // Clicking it opens the same model+effort quick picker ⌘⇧I summons,
            // not an NSMenu — so both front doors land on one card and behave
            // identically.
            // The title tracks the armed pick LIVE — a model or effort chosen in
            // the open card re-titles the chip on the spot, no waiting for the
            // card to close. The card itself stays exactly where it opened: it
            // doesn't hang off the chip (whose width moves with the title) but
            // off the frozen point below — see `agentChipAnchorX`.
            AgentComposeChip(title: agentModelEffortTitle, action: {
                model.showAgentPicker = true
            }, icon: { EmptyView() })
            .fixedSize()
            // The card hangs off a 1pt probe pinned under the chip's centre —
            // a point, not the chip's own frame. Same place the card has always
            // opened (bottom edge, centred), but re-titling the chip can't drag
            // it sideways mid-pick. Placed with `.position` (a real layout
            // placement, which is what the probe reports as its screen rect) —
            // `.offset` is a render-time transform the probe's own frame ignores,
            // which would land the card at the chip's leading edge instead. In
            // the background, so the chip's own button keeps every click.
            .background {
                GeometryReader { g in
                    Color.clear
                        .frame(width: 1, height: 1)
                        .modifier(MenuCardWindow(
                            open: model.showAgentPicker,
                            centered: true,
                            onDismiss: { _ in model.showAgentPicker = false },
                            card: {
                                AnyView(AgentModelPickerView(
                                    choices: AgentEngine.available.flatMap(\.modelChoices),
                                    selectedEngine: model.agentArmedEngine,
                                    selectedModelID: model.agentModelID,
                                    selectedEffort: model.agentEffort,
                                    onSelectModel: { choice in
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                            model.selectAgentModel(choice)
                                        }
                                    },
                                    // Same spring as the model pick, so the chip's title
                                    // (and width) catches the new effort as a glide
                                    // rather than a jump.
                                    onSelectEffort: { effort in
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                            model.agentEffort = effort
                                        }
                                    },
                                    onDone: { model.showAgentPicker = false })
                                    // Resolve the Claude aliases to concrete model names ("opus" →
                                    // "Claude Opus 4.8") so the rows can say what they actually run;
                                    // cached + TTL'd, so this is usually a no-op, and the labels fill
                                    // in reactively when a real probe lands.
                                    .task { catalog.resolveClaudeAliases() }
                                    .preferredColorScheme(.dark)
                                    .menuCardBackground())
                            }))
                        // The chip's bottom-centre — where the card has always
                        // hung from — held at the width the chip had when it opened.
                        .position(x: agentChipAnchorX ?? g.size.width / 2,
                                  y: g.size.height)
                        // Track the centre while the card is down; hold it still
                        // for as long as the card is up.
                        .onChange(of: g.size.width, initial: true) { _, w in
                            guard !model.showAgentPicker || agentChipAnchorX == nil
                            else { return }
                            agentChipAnchorX = w / 2
                        }
                        // Catch up once the card is gone: the title (and with it
                        // the chip's width) may well have changed under it, and
                        // the next open has to hang off the NEW centre.
                        .onChange(of: model.showAgentPicker) { _, open in
                            if !open { agentChipAnchorX = g.size.width / 2 }
                        }
                }
            }
        }
        .onChange(of: utilityOverlaySession.protectsPanelInteraction) { _, protectsPanel in
            model.setUtilityOverlayPresented(protectsPanel)
        }
        .onDisappear {
            model.setUtilityOverlayPresented(false)
        }
    }

    /// The folder chip's title, middle-truncated in the STRING rather than by
    /// the Text: the chip is `.fixedSize()` (without it the row's fixed-size
    /// menu chips squeeze it and SwiftUI trims even a short name to "not…"),
    /// so a pathological folder name must be bounded here instead.
    private static func compactFolderTitle(_ name: String?) -> String? {
        guard let name else { return nil }
        guard name.count > 22 else { return name }
        return name.prefix(12) + "…" + name.suffix(9)
    }

    /// The model chip's title: the explicit pick's label, or the engine's plain
    /// name when the run rides the CLI-config default. The vendor family word is
    /// dropped the same way the picker's rows drop it — "Claude Opus 4.8" reads
    /// as "Opus 4.8", "GPT-5.1-Codex" as "5.1-Codex" — so the merged chip stays a
    /// tight "Opus 4.8 xhigh" instead of restating the vendor on every run.
    private var agentModelTitle: String {
        let engine = model.agentArmedEngine
        if let id = model.agentModelID,
           let choice = engine.modelChoices.first(where: { $0.id == id }) {
            return Self.strippingModelFamily(choice.label, engine: engine)
        }
        return engine.displayName
    }

    /// Drop the leading vendor family word from a model label — codex labels are
    /// "GPT-…", claude labels "Claude …", so the chip shows only the model. Mirrors
    /// `AgentModelPickerView.shortLabel`; labels without the prefix pass through.
    private static func strippingModelFamily(_ label: String, engine: AgentEngine) -> String {
        let family: String
        switch engine {
        case .codex:  family = "gpt"
        case .claude: family = "claude"
        case .grok:   family = "grok"
        // Command Code fronts a dozen labs — there is no one family word to drop,
        // and the vendor is exactly what tells its models apart. pi fronts more
        // still (a dozen labs across several accounts), for the same reason.
        case .commandCode, .pi: return label
        }
        for sep in ["-", " "] {
            let p = family + sep
            if label.lowercased().hasPrefix(p), label.count > p.count {
                return String(label.dropFirst(p.count))
            }
        }
        return label
    }

    /// The merged model+effort chip's title: the model on its own while effort
    /// rides its CLI default, or "model effort" once a level is picked — the
    /// effort trails as the bare lowercase level (`xhigh`), no separator, no
    /// dash, so the line stays quiet and only names the effort when it's set.
    private var agentModelEffortTitle: String {
        guard let effort = model.agentEffort else { return agentModelTitle }
        return "\(agentModelTitle) \(effort.rawValue)"
    }

    /// The panel presence of agent runs — one quiet line per task, never a card.
    /// Presence and reading are separate things: a bead and one phrase, nothing
    /// else. While a run works the line is the live activity and the leading slot
    /// breathes a soft tint pulse; once it settles a glass bead lights the slot and the line
    /// falls back to the task's own name. A tap opens the run's Recent record in the result view — the
    /// same conversation surface every other thread reads in. Outcome prose,
    /// clocks, file counts and the work trail all belong in that record, not
    /// here: this is a glance surface.
    var agentStatusRows: some View {
        // spacing 0 so a stack of agent rows keeps the SAME vertical rhythm as the
        // Recent rows below (each row carries its own 9pt vertical pad — see
        // `agentStatusRow`), instead of an airier gap that reads as "bigger padding".
        VStack(alignment: .leading, spacing: 0) {
            // `tasks` is stored in spawn order; show it newest-first so the most
            // recently started run sits at the top of the list.
            ForEach(agentManager.tasks.reversed()) { task in
                agentStatusRow(task)
            }
        }
    }
}
