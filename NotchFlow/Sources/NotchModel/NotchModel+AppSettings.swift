import SwiftUI
import Combine
import AppKit   // NSWorkspace — opening Notes/Reminders for a Recent capture
import Carbon.HIToolbox
import UniformTypeIdentifiers   // UTType — is a pasted file URL an image? (agent ⌘V)

@MainActor
extension NotchModel {
    // MARK: - Natural-language app settings

    /// A validated setting update. Validation happens for the whole batch before
    /// the confirmation card appears, so the card never promises a change that we
    /// already know is malformed. The payload retains typed values for the commit;
    /// `summary` is deliberately safe to show (API keys are never echoed).
    struct PreparedAppSettingChange {
        enum Payload {
            case dockIcon(DockIconVisibility)
            case menuBarIcon(MenuBarIconVisibility)
            case launchAtLogin(Bool)
            case placement(DisplayPlacement)
            case liveActivity(Bool)
            case hoverSensitivity(HoverSensitivity)
            case noteDestination(NoteDestination)
            case notesFolder(String)
            case copySense(Bool)
            case shortcut(SummonHotKey)
            /// `nil` chord ⇒ restore the shipped default for that action.
            case actionShortcut(AppShortcutAction, ShortcutChord?)
            /// The whole resulting row — new binding or edited existing one.
            case promptShortcut(PromptShortcut)
            case promptShortcutRemoval(UUID)
            case customInstructions(String)
            case proxy(String)
            case aiProvider(Provider)
            case aiModel(Provider, String)
            case apiKey(Provider, String)
            case searchBackend(APIKeyStore.SearchBackend?)
            case searchAPIKey(APIKeyStore.SearchBackend, String)
            case customProviderName(String)
            case customProviderURL(String)
            case customProviderModel(String)
        }

        let key: String
        let summary: String
        let payload: Payload
        let isNoOp: Bool
    }

