import SwiftUI
import Combine
import AppKit   // NSWorkspace — opening Notes/Reminders for a Recent capture
import Carbon.HIToolbox
import UniformTypeIdentifiers   // UTType — is a pasted file URL an image? (agent ⌘V)

@MainActor
extension NotchModel {
    // MARK: - Confirmation sentences
    //
    // A pending change is written as one ordinary sentence — "Dock icon will
    // change to Hidden" — because the confirmation card reads as a question the
    // app is asking, not as a table of fields. Four shapes cover every setting:
    // a new value, an emptied field, a deleted binding, and a stored key (whose
    // value is never shown).

    func changeSentence(_ label: String, _ value: String) -> String {
        "\(label) will change to \(value)"
    }

    func clearedSentence(_ label: String) -> String {
        "\(label) will be cleared"
    }

    func removedSentence(_ label: String) -> String {
        "\(label) will be removed"
    }

    func keySetSentence(_ label: String) -> String {
        "\(label) will be set (key hidden)"
    }

    func promptRunSentence(_ label: String, _ prompt: String) -> String {
        "\(label) will run: \(prompt)"
    }

    func appSettingsConfirmationCopy() -> (question: String, confirm: String, cancel: String) {
        ("Confirm these setting changes?", "Confirm", "Cancel")
    }

