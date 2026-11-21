import SwiftUI
import Combine
import AppKit   // NSWorkspace — opening Notes/Reminders for a Recent capture
import Carbon.HIToolbox
import UniformTypeIdentifiers   // UTType — is a pasted file URL an image? (agent ⌘V)

@MainActor
extension NotchModel {
    // MARK: - Ask-the-user questions (the `ask_user` tool)

    /// One clarifying question the model posed mid-answer via the `ask_user` tool,
    /// waiting on the user to pick an option. Rendered as an option card under the
    /// streaming assistant turn it belongs to. Runtime-only — never persisted, so
    /// a saved conversation can't reopen onto a dead question.
    struct PendingUserQuestion: Identifiable, Equatable {
        let id: UUID
        /// The assistant turn (answer) this question interrupts — the card shows
        /// under that turn while it streams.
        let answerID: UUID
        let question: String
        let options: [String]
        /// Confirmation actions are compact peers and sit side by side. Ordinary
        /// clarifying answers can be longer, so they keep the stacked layout.
        let inlineOptions: Bool
    }

    /// How long an unanswered question waits before the round moves on without one.
    /// Long enough to answer at leisure (or hover a folded panel back open — the
    /// card survives reattach), short enough that a walked-away round still
    /// finishes, lands in Recent, and fires its notification.
    private static let userChoiceTimeout: TimeInterval = 120

    /// The question card to show under a streaming assistant turn, if any.
    func pendingQuestion(for answerID: UUID) -> PendingUserQuestion? {
        pendingUserQuestions.first { $0.answerID == answerID }
    }

    /// The user tapped an option on the card: feed it back as the tool result and
    /// let the suspended round continue.
    func chooseUserOption(_ option: String, questionID: UUID) {
        resolveUserQuestion(questionID, with: .success("The user chose: \"\(option)\""))
    }

    /// Suspend an `ask_user` tool call until the user picks an option. Publishes
    /// the question for the UI, parks the continuation, and arms the timeout; the
    /// user's tap, the timeout, or the round's cancellation resumes it — whichever
    /// comes first. Main-actor isolated (with the resolution paths), so the park
    /// and every resume are serialized and none can be lost.
    func awaitUserChoice(answerID: UUID, question: String, options: [String],
                         inlineOptions: Bool = false) async throws -> String {
        let questionID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                // Cancelled before we even parked (superseded while the tool call
                // was dispatched): don't surface a dead card.
                if Task.isCancelled {
                    cont.resume(throwing: CancellationError())
                    return
                }
                userChoiceContinuations[questionID] = cont
                let pending = PendingUserQuestion(
                    id: questionID, answerID: answerID,
                    question: question, options: options,
                    inlineOptions: inlineOptions)
                pendingUserQuestions.append(pending)
                updateRuntimeTurn(answerID) { $0.pendingQuestion = pending }
                // Timeout backstop: an unanswered question (user walked away, panel
                // stayed closed) must not hang the round forever — resolve with an
                // explicit "no answer" the model is told to proceed on. Unstructured
                // on purpose: it must fire even after the round detaches, and it's a
                // no-op when the question resolved some other way first.
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(Self.userChoiceTimeout * 1_000_000_000))
                    self?.resolveUserQuestion(questionID, with: .success(
                        "The user did not answer. Proceed with your best judgment and state the assumption you made."))
                }
            }
        } onCancel: {
            // Round superseded/cancelled while waiting — release the harness so its
            // own cancellation handling runs. Hop to the main actor; idempotent, so
            // racing a simultaneous tap or timeout is safe.
            Task { @MainActor [weak self] in
                self?.resolveUserQuestion(questionID, with: .failure(CancellationError()))
            }
        }
    }

    /// Resume a parked question exactly once and drop its card. Safe to call from
    /// every path (tap, timeout, cancel) — a second call for the same id finds no
    /// continuation and does nothing.
    func resolveUserQuestion(_ questionID: UUID, with result: Result<String, Error>) {
        guard let cont = userChoiceContinuations.removeValue(forKey: questionID) else { return }
        let answerID = pendingUserQuestions.first(where: { $0.id == questionID })?.answerID
        pendingUserQuestions.removeAll { $0.id == questionID }
        if let answerID {
            updateRuntimeTurn(answerID) { $0.pendingQuestion = nil }
        }
        cont.resume(with: result)
    }

    /// The recurrence suffix shown live in the Remind hint *before* Enter (" \u{00B7} Daily"
    /// / " \u{00B7} Weekly \u{00B7} Mon" / " \u{00B7} Monthly"), so the user sees the recurrence
    /// was parsed while they can still correct it — anticipatory, not retrospective. Reads
    /// the same `recurrenceKind(in:)` the post-submit toast uses, off the live `text`.
    ///
    /// Gated on `effectiveSubmitPanel == .reminder` (so a Tab-override to Note/Ask drops
    /// it immediately) — and therefore only meaningful once the classifier has fired
    /// (~140ms after the keystroke). Empty for one-shot lines and non-reminders.
    ///
    /// NOTE: bare "weekly" (no named day) intentionally shows just " \u{00B7} Weekly" here —
    /// the repeat day is only resolved from the due date at file time, which the pre-Enter
    /// text alone can't know. The toast (which *has* the resolved `due`) shows the concrete
    /// day; the two diverge by design only in that one case.
    var submitHintSuffix: String {
        guard effectiveSubmitPanel == .reminder else { return "" }
        switch RemindersService.recurrenceKind(in: text) {
        case .daily:
            return L("recur.daily")
        case .weekly(let ekDay):
            if let ekDay {
                let dayIdx = ekDay.rawValue - 1   // EKWeekday 1-Sun…7-Sat \u{2192} 0-based
                return L("recur.weeklyOn", Calendar.current.shortWeekdaySymbols[dayIdx % 7])
            }
            return L("recur.weekly")
        case .monthly:
            return L("recur.monthly")
        case nil:
            return ""
        }
    }
}
