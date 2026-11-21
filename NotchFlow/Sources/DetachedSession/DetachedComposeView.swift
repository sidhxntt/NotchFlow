import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Compose window body

/// The idle prompt, torn out: a standalone composer window. It carries the
/// panel's own input (`PromptField`, the same Tab correction cycle, the same
/// destination spelled out — here on the send button) but keeps its line to
/// itself — the notch's box is cleared when the composer leaves, so the two
/// never write over each other.
///
/// Enter routes exactly as it would in the notch: Note and Remind file through
/// the identical services (their feedback lands on the model, mirrored below),
/// an armed Agent bucket spawns its run into the tray, and an Ask starts a round
/// that this very window then holds — the composer becomes the conversation in
/// place (`DetachedSessionWindowController.adoptThread`).
///
struct DetachedComposeView: View {
    @ObservedObject var state: DetachedWindowState
    @ObservedObject var model: NotchModel
    var pinned: Bool
    var onTogglePin: () -> Void
    var onClose: () -> Void
    var onSubmit: (String, NotchModel.Panel) -> Void
    /// The height this composer wants right now — the window follows it, so the
    /// slab grows with a wrapping draft exactly as the notch does.
    var onDesiredHeight: (CGFloat) -> Void = { _ in }

    @State private var focused = false
    @State private var caretWidth: CGFloat = 0
    @State private var caretY: CGFloat = 0
    @State private var inputHeight: CGFloat = PromptField.lineHeight(for: NotchBody.idleFontSize)
    /// This window's own read of its own line — see the type comment.
    @State private var due: Date?
    /// Tab's manual destination override, scoped to the line being written
    /// exactly like the panel's (`NotchModel.manualPanelOverride`).
    @State private var override: NotchModel.Panel?
    @State private var typedNoteTrigger: String?

    /// The window's height with a one-line prompt: the body's insets, the header,
    /// its gap, and the input row. A wrapped draft grows the window from here.
    static let restingHeight: CGFloat =
        DetachedThreadView.cardTopPadding + 26 + 10 + NotchBody.idleRowHeight
            + DetachedThreadView.cardBottomPadding

    /// One feedback line's own height plus its gap — added to the window when a
    /// save cue is up, so the cue never squeezes the input.
    private static let feedbackHeight: CGFloat = 8 + 16

    private var desiredHeight: CGFloat {
        Self.restingHeight
            + max(0, inputHeight - PromptField.lineHeight(for: NotchBody.idleFontSize))
            + (feedbackText == nil ? 0 : Self.feedbackHeight)
    }

    private var draft: String { state.composeDraft }

    private var trimmed: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Where Enter sends this line. Same resolution as the panel's
    /// `effectiveSubmitPanel`: Ask until the user pins something by hand, and
    /// nothing reads the text to change that. A pinned Capture names the bucket,
    /// not the leaf — the date still decides Notes vs Reminders under it, which
    /// is invisible here (both faces say Capture).
    private var destination: NotchModel.Panel {
        guard let override else { return .chat }
        return override == .note && due != nil ? .reminder : override
    }

    /// An armed Agent bucket owns the line regardless of any pin — the same
    /// precedence `submitCurrent()` uses.
    private var goesToAgent: Bool { model.agentComposeActive }

