import SwiftUI
import Combine
import AppKit   // NSWorkspace — opening Notes/Reminders for a Recent capture
import Carbon.HIToolbox
import UniformTypeIdentifiers   // UTType — is a pasted file URL an image? (agent ⌘V)

@MainActor
extension NotchModel {
    // MARK: - The selection the user came in with

    /// Whether an ambient selection belongs on what the panel is currently
    /// showing: the plain idle prompt, and nothing else. A thread on screen, an
    /// agent task being written, settings, What's New, or a shortcut that already
    /// captured its own selection each own the surface — dropping a second
    /// context badge onto any of them would be noise at best.
    var acceptsSelectionContext: Bool {
        selectionContextEnabled
            && mode == .idle && turns.isEmpty && !showWhatsNew
            && !agentComposeActive
            && promptShortcutContext == nil
    }

    /// Carry the selection read at the open edge into the idle prompt. Silent
    /// no-op for everything that isn't worth carrying — an empty read, a surface
    /// that doesn't accept one, or the exact text the user already said no to.
    func attachSelectionContext(_ selected: String, from app: String?) {
        let body = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, acceptsSelectionContext, body != dismissedSelection else { return }
        selectionContext = selected
        selectionContextSource = app
    }

    /// The × on the badge: this answer is not about that. Remembered, so the next
    /// summon over the same untouched selection doesn't re-attach it.
    func dropSelectionContext() {
        dismissedSelection = selectionContext?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        selectionContext = nil
        selectionContextSource = nil
        // The × is the first moment we can be sure the user has both noticed the
        // feature and wanted it gone — so it is the one moment worth spending on
        // telling them where the switch lives. Once ever, then never again: a
        // reminder that repeats is nagging about a thing they already handled.
        guard !UserDefaults.standard.bool(forKey: Self.selectionContextHintSeenKey)
        else { return }
        UserDefaults.standard.set(true, forKey: Self.selectionContextHintSeenKey)
        selectionContextHintTask?.cancel()
        selectionContextHintShown = true
        selectionContextHintTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                self?.selectionContextHintShown = false
            }
        }
    }

    /// Take the one-time hint off screen early — the user followed it into
    /// Settings, or the page moved on underneath it.
    func retireSelectionContextHint() {
        selectionContextHintTask?.cancel()
        selectionContextHintShown = false
    }

    /// Drop the carried selection because the page changed under it (a new chat,
    /// a close, a line that went somewhere else). Unlike `dropSelectionContext`
    /// this is not a refusal, so it arms no memory — the next open reads the
    /// selection fresh.
    func clearSelectionContext() {
        selectionContext = nil
        selectionContextSource = nil
        retireSelectionContextHint()
    }

    /// A prompt shortcut whose presentation is a compact pointer-side window.
    /// The round starts headlessly, preserving whatever the notch is currently
    /// showing, then its live mirror is handed directly to the window.
    func runPromptShortcutInWindow(shortcutID: UUID, prompt: String, selectedText: String,
                                   pin: ModelPin? = nil,
                                   title: String, near pointer: NSPoint,
                                   sourceApplication: NSRunningApplication?) {
        guard let threadID = startPromptShortcutRound(
            prompt: prompt, selectedText: selectedText, pin: pin)
        else { return }
        DetachedSessionWindowController.presentCompactShortcut(
            shortcutID: shortcutID, threadID: threadID,
            title: title, model: self, near: pointer,
            sourceApplication: sourceApplication)
    }

    /// Start the headless round shared by saved prompt shortcuts and the compact
    /// one-off composer. Keeping construction here guarantees both paths wrap the
    /// captured selection identically and both remain invisible to panel state.
    @discardableResult
    func startPromptShortcutRound(prompt: String, selectedText: String,
                                  pin: ModelPin? = nil,
                                  origin: HistoryItem.Origin? = nil) -> UUID? {
        guard LicenseService.shared.state.allowsProductServices else { return nil }
        let instruction = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return nil }

        // The one-off composer can DROP its captured selection (the × on the
        // "Using copied text" badge) — the line then stands on its own and asks
        // exactly what was typed.
        let question = context.isEmpty ? instruction : """
        \(instruction)

        <selected_text>
        \(selectedText)
        </selected_text>
        """
        return runDetachedRound(
            threadID: UUID(), seed: [], question: question,
            hideUserBubble: true, trackCompactTask: true, pin: pin,
            origin: origin)
    }

    /// Supersede a compact shortcut's previous headless round. This is a replace,
    /// not a visible stop: discard its unfinished Recent placeholder while the
    /// existing window immediately adopts the newer translation.
    func cancelCompactRound(threadID: UUID) {
        compactRoundTasks.removeValue(forKey: threadID)?.cancel()
        settlePending(threadID)
    }

    /// Leaving or replacing a Force Touch result is a presentation detach, like
    /// folding the main panel: relinquish the handle that can supersede the round
    /// without cancelling the unstructured task itself. Its in-flight snapshot
    /// keeps streaming and persists the finished thread into Recent.
    func detachCompactRound(threadID: UUID) {
        compactRoundTasks.removeValue(forKey: threadID)
    }

    /// The single Enter entry point the input field calls. There's only one surface
    /// — the chat input — so this never changes what the panel looks like; it just
    /// routes the line by **intent**:
    ///   · note naming a future time → file it in Apple Reminders (alarm at that time)
    ///   · note                      → write it to Apple Notes (feedback shows inline)
    ///   · ask, or ambiguous         → send it to the AI
    /// Ambiguity falls to ask (`effectiveSubmitPanel` resolves `nil` → `.chat`), so an
    /// unsure line on a fresh prompt asks the AI — the agreed "ambiguous → ask" rule.
    /// This matches `submitLabel` exactly, so the inline "Ask"/"Note"/"Remind" hint
    /// always names where the line actually went.
    func submitCurrent() {
        guard LicenseService.shared.state.allowsProductServices else { return }
        // A thread on screen routes by the THREAD, not the armed bucket:
        // `submit()` continues the conversation (its agent session when
        // resumable, else the chat model), so a persisted Agent bucket can
        // never hijack an ask thread's follow-up into a fresh agent task.
        if !turns.isEmpty { submit(); return }
        // An empty prompt shortcut has already supplied the object of the ask.
        // Whatever is typed now is the one-off instruction, regardless of intent
        // classification or which bucket was previously armed.
        if let selectedText = promptShortcutContext {
            let instruction = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !instruction.isEmpty else { return }
            promptShortcutContext = nil
            text = """
            \(instruction)

            <selected_text>
            \(selectedText)
            </selected_text>
            """
            fromPromptShortcut = true
            submit(hideUserBubble: true)
            return
        }
        // An active agent compose sends the line to the agent CLI, not the
        // chat model — regardless of what the classifier reads.
        if agentComposeActive { submitAgent(); return }
        // A `/`-pinned prompt shortcut acts as the line's mode: wrap the input
        // in that shortcut's instruction and ask — the same intent the chord
        // path fires with captured selection, just against what was typed.
        if let shortcut = promptShortcutMode {
            let instruction = shortcut.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !instruction.isEmpty else { return }
            text = """
            \(instruction)

            <selected_text>
            \(text)
            </selected_text>
            """
            promptShortcutMode = nil
            // Same shortcut, same pin: a `/`-driven run is the chord's twin, so it
            // runs on the backend that shortcut names.
            armModelPin(shortcut.pin)
            submit()
            return
        }
        // The selection carried in from the app the user came from rides along
        // with an ASK — "translate this" is about the thing they had highlighted,
        // which is the entire reason it was picked up. Note and Remind route on
        // their own words alone ("call mom tomorrow", typed over some paragraph
        // still selected in another window, is a reminder and nothing else), so
        // there the context is dropped rather than folded in. Either way it is
        // consumed here: it belonged to this line.
        if let selection = selectionContext {
            clearSelectionContext()
            let instruction = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if effectiveSubmitPanel == .chat, !instruction.isEmpty {
                text = """
                \(instruction)

                <selected_text>
                \(selection)
                </selected_text>
                """
                // Same shape as the prompt-shortcut path above: the wrapped
                // payload is wire context, not something to render back at the
                // user as their own bubble.
                submit(hideUserBubble: true)
                return
            }
        }
        switch effectiveSubmitPanel {
        case .chat:     submit()
        case .note:
            askComposeImages = []
            submitNote()
        case .reminder:
            askComposeImages = []
            submitReminder()
        }
    }
}
