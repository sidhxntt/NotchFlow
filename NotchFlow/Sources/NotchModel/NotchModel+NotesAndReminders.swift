import SwiftUI
import Combine
import AppKit   // NSWorkspace — opening Notes/Reminders for a Recent capture
import Carbon.HIToolbox
import UniformTypeIdentifiers   // UTType — is a pasted file URL an image? (agent ⌘V)

@MainActor
extension NotchModel {
    // MARK: - Notes & reminders (create_note / create_reminder)

    /// Entry point injected into `CreateNoteTool` / `CreateReminderTool` for this
    /// answer round. Nothing is ever written on the model's say-so alone: the same
    /// in-answer card `ask_user` and `manage_app_settings` use shows the exact text
    /// (and, for a reminder, the exact due time) and only Confirm commits. The write
    /// itself then goes through the same services — and the same Recent row — as a
    /// hand-typed capture, so a note filed from chat is indistinguishable from one
    /// jotted into the notch.
    func handleCaptureRequest(answerID: UUID, request: CaptureRequest) async throws -> String {
        let line = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return "Error: there was no text to save." }
        guard line.count <= 4000 else {
            return "Error: that is too long to file. Keep it under 4000 characters."
        }

        // Resolve the due date BEFORE the card, so what the user approves is the
        // moment that will actually be filed — the card and the alarm can never
        // disagree. An explicit `due` wins; without one we fall back to the same
        // parsers a typed line goes through, so an English repeat phrase still repeats.
        var due: Date?
        if request.kind == .reminder {
            if let raw = request.due {
                guard let parsed = Self.parseCaptureDue(raw) else {
                    return "Error: could not read due=\"\(raw)\". Give the user's local time as YYYY-MM-DDTHH:MM."
                }
                guard parsed > Date() else {
                    return "Error: that due time is already past. Call current_datetime and pass a future local time."
                }
                due = parsed
            } else {
                due = RemindersService.futureDate(in: line)
                    ?? RemindersService.recurrenceDate(in: line)
            }
        }

        guard captureConfirmationAnswers.insert(answerID).inserted else {
            return "Error: another note or reminder is already awaiting confirmation in this answer. File them one at a time."
        }
        defer { captureConfirmationAnswers.remove(answerID) }

        let copy = captureConfirmationCopy(kind: request.kind, due: due)
        let choice = try await awaitUserChoice(
            answerID: answerID,
            question: copy.question + "\n" + line,
            options: [copy.cancel, copy.confirm],
            inlineOptions: true)
        guard choice == "The user chose: \"\(copy.confirm)\"" else {
            return "Cancelled. Nothing was saved."
        }