    private var hintLabel: String {
        if goesToAgent { return L("hint.agent") }
        switch destination {
        case .chat:              return L("hint.ask")
        // One word for both Capture leaves, same as the panel's pill.
        case .note, .reminder:   return L("hint.capture")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            composerRow
                .padding(.top, 10)
            if let feedback = feedbackText {
                Text(feedback)
                    .font(.sf(12))
                    .tracking(0.2)
                    .foregroundStyle(model.noteError == nil ? Tokens.text4 : Tokens.text2)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DetachedThreadView.cardHorizontalPadding)
        .padding(.top, DetachedThreadView.cardTopPadding)
        .padding(.bottom, DetachedThreadView.cardBottomPadding)
        .onAppear {
            // Same false→true edge the panel uses to hand an AppKit field
            // first-responder; the small delay lets the window become key first.
            focused = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { focused = true }
        }
        .onChange(of: desiredHeight) { _, h in onDesiredHeight(h) }
        .onChange(of: draft) { _, value in
            guard let trigger = typedNoteTrigger,
                  !value.hasPrefix(trigger) else { return }
            typedNoteTrigger = nil
            override = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : .chat
        }
        // The date read that decides which service a capture is filed through,
        // mirroring the panel's `scheduleDueDetection`. Nothing classifies this
        // window's line any more — the destination is whatever the user pinned.
        // `.task(id:)` cancels the in-flight read on every keystroke.
        .task(id: trimmed) {
            let snapshot = trimmed
            guard !snapshot.isEmpty else {
                due = nil
                return
            }
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard !Task.isCancelled else { return }
            let when = await Task.detached {
                RemindersService.futureDate(in: snapshot)
                    ?? RemindersService.recurrenceDate(in: snapshot)
            }.value
            guard !Task.isCancelled else { return }
            due = when
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            WindowTrailingCluster(pinned: pinned, togglePin: onTogglePin,
                                  close: onClose)
        }
        .frame(height: 26)
    }

    /// The panel's idle input, in a window: the same field, and a send button that
    /// names where Enter sends the line.
    private var composerRow: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .leading) {
                PromptField(
                    text: $state.composeDraft,
                    // Placeholder drawn as a SwiftUI label below so it can fade
                    // (the native one hard-swaps) — the panel's own trick.
                    placeholder: "",
                    fontSize: NotchBody.idleFontSize,
                    focusTrigger: focused,
                    maxVisibleLines: NotchBody.promptMaxLines,
                    onSubmit: send,
                    // Tab steps the destination when the classifier reads the
                    // line wrong, exactly as in the notch; always consumed so
                    // focus never wanders out of the box.
                    onTab: {
                        typedNoteTrigger = nil
                        override = Self.nextDestination(after: override ?? destination)
                        return true
                    },
                    // Match the notch's fresh prompt: the hand-typed sigil is
                    // retained and pins this detached line to Note. If the
                    // composer was armed for Agent, Note explicitly leaves it.
                    onInitialNoteTrigger: { trigger in
                        model.setAgentBucket(false)
                        typedNoteTrigger = String(trigger)
                        override = .note
                    },
                    onCaretWidth: { caretWidth = $0 },
                    onCaretY: { caretY = $0 },
                    onHeightChange: { inputHeight = $0 }
                )
                .frame(height: inputHeight)
                .padding(.trailing,
                         typedNoteTrigger == nil
                            ? 0
                            : InlineModeHint.reservedTrailingWidth(
                                text: "You are using Note mode",
                                fontSize: NotchBody.idleFontSize))
                .background {
                    if typedNoteTrigger != nil {
                        GeometryReader { geo in
                            InlineModeHint(
                                text: "You are using Note mode",
                                fontSize: NotchBody.idleFontSize,
                                caretWidth: caretWidth,
                                caretY: caretY,
                                availableWidth: geo.size.width,
                                tint: Tokens.noteInk)
                            .frame(height: geo.size.height, alignment: .center)
                        }
                        .allowsHitTesting(false)
                    }
                }
                .animation(.smooth(duration: 0.25), value: typedNoteTrigger != nil)
                if draft.isEmpty && caretWidth == 0 {
                    Text(L(model.idlePlaceholderKey))
                        .font(.sf(NotchBody.idleFontSize))
                        .foregroundStyle(Tokens.placeholder)
                        .lineLimit(1)
                        .padding(.leading, PromptField.textInset)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.16), value: caretWidth == 0)
            .animation(.easeOut(duration: 0.16), value: draft.isEmpty)

            // The window has no bucket row to carry a destination pill, so the send
            // button spells it out instead: "Note ⏎" / "Remind ⏎" — the same word
            // the panel's pill would show, on the control Enter maps to.
            if !trimmed.isEmpty {
                SendButton(compact: true, label: hintLabel, action: send)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .frame(height: max(NotchBody.idleRowHeight,
                           inputHeight + NotchBody.idleRowHeight
                               - PromptField.lineHeight(for: NotchBody.idleFontSize)))
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: trimmed.isEmpty)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: inputHeight)
    }

    /// The note/reminder save cue, mirrored from the model — the writes run
    /// through the panel's own services, so their feedback lives there.
    private var feedbackText: String? {
        if let err = model.noteError { return err }
        if let cue = model.lastSavedNote { return cue }
        if model.noteSaving { return L("input.saving") }
        return nil
    }

    private func send() {
        let line = trimmed
        guard !line.isEmpty else { return }
        let where_ = destination
        state.composeDraft = ""
        typedNoteTrigger = nil
        override = nil
        due = nil
        onSubmit(line, where_)
    }

    /// Tab's cycle — Ask ⇄ Capture, matching `toggleSubmitPanel`. Note and
    /// Remind are not separate stops: which leaf a capture lands in follows the
    /// time the line names, so there is nothing here for Tab to step through.
    private static func nextDestination(after current: NotchModel.Panel) -> NotchModel.Panel {
        switch current {
        case .chat:              return .note
        case .note, .reminder:   return .chat
        }
    }
}