    static func settingToken(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    static func parseBoolean(_ raw: String) -> Bool? {
        switch settingToken(raw) {
        case "true", "on", "yes", "enabled", "enable", "show", "shown": return true
        case "false", "off", "no", "disabled", "disable", "hide", "hidden": return false
        default: return nil
        }
    }

    static func parseDockVisibility(_ raw: String) -> DockIconVisibility? {
        switch settingToken(raw) {
        case "shown", "show", "visible", "on", "true": return .shown
        case "hidden", "hide", "invisible", "off", "false": return .hidden
        default: return nil
        }
    }

    static func parseMenuBarVisibility(_ raw: String) -> MenuBarIconVisibility? {
        switch settingToken(raw) {
        case "shown", "show", "visible", "on", "true": return .shown
        case "hidden", "hide", "invisible", "off", "false": return .hidden
        default: return nil
        }
    }

    static func parsePlacement(_ raw: String) -> DisplayPlacement? {
        switch settingToken(raw) {
        case "all", "all_screens", "every_screen": return .all
        case "built_in", "builtin", "main", "main_screen": return .builtIn
        default: return nil
        }
    }

    static func placementToken(_ placement: DisplayPlacement) -> String {
        placement == .all ? "all" : "built_in"
    }

    static func parseNoteDestination(_ raw: String) -> NoteDestination? {
        switch settingToken(raw) {
        case "apple_notes", "notes", "apple": return .appleNotes
        case "markdown_folder", "markdown", "folder", "files": return .markdownFolder
        default: return nil
        }
    }

    static func noteDestinationToken(_ value: NoteDestination) -> String {
        value == .appleNotes ? "apple_notes" : "markdown_folder"
    }

    static func parseProvider(_ raw: String) -> Provider? {
        switch settingToken(raw) {
        case "openrouter", "open_router": return .openrouter
        case "vercel": return .vercel
        case "openai", "open_ai": return .openai
        case "codex": return .codex
        case "claudecode", "claude_code": return .claudeCode
        case "grokcode", "grok_code": return .grokCode
        case "pi", "picode", "pi_code": return .piCode
        case "anthropic", "claude": return .anthropic
        case "gemini", "google": return .gemini
        case "deepseek", "deep_seek": return .deepseek
        case "qwen": return .qwen
        case "glm", "zhipu": return .glm
        case "kimi", "moonshot": return .kimi
        case "minimax", "mini_max": return .minimax
        case "mimo", "xiaomi": return .mimo
        case "custom", "custom_provider": return .custom
        default: return nil
        }
    }

    static func providerToken(_ provider: Provider) -> String {
        switch provider {
        case .claudeCode: return "claude_code"
        case .grokCode:   return "grok_code"
        case .piCode:     return "pi_code"
        case .commandCode: return "command_code"
        default:          return provider.rawValue
        }
    }

    /// Optional search backends need a nested optional: nil means a recognized
    /// `native` request, while an outer nil means the text was invalid.
    static func parseSearchBackend(_ raw: String) -> APIKeyStore.SearchBackend?? {
        switch settingToken(raw) {
        case "native", "default", "provider", "auto": return .some(nil)
        case "exa": return .some(.exa)
        case "keenable": return .some(.keenable)
        case "anysearch", "any_search": return .some(.anysearch)
        default: return nil
        }
    }

    static func parseConcreteSearchBackend(_ raw: String) -> APIKeyStore.SearchBackend? {
        switch settingToken(raw) {
        case "exa": return .exa
        case "keenable": return .keenable
        case "anysearch", "any_search": return .anysearch
        default: return nil
        }
    }

    static func isClearToken(_ raw: String) -> Bool {
        let token = settingToken(raw)
        return token.isEmpty || ["clear", "remove", "delete", "none"].contains(token)
    }

    static func parseShortcut(_ raw: String) -> SummonHotKey? {
        let token = settingToken(raw)
        if ["disabled", "disable", "off", "none"].contains(token) {
            var shortcut = SummonHotKey.current
            shortcut.enabled = false
            return shortcut
        }
        if ["default", "double_option", "double_alt", "option_option"].contains(token) {
            return .defaultConfig
        }
        let doubles: [String: UInt32] = [
            "double_command": UInt32(cmdKey), "double_cmd": UInt32(cmdKey),
            "double_control": UInt32(controlKey), "double_ctrl": UInt32(controlKey),
            "double_shift": UInt32(shiftKey),
        ]
        if let modifier = doubles[token] {
            return SummonHotKey(keyCode: 0, modifiers: 0,
                                doubleTapModifier: modifier, enabled: true)
        }

        guard let chord = parseChord(raw) else { return nil }
        guard AppShortcutStore.conflictOwner(for: chord, editingSummon: true) == nil else {
            return nil
        }
        return SummonHotKey(keyCode: chord.keyCode, modifiers: chord.modifiers,
                            doubleTapModifier: 0, enabled: true)
    }

    /// Written chord → the Carbon pair the recorder would have produced. Accepts
    /// glyphs (`⌘⇧K`), words (`command+shift+k`), spaces or dashes as separators.
    /// `nil` when it names no real key or carries no real modifier — the same
    /// floor the Shortcuts pane enforces, so both entry paths accept exactly the
    /// same set of chords.
    static func parseChord(_ raw: String) -> ShortcutChord? {
        var chord = raw.lowercased()
        let replacements = [
            "⌘": "command+", "⌥": "option+", "⌃": "control+", "⇧": "shift+",
            "cmd": "command", "alt": "option", "ctrl": "control",
        ]
        for (from, to) in replacements { chord = chord.replacingOccurrences(of: from, with: to) }
        chord = chord.replacingOccurrences(of: "-", with: "+")
        chord = chord.replacingOccurrences(of: " ", with: "+")
        let parts = chord.split(separator: "+").map(String.init).filter { !$0.isEmpty }
        guard let keyName = parts.last, let keyCode = shortcutKeyCode(keyName) else { return nil }
        var modifiers: UInt32 = 0
        for part in parts.dropLast() {
            switch part {
            case "command": modifiers |= UInt32(cmdKey)
            case "option":  modifiers |= UInt32(optionKey)
            case "control": modifiers |= UInt32(controlKey)
            case "shift":   modifiers |= UInt32(shiftKey)
            default: return nil
            }
        }
        let real = UInt32(cmdKey) | UInt32(optionKey) | UInt32(controlKey)
        guard modifiers & real != 0 else { return nil }
        return ShortcutChord(keyCode: keyCode, modifiers: modifiers)
    }

    /// The prompt a chord is already bound to, if any — prompt shortcuts live in
    /// their own list, so `AppShortcutStore.conflictOwner` cannot see them.
    static func promptShortcutOwner(for chord: ShortcutChord,
                                            excluding id: UUID? = nil) -> String? {
        PromptShortcutStore.current
            .first { $0.id != id && $0.shortcut == chord }
            .map { $0.prompt.isEmpty ? L("shortcuts.promptAction") : $0.prompt }
            .map { $0.count > 40 ? String($0.prefix(39)) + "…" : $0 }
    }

    /// Find the binding a `scope` selector points at: its id, its current chord,
    /// or a distinctive part of its prompt. Ambiguity throws rather than guessing
    /// which of the user's bindings to overwrite.
    static func resolvePromptShortcut(_ selector: String,
                                              in list: [PromptShortcut]) throws -> PromptShortcut {
        let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: trimmed), let hit = list.first(where: { $0.id == id }) {
            return hit
        }
        if let chord = parseChord(trimmed), let hit = list.first(where: { $0.shortcut == chord }) {
            return hit
        }
        let needle = trimmed.lowercased()
        let matches = list.filter { $0.prompt.lowercased().contains(needle) }
        if let only = matches.first, matches.count == 1 { return only }
        if matches.count > 1 {
            throw AppSettingValidationError.message(
                "scope \"\(trimmed)\" matches \(matches.count) prompt shortcuts; use the chord of the one you mean.")
        }
        throw AppSettingValidationError.message(
            "No prompt shortcut matches scope \"\(trimmed)\". Call action=shortcuts to see the existing ones.")
    }

    private static func shortcutKeyCode(_ raw: String) -> UInt32? {
        let named: [String: Int] = [
            "space": kVK_Space, "return": kVK_Return, "enter": kVK_Return,
            "tab": kVK_Tab, "escape": kVK_Escape, "esc": kVK_Escape,
            "delete": kVK_Delete, "backspace": kVK_Delete,
            "left": kVK_LeftArrow, "right": kVK_RightArrow,
            "up": kVK_UpArrow, "down": kVK_DownArrow,
            "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4,
            "f5": kVK_F5, "f6": kVK_F6, "f7": kVK_F7, "f8": kVK_F8,
            "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
        ]
        if let code = named[raw] { return UInt32(code) }
        let ansi: [String: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
            "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
            "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
            "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
            "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
            "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
            "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash,
            ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, "[": kVK_ANSI_LeftBracket,
            "]": kVK_ANSI_RightBracket, "\\": kVK_ANSI_Backslash,
            "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "`": kVK_ANSI_Grave,
        ]
        return ansi[raw].map(UInt32.init)
    }
}