        switch request.kind {
        case .note:
            return await commitNoteCapture(line)
        case .reminder:
            return await commitReminderCapture(line, due: due)
        }
    }

    /// The confirmed note write, on whichever destination the user picked — Apple
    /// Notes or their Markdown folder. Same services, same Recent row as `submitNote`.
    private func commitNoteCapture(_ line: String) async -> String {
        if NoteDestination.current == .markdownFolder {
            let result: Result<String?, FileNotesError> = await withCheckedContinuation { cont in
                FileNotesService.writeNote(line) { cont.resume(returning: $0) }
            }
            switch result {
            case .success(let path):
                persistCapture(line, source: .note, link: path)
                return "Saved. The note was appended to the user's Markdown notes folder."
            case .failure(let err):
                return "Error: \(err.errorDescription ?? "couldn't write the note file.")"
            }
        }
        let result: Result<String?, NotesError> = await withCheckedContinuation { cont in
            NotesService.writeNote(line) { cont.resume(returning: $0) }
        }
        switch result {
        case .success(let noteID):
            persistCapture(line, source: .note, link: noteID)
            return "Saved. The note is now in the user's Apple Notes."
        case .failure(let err):
            return "Error: \(err.errorDescription ?? "couldn't save to Apple Notes.")"
        }
    }

    /// The confirmed reminder write. A `nil` due files a dateless reminder — it
    /// shows in the list without ringing, which is honest and better than refusing.
    private func commitReminderCapture(_ line: String, due: Date?) async -> String {
        let result: Result<String?, RemindersError> = await withCheckedContinuation { cont in
            RemindersService.createReminder(line, due: due) { cont.resume(returning: $0) }
        }
        switch result {
        case .success(let link):
            persistCapture(line, source: .reminder, link: link)
            guard let due else {
                return "Saved. The reminder is in the user's Reminders app, with no alarm time."
            }
            return "Saved. The reminder is in the user's Reminders app, due \(Self.captureDueDescription(due))."
        case .failure(let err):
            return "Error: \(err.errorDescription ?? "couldn't create the reminder.")"
        }
    }

    /// Parse the `due` the model wrote. Local wall-clock forms first (`2026-08-20T15:00`,
    /// `2026-08-20 15:00`, a bare day) — that is what the tool asks for and what a
    /// user means by "3pm" — then a full ISO-8601 stamp for models that insist on
    /// sending an offset. A bare day anchors to 9am, matching `recurrenceDate`.
    private static func parseCaptureDue(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let local = DateFormatter()
        local.locale = Foundation.Locale(identifier: "en_US_POSIX")
        local.timeZone = TimeZone.current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm",
                       "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            local.dateFormat = format
            if let date = local.date(from: text) { return date }
        }
        local.dateFormat = "yyyy-MM-dd"
        if let day = local.date(from: text) {
            return Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: text)
    }

    /// The due time as the tool result states it back to the model — the user's
    /// locale and timezone, so a follow-up sentence quotes the same moment the
    /// card showed.
    private static func captureDueDescription(_ due: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        fmt.locale = localeForInterfaceLanguage()
        return fmt.string(from: due)
    }

    /// English date strings for confirmations and the matching tool output.
    private static func localeForInterfaceLanguage() -> Foundation.Locale {
        Foundation.Locale(identifier: "en_US")
    }

    /// Card copy for a capture confirmation. A reminder with a resolved time
    /// names it in the question, so the user approves the alarm and not just the words.
    private func captureConfirmationCopy(kind: CaptureRequest.Kind,
                                         due: Date?) -> (question: String, confirm: String, cancel: String) {
        let when = due.map { Self.captureDueDescription($0) }
        let question = kind == .note ? "Save this note?"
            : (when.map { "Create a reminder for \($0)?" } ?? "Create this reminder?")
        return (question, "Save", "Cancel")
    }

    /// Route canonical setting ids onto the category that owns their UI control.
    /// Kept beside the tool handler so adding a setting means adding its write and
    /// fallback destination in the same place.
    static func appSettingsSection(for setting: String) -> String? {
        switch settingToken(setting) {
        case "model", "ai_provider", "ai_model", "api_key",
             "custom_provider_name", "custom_provider_url", "custom_provider_model",
             "custom_instructions":
            return "chat"
        case "search", "search_backend", "search_api_key":
            // Search lives inside Model now — its rows are a group on that pane.
            return "model"
        case "capture", "notes", "note_destination", "notes_folder", "copy_sense",
             "selection_context":
            return "chat"
        case "general", "launch_at_login", "dock_icon", "menu_bar_icon",
             "proxy":
            return "global"
        case "shortcuts", "summon_shortcut", "action_shortcut", "prompt_shortcut":
            return "agent"
        case "appearance", "display_placement", "live_activity",
             "hover_sensitivity", "force_click":
            return "appearance"
        case "stats", "usage", "statistics":
            return "stats"
        case "about":
            return "about"
        default:
            return nil
        }
    }

    /// Open the standalone Settings window directly on one category. This is a
    /// navigation-only capability: it writes no preference and therefore never
    /// enters the confirmation path.
    @discardableResult
    func openAppSettingsSection(_ requested: String) -> Bool {
        let section: InlineSettingsView.Section
        switch Self.settingToken(requested) {
        case "chat":       section = .chat
        case "global":     section = .global
        case "appearance": section = .appearance
        case "agent":      section = .agent
        case "stats":      section = .stats
        case "about":      section = .about
        default: return false
        }
        settingsSection = section.rawValue
        openSettings()
        return true
    }

    /// A complete, secret-safe snapshot for questions such as "what are my app
    /// settings?". Stable ids and canonical values make it easy for the model to
    /// answer in the user's language without guessing how a localized UI label
    /// maps back onto a future update call.
    func appSettingsSnapshot() -> String {
        let provider = APIKeyStore.selectedProvider
        let modelID = APIKeyStore.storedModel(for: provider)
        let shortcut = SummonHotKey.current
        let backend = APIKeyStore.preferredSearchBackend?.rawValue ?? "native"
        let providerKey = APIKeyStore.current(for: provider) == nil ? "not_configured" : "configured"
        let exaKey = APIKeyStore.currentExaKey() == nil ? "not_configured" : "configured"
        let keenableKey = APIKeyStore.currentKeenableKey() == nil ? "not_configured" : "configured"
        let anySearchKey = APIKeyStore.currentAnySearchKey() == nil ? "not_configured" : "configured"
        // Both shortcut families are scoped lists rather than scalars, so they
        // read the same way api_key/ai_model do: one line per addressable target.
        let actionShortcuts = AppShortcutAction.allCases.map {
            "action_shortcut[\($0.token)]=\(AppShortcutStore.chord(for: $0).displayString)"
        }
        let promptShortcuts = PromptShortcutStore.current.map { binding in
            let chord = binding.shortcut?.displayString ?? "unassigned"
            return "prompt_shortcut[\(chord)]=\(binding.prompt)"
        }
        return [
            "dock_icon=\(DockIconVisibility.current.rawValue)",
            "menu_bar_icon=\(MenuBarIconVisibility.current.rawValue)",
            "launch_at_login=\(LaunchAtLogin.isEnabled)",
            "display_placement=\(Self.placementToken(DisplayPlacement.current))",
            "live_activity=\(liveActivityEnabled)",
            "hover_sensitivity=\(HoverSensitivity.current.rawValue)",
            "note_destination=\(Self.noteDestinationToken(NoteDestination.current))",
            "notes_folder=\(FileNotesService.folderPath)",
            "copy_sense=\(copySenseEnabled)",
            "summon_shortcut=\(shortcut.enabled ? shortcut.displayString : "disabled")",
            "custom_instructions=\(customInstructions.isEmpty ? "(empty)" : customInstructions)",
            "proxy=\(proxyURL.isEmpty ? "auto" : proxyURL)",
            "ai_provider=\(Self.providerToken(provider))",
            "ai_model=\(modelID.isEmpty ? "default" : modelID)",
            "api_key[\(Self.providerToken(provider))]=\(providerKey)",
            "search_backend=\(backend)",
            "search_api_key[exa]=\(exaKey)",
            "search_api_key[keenable]=\(keenableKey)",
            "search_api_key[anysearch]=\(anySearchKey)",
            "custom_provider_name=\(CustomProvider.name.isEmpty ? "(empty)" : CustomProvider.name)",
            "custom_provider_url=\(CustomProvider.baseURL.isEmpty ? "(empty)" : CustomProvider.baseURL)",
            "custom_provider_model=\(CustomProvider.model.isEmpty ? "(empty)" : CustomProvider.model)",
        ].joined(separator: "\n")
        + "\n" + (actionShortcuts + promptShortcuts).joined(separator: "\n")
    }

    /// A localized, live reference for shortcut questions asked in chat. It is
    /// derived from the exact catalog rendered by Settings, so the model never
    /// needs to remember key combinations and the configurable summon chord is
    /// always the one the user currently has selected.
    func appShortcutSnapshot() -> String {
        let reference = AppShortcutReference.groups().map { group in
            let entries = group.entries.map { entry in
                let binding = entry.chords.isEmpty
                    ? (entry.note ?? L("general.shortcut.off"))
                    : entry.chords.joined(separator: " \(L("shortcuts.or")) ")
                // Editable rows carry the id an update has to scope to; a fixed
                // row carries none, which is exactly what "not editable" means.
                let scope: String
                switch entry.editable {
                case .summon: scope = " [setting=summon_shortcut]"
                case .action(let action): scope = " [setting=action_shortcut scope=\(action.token)]"
                case .prompt, nil: scope = ""
                }
                return "- \(entry.label): \(binding)\(scope)"
            }
            return (["\(group.title):"] + entries).joined(separator: "\n")
        }.joined(separator: "\n\n")

        let prompts = PromptShortcutStore.current
        let promptLines: [String] = prompts.isEmpty
            ? ["(none)"]
            : prompts.map { binding in
                let chord = binding.shortcut?.displayString ?? L("general.shortcut.off")
                return "- \(chord): \(binding.prompt) [setting=prompt_shortcut scope=\(chord)]"
            }
        return reference + "\n\n"
            + (["\(L("shortcuts.promptAction")):"] + promptLines).joined(separator: "\n")
    }

    func prepareAppSettingChange(
        _ raw: AppSettingsRequest.Change,
        defaultProvider: Provider
    ) throws -> PreparedAppSettingChange {
        let setting = Self.settingToken(raw.setting)
        let value = raw.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let scoped = raw.scope?.trimmingCharacters(in: .whitespacesAndNewlines)

        /// Each change is one plain sentence the user can read straight through —
        /// "Dock icon will change to Hidden" — not a `Label → value` pair. A `nil`
        /// display value means the field is being emptied, which is its own
        /// sentence: "will change to Clear" isn't a thing anyone says.
        func made(_ key: String, _ label: String, _ displayValue: String?,
                  _ payload: PreparedAppSettingChange.Payload,
                  noOp: Bool) -> PreparedAppSettingChange {
            let summary = displayValue.map { changeSentence(label, confirmationDisplay($0)) }
                ?? clearedSentence(label)
            return .init(key: key, summary: summary, payload: payload, isNoOp: noOp)
        }

        switch setting {
        case "dock_icon":
            guard let newValue = Self.parseDockVisibility(value) else {
                throw invalidValue(setting, "shown or hidden")
            }
            return made(setting, L("general.dockIcon"), newValue.label,
                        .dockIcon(newValue), noOp: newValue == DockIconVisibility.current)

        case "menu_bar_icon":
            guard let newValue = Self.parseMenuBarVisibility(value) else {
                throw invalidValue(setting, "shown or hidden")
            }
            return made(setting, L("general.menuBarIcon"), newValue.label,
                        .menuBarIcon(newValue), noOp: newValue == MenuBarIconVisibility.current)

        case "launch_at_login":
            guard let enabled = Self.parseBoolean(value) else { throw invalidBoolean(setting) }
            return made(setting, L("general.launchAtLogin"), localizedToggle(enabled),
                        .launchAtLogin(enabled), noOp: enabled == LaunchAtLogin.isEnabled)

        case "display_placement":
            guard let newValue = Self.parsePlacement(value) else {
                throw invalidValue(setting, "all or built_in")
            }
            return made(setting, L("general.showOn"), newValue.label,
                        .placement(newValue), noOp: newValue == DisplayPlacement.current)

        case "live_activity":
            guard let enabled = Self.parseBoolean(value) else { throw invalidBoolean(setting) }
            return made(setting, L("appearance.liveActivity"), localizedToggle(enabled),
                        .liveActivity(enabled), noOp: enabled == liveActivityEnabled)

        case "hover_sensitivity":
            guard let newValue = HoverSensitivity(rawValue: Self.settingToken(value)) else {
                throw invalidValue(setting, "low, balanced, or instant")
            }
            return made(setting, L("general.hoverSensitivity"), newValue.label,
                        .hoverSensitivity(newValue), noOp: newValue == HoverSensitivity.current)

        case "note_destination":
            guard let newValue = Self.parseNoteDestination(value) else {
                throw invalidValue(setting, "apple_notes or markdown_folder")
            }
            return made(setting, L("general.noteDestination"), newValue.label,
                        .noteDestination(newValue), noOp: newValue == NoteDestination.current)

        case "notes_folder":
            let path = (value as NSString).expandingTildeInPath
            guard path.hasPrefix("/") else {
                throw AppSettingValidationError.message("notes_folder must be an absolute path.")
            }
            return made(setting, "Notes folder", (path as NSString).abbreviatingWithTildeInPath,
                        .notesFolder(path), noOp: path == FileNotesService.folderPath)

        case "copy_sense":
            guard let enabled = Self.parseBoolean(value) else { throw invalidBoolean(setting) }
            return made(setting, L("general.copySense"), localizedToggle(enabled),
                        .copySense(enabled), noOp: enabled == copySenseEnabled)

        case "summon_shortcut":
            guard let shortcut = Self.parseShortcut(value) else {
                throw invalidValue(setting, "disabled, default, double_option, double_command, double_control, double_shift, or a chord like command+shift+k")
            }
            return made(setting, L("general.shortcut"),
                        shortcut.enabled ? shortcut.displayString : L("general.shortcut.off"),
                        .shortcut(shortcut), noOp: shortcut == SummonHotKey.current)

        case "action_shortcut":
            guard let scoped, let action = AppShortcutAction.parse(scoped) else {
                throw AppSettingValidationError.message(
                    "action_shortcut requires scope=copy_answer, regenerate, pin, new_chat, filter, picker, or detach.")
            }
            if ["default", "reset", "restore"].contains(Self.settingToken(value)) {
                return made("\(setting)[\(action.token)]", action.label,
                            action.defaultChord.displayString, .actionShortcut(action, nil),
                            noOp: AppShortcutStore.chord(for: action) == action.defaultChord)
            }
            guard let chord = Self.parseChord(value) else {
                throw invalidValue(setting, "default or a chord like command+shift+c")
            }
            // The same validator the Shortcuts pane runs, so a chord the recorder
            // would reject can't slip in through chat instead.
            if let owner = AppShortcutStore.conflictOwner(for: chord, editingAction: action) {
                throw AppSettingValidationError.message(
                    "\(chord.displayString) is already used by \(owner).")
            }
            if let owner = Self.promptShortcutOwner(for: chord) {
                throw AppSettingValidationError.message(
                    "\(chord.displayString) is already used by the prompt shortcut “\(owner)”.")
            }
            return made("\(setting)[\(action.token)]", action.label, chord.displayString,
                        .actionShortcut(action, chord),
                        noOp: AppShortcutStore.chord(for: action) == chord)

        case "prompt_shortcut":
            return try preparePromptShortcut(value: value, scope: scoped, prompt: raw.prompt)

        case "custom_instructions":
            guard value.count <= Self.customInstructionsLimit else {
                throw AppSettingValidationError.message(
                    "custom_instructions is limited to \(Self.customInstructionsLimit) characters.")
            }
            return made(setting, L("general.customInstructions"), value.isEmpty ? nil : value,
                        .customInstructions(value), noOp: value == customInstructions)

        case "proxy":
            let cleared = ["", "auto", "automatic", "system", "default"].contains(Self.settingToken(value))
            guard cleared || ProxyConfig.normalize(value) != nil else {
                throw AppSettingValidationError.message(
                    "proxy must be auto or a valid HTTP/HTTPS/SOCKS proxy host or URL.")
            }
            let proxy = cleared ? "" : value
            return made(setting, L("network.proxy"), proxy.isEmpty ? "Auto" : proxy,
                        .proxy(proxy), noOp: proxy == proxyURL)

        case "ai_provider":
            guard let provider = Self.parseProvider(value) else {
                throw invalidValue(setting, "a supported provider id")
            }
            return made(setting, L("model.provider"), provider.displayName,
                        .aiProvider(provider), noOp: provider == APIKeyStore.selectedProvider)

        case "ai_model":
            let provider = try scopedProvider(scoped, defaultProvider: defaultProvider)
            let modelID = ["", "default", "automatic", "auto"].contains(Self.settingToken(value)) ? "" : value
            let shown = modelID.isEmpty ? "Default (\(provider.defaultModel))" : modelID
            return made("\(setting)[\(provider.rawValue)]", L("model.label"), shown,
                        .aiModel(provider, modelID),
                        noOp: modelID == APIKeyStore.storedModel(for: provider))

        case "api_key":
            let provider = try scopedProvider(scoped, defaultProvider: defaultProvider)
            guard !provider.isCLI else {
                throw AppSettingValidationError.message(
                    "\(provider.displayName) uses its signed-in CLI account, not an API key setting.")
            }
            guard !APIKeyStore.hasEnvOverride(for: provider) else {
                throw AppSettingValidationError.message(
                    "\(provider.displayName)'s API key is controlled by \(provider.envVarName), so the app setting cannot override it.")
            }
            let key = Self.isClearToken(value) ? "" : value
            let keyLabel = "\(provider.displayName) \(L("model.apiKey"))"
            // The key itself never appears in the confirmation, so a stored key
            // gets its own sentence rather than a value to "change to".
            return .init(key: "\(setting)[\(provider.rawValue)]",
                         summary: key.isEmpty ? clearedSentence(keyLabel) : keySetSentence(keyLabel),
                         payload: .apiKey(provider, key),
                         isNoOp: key == APIKeyStore.stored(for: provider))

        case "search_backend":
            guard let backend = Self.parseSearchBackend(value) else {
                throw invalidValue(setting, "native, keenable, exa, or anysearch")
            }
            let shown: String
            switch backend {
            case .exa:      shown = "Exa"
            case .keenable: shown = "Keenable"
            case .anysearch: shown = "AnySearch"
            case nil:       shown = L("search.backend.native")
            }
            return made(setting, L("search.backend"), shown, .searchBackend(backend),
                        noOp: backend == APIKeyStore.preferredSearchBackend)

        case "search_api_key":
            guard let backend = Self.parseConcreteSearchBackend(scoped ?? "") else {
                throw AppSettingValidationError.message(
                    "search_api_key requires scope=exa, scope=keenable, or scope=anysearch.")
            }
            let hasEnv: Bool
            switch backend {
            case .exa:       hasEnv = APIKeyStore.hasExaEnvOverride()
            case .keenable:  hasEnv = APIKeyStore.hasKeenableEnvOverride()
            case .anysearch: hasEnv = APIKeyStore.hasAnySearchEnvOverride()
            }
            guard !hasEnv else {
                throw AppSettingValidationError.message(
                    "The \(backend.rawValue) key is controlled by an environment variable, so the app setting cannot override it.")
            }
            let key = Self.isClearToken(value) ? "" : value
            let stored: String
            switch backend {
            case .exa:       stored = APIKeyStore.storedExaKey()
            case .keenable:  stored = APIKeyStore.storedKeenableKey()
            case .anysearch: stored = APIKeyStore.storedAnySearchKey()
            }
            let keyLabel = "\(backend.rawValue.capitalized) API key"
            return .init(key: "\(setting)[\(backend.rawValue)]",
                         summary: key.isEmpty ? clearedSentence(keyLabel) : keySetSentence(keyLabel),
                         payload: .searchAPIKey(backend, key), isNoOp: key == stored)

        case "custom_provider_name":
            return made(setting, L("model.custom.name"), value.isEmpty ? nil : value,
                        .customProviderName(value), noOp: value == CustomProvider.name)

        case "custom_provider_url":
            guard value.isEmpty || CustomProvider.normalized(value) != nil else {
                throw AppSettingValidationError.message("custom_provider_url is not a valid endpoint URL.")
            }
            return made(setting, L("model.custom.url"), value.isEmpty ? nil : value,
                        .customProviderURL(value), noOp: value == CustomProvider.baseURL)

        case "custom_provider_model":
            return made("ai_model[custom]", L("model.custom.model"), value.isEmpty ? nil : value,
                        .customProviderModel(value), noOp: value == CustomProvider.model)

        default:
            throw AppSettingValidationError.message("Unsupported app setting: \(raw.setting).")
        }
    }

    /// The one setting that carries two fields: a prompt shortcut is a chord
    /// *plus* the sentence it runs on the selection. Chat can create one, retarget
    /// an existing chord, rewrite its text, or delete it — every path lands on the
    /// same stored row the Shortcuts pane edits, and on the same validation.
    private func preparePromptShortcut(value: String, scope: String?,
                                       prompt: String?) throws -> PreparedAppSettingChange {
        let list = PromptShortcutStore.current
        let existing = try scope.map { try Self.resolvePromptShortcut($0, in: list) }
        let token = Self.settingToken(value)
        let label = L("shortcuts.promptAction")

        if ["remove", "delete", "off", "none", "clear"].contains(token) {
            guard let existing else {
                throw AppSettingValidationError.message(
                    "Removing a prompt shortcut needs scope set to its chord or a distinctive part of its prompt.")
            }
            let chord = existing.shortcut?.displayString ?? L("shortcuts.promptAction.set")
            return .init(key: "prompt_shortcut[\(existing.id)]",
                         summary: removedSentence("\(label) \(chord)"),
                         payload: .promptShortcutRemoval(existing.id), isNoOp: false)
        }

        var updated = existing ?? PromptShortcut()
        if !["keep", "same", "unchanged"].contains(token) {
            guard let chord = Self.parseChord(value) else {
                throw invalidValue("prompt_shortcut",
                                   "a chord like option+s, or keep, or remove")
            }
            if let owner = AppShortcutStore.conflictOwner(for: chord) {
                throw AppSettingValidationError.message(
                    "\(chord.displayString) is already used by \(owner).")
            }
            if let owner = Self.promptShortcutOwner(for: chord, excluding: updated.id) {
                throw AppSettingValidationError.message(
                    "\(chord.displayString) already runs the prompt shortcut \"\(owner)\".")
            }
            // A prompt shortcut is global, so the chord has to be one macOS will
            // actually hand over — the same probe the recorder runs.
            if existing?.shortcut != chord,
               !HotKey.isAvailable(keyCode: chord.keyCode, modifiers: chord.modifiers) {
                throw AppSettingValidationError.message(
                    "\(chord.displayString) is claimed by macOS or another app, so it cannot be registered.")
            }
            updated.shortcut = chord
        } else if existing == nil {
            throw AppSettingValidationError.message(
                "prompt_shortcut=keep only edits an existing binding; send a chord to create one.")
        }

        if let prompt { updated.prompt = prompt }
        guard !updated.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppSettingValidationError.message(
                "A new prompt shortcut needs `prompt`: the instruction the chord runs on the selected text.")
        }
        guard updated.prompt.count <= Self.customInstructionsLimit else {
            throw AppSettingValidationError.message(
                "A prompt shortcut is limited to \(Self.customInstructionsLimit) characters.")
        }
        let chord = updated.shortcut?.displayString ?? L("shortcuts.promptAction.set")
        return .init(key: "prompt_shortcut[\(updated.id)]",
                     summary: promptRunSentence("\(label) \(chord)",
                                                confirmationDisplay(updated.prompt)),
                     payload: .promptShortcut(updated), isNoOp: existing == updated)
    }

    private func scopedProvider(_ scope: String?, defaultProvider: Provider) throws -> Provider {
        guard let scope, !scope.isEmpty else { return defaultProvider }
        guard let provider = Self.parseProvider(scope) else {
            throw AppSettingValidationError.message("Unknown provider scope: \(scope).")
        }
        return provider
    }

    private func invalidValue(_ setting: String, _ expected: String) -> AppSettingValidationError {
        .message("Invalid value for \(setting); expected \(expected).")
    }

    private func invalidBoolean(_ setting: String) -> AppSettingValidationError {
        invalidValue(setting, "true or false")
    }

    /// User-provided free text belongs in the confirmation, but never as a
    /// multi-line pseudo-row that could visually impersonate another change.
    private func confirmationDisplay(_ raw: String) -> String {
        let singleLine = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard singleLine.count > 120 else { return singleLine }
        return String(singleLine.prefix(119)) + "…"
    }

    private func localizedToggle(_ enabled: Bool) -> String {
        enabled ? "On" : "Off"
    }
}