    enum AppSettingValidationError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let message) = self { return message }
            return nil
        }
    }

    /// Entry point injected into `ManageAppSettingsTool` for this answer round.
    /// Listing is read-only and returns immediately. Every update — including a
    /// multi-setting batch — suspends on the same in-answer choice card used by
    /// `ask_user`, then commits only when the positive option is tapped.
    func handleAppSettingsRequest(answerID: UUID,
                                  request: AppSettingsRequest) async throws -> String {
        if request.action == .list { return appSettingsSnapshot() }
        if request.action == .shortcuts { return appShortcutSnapshot() }
        if request.action == .open {
            guard let requested = request.section,
                  openAppSettingsSection(requested) else {
                return "Error: section must be model, search, notes, general, appearance, shortcuts, or about."
            }
            return "Opened the \(requested) settings page so the user can review the available choices."
        }

        guard settingsConfirmationAnswers.insert(answerID).inserted else {
            return "Error: another settings update is already awaiting confirmation in this answer. Combine all requested changes into one manage_app_settings call."
        }
        defer { settingsConfirmationAnswers.remove(answerID) }

        var prepared: [PreparedAppSettingChange] = []
        var seen = Set<String>()
        let batchProvider = request.changes
            .first { Self.settingToken($0.setting) == "ai_provider" }
            .flatMap { Self.parseProvider($0.value) }
            ?? APIKeyStore.selectedProvider
        for raw in request.changes {
            let change: PreparedAppSettingChange
            do {
                change = try prepareAppSettingChange(raw, defaultProvider: batchProvider)
            } catch {
                // An unsupported value is most useful when it lands the user on
                // the actual control and its real choices. This also catches a
                // model that attempted `update` instead of the advertised `open`
                // fallback, so the UX does not depend on perfect tool selection.
                if let section = Self.appSettingsSection(for: raw.setting) {
                    _ = openAppSettingsSection(section)
                    return "\(error.localizedDescription) Opened the \(section) settings page so the user can review the available choices."
                }
                throw error
            }
            guard seen.insert(change.key).inserted else {
                throw AppSettingValidationError.message(
                    "The same setting appears more than once in this update: \(change.key).")
            }
            prepared.append(change)
        }

        let effective = prepared.filter { !$0.isNoOp }
        guard !effective.isEmpty else {
            return "No change was needed; those settings already have the requested values."
        }

        let copy = appSettingsConfirmationCopy()
        let lines = effective.map(\.summary).joined(separator: "\n")
        let choice = try await awaitUserChoice(
            answerID: answerID,
            question: copy.question + "\n" + lines,
            options: [copy.cancel, copy.confirm],
            inlineOptions: true)
        guard choice == "The user chose: \"\(copy.confirm)\"" else {
            return "Cancelled. No settings were changed."
        }

        // Login-item registration is the only commit that can fail. Do it before
        // the infallible UserDefaults writes so a refusal cannot leave half a batch
        // applied after the user approved the whole summary.
        for change in effective {
            if case .launchAtLogin(let enabled) = change.payload {
                try LaunchAtLogin.setEnabled(enabled)
            }
        }

        var refreshAI = false
        for change in effective {
            switch change.payload {
            case .dockIcon(let value):
                DockIconVisibility.current = value
                NotificationCenter.default.post(name: .dockIconVisibilityChanged, object: nil)
            case .menuBarIcon(let value):
                MenuBarIconVisibility.current = value
                NotificationCenter.default.post(name: .menuBarIconVisibilityChanged, object: nil)
            case .launchAtLogin:
                break // committed first because this one can throw
            case .placement(let value):
                DisplayPlacement.current = value
                NotificationCenter.default.post(name: .displayPlacementChanged, object: nil)
            case .liveActivity(let enabled):
                liveActivityEnabled = enabled
            case .hoverSensitivity(let value):
                applyHoverSensitivity(value)
            case .noteDestination(let value):
                NoteDestination.current = value
            case .notesFolder(let path):
                FileNotesService.folderPath = path
            case .copySense(let enabled):
                copySenseEnabled = enabled
            case .shortcut(let value):
                SummonHotKey.current = value
                NotificationCenter.default.post(name: .summonHotKeyChanged, object: nil)
            case .actionShortcut(let action, let chord):
                if let chord {
                    AppShortcutStore.set(chord, for: action)
                } else {
                    AppShortcutStore.reset(action)
                }
                NotificationCenter.default.post(name: .appShortcutsChanged, object: nil)
            case .promptShortcut(let binding):
                // Re-read the list per change: a batch may touch several rows, and
                // each write must land on the state its predecessors left behind.
                var list = PromptShortcutStore.current
                if let index = list.firstIndex(where: { $0.id == binding.id }) {
                    list[index] = binding
                } else {
                    list.append(binding)
                }
                PromptShortcutStore.save(list)
                NotificationCenter.default.post(name: .promptShortcutsChanged, object: nil)
                // A freshly-settled prompt (created or edited here, or in Settings)
                // earns its AI display name once — `ensurePromptShortcutName` only
                // writes when a name is still missing.
                if binding.isReady { ensurePromptShortcutName(binding) }
            case .promptShortcutRemoval(let id):
                var list = PromptShortcutStore.current
                list.removeAll { $0.id == id }
                PromptShortcutStore.save(list)
                NotificationCenter.default.post(name: .promptShortcutsChanged, object: nil)
            case .customInstructions(let value):
                customInstructions = value
            case .proxy(let value):
                proxyURL = value
            case .aiProvider(let provider):
                APIKeyStore.selectedProvider = provider
                refreshAI = true
            case .aiModel(let provider, let modelID):
                APIKeyStore.saveModel(modelID, for: provider)
                if !modelID.isEmpty { AskModelMRU.record(provider: provider, model: modelID) }
                refreshAI = true
            case .apiKey(let provider, let key):
                APIKeyStore.save(key, for: provider)
                refreshAI = true
            case .searchBackend(let backend):
                APIKeyStore.preferredSearchBackend = backend
                refreshAI = true
            case .searchAPIKey(let backend, let key):
                switch backend {
                case .exa:      APIKeyStore.saveExaKey(key)
                case .keenable: APIKeyStore.saveKeenableKey(key)
                case .anysearch: APIKeyStore.saveAnySearchKey(key)
                }
                refreshAI = true
            case .customProviderName(let value):
                CustomProvider.name = value
                refreshAI = true
            case .customProviderURL(let value):
                CustomProvider.baseURL = value
                refreshAI = true
            case .customProviderModel(let value):
                CustomProvider.model = value
                refreshAI = true
            }
        }
        if refreshAI {
            NotificationCenter.default.post(name: .aiBackendChanged, object: nil)
        }
        return "Settings updated after confirmation: "
            + effective.map(\.summary).joined(separator: "; ") + "."
    }
}
