import SwiftUI
import AppKit
import Combine
import PDFKit
import ImageIO

/// A short explanation that trails the caret and docks at the prompt's trailing
/// edge. Used only while a punctuation prefix has explicitly armed Note mode.
struct InlineModeHint: View {
    var text: String
    var fontSize: CGFloat
    var caretWidth: CGFloat
    var caretY: CGFloat = 0
    var availableWidth: CGFloat
    var tint: Color

    private static let gap: CGFloat = 8

    static func reservedTrailingWidth(text: String, fontSize: CGFloat) -> CGFloat {
        width(of: "— \(text)", fontSize: fontSize) + gap
    }

    private static func width(of string: String, fontSize: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize)
        return ceil((string as NSString).size(withAttributes: [.font: font]).width)
    }

    private static func baselineDrop(fontSize: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize)
        let swiftUILine = (font.ascender - font.descender).rounded(.up)
        let nativeLine = NSLayoutManager().defaultLineHeight(for: font)
        return max(0, (swiftUILine - nativeLine) / 2)
    }

    var body: some View {
        let reserved = Self.reservedTrailingWidth(text: text, fontSize: fontSize)
        let dock = availableWidth - reserved + Self.gap
        let start = min(PromptField.textInset + caretWidth + Self.gap, dock)

        Text("— \(text)")
            .font(.sf(fontSize))
            .foregroundStyle(tint.opacity(0.42))
            .lineLimit(1)
            .fixedSize()
            .offset(x: start, y: caretY + Self.baselineDrop(fontSize: fontSize))
            .animation(.smooth(duration: 0.25), value: start)
            .animation(.smooth(duration: 0.25), value: caretY)
            .transition(.opacity)
    }
}

/// The compact substring filter that sits above the recent list once it grows past a
/// handful of rows. An `NSViewRepresentable` over `NSTextField` — NOT a SwiftUI
/// `TextField` — for the same reason `PromptField` is: a plain SwiftUI field pops the
/// floating autocomplete/suggestions panel and applies smart substitutions, which
/// would be jarring over the glass. We reuse `PromptField.disableEditorMagic` to kill
/// all of that on the field editor. Deliberately *not* auto-focused: keyboard focus
/// stays in the main prompt so ↓/↑ still drive the list; the user clicks the field to
/// start filtering.
struct HistorySearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var fontSize: CGFloat
    /// When this flips true the field grabs first-responder once, so the filter
    /// icon can deposit the caret straight into the expanded field.
    var focusTrigger: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        // MagiclessTextField matters MOST here: this field is deliberately not
        // auto-focused (see above) — a click is its normal way in, which is
        // exactly the path where editor magic used to stay armed until the
        // first committed keystroke.
        let field = MagiclessTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.isAutomaticTextCompletionEnabled = false
        field.allowsCharacterPickerTouchBarItem = false
        field.importsGraphics = false
        field.allowsEditingTextAttributes = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        applyStyle(to: field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        // Same composition guard as PromptField: never overwrite the field while an
        // IME composition is in flight, or half-typed pinyin gets wiped.
        let composing = (field.currentEditor() as? NSTextView)?.hasMarkedText() ?? false
        if !composing, field.stringValue != text { field.stringValue = text }
        applyStyle(to: field)
        // Kill editor-level magic whenever this field owns the field editor (the
        // editor is created lazily on first focus; re-applying is harmless).
        if let editor = field.currentEditor() {
            PromptField.disableEditorMagic(editor)
        }
        // Take focus exactly ONCE per rising edge of focusTrigger, mirroring
        // PromptField's latch so we don't fight the field editor on every render.
        let coord = context.coordinator
        if focusTrigger {
            if !coord.didFocus, field.window != nil, field.currentEditor() == nil {
                coord.didFocus = true
                DispatchQueue.main.async { [weak field] in
                    guard let field, field.currentEditor() == nil else { return }
                    field.window?.makeFirstResponder(field)
                    if let editor = field.currentEditor() {
                        // Collapse the auto-select-all that `becomeFirstResponder`
                        // does, so a re-focus drops a caret at the end instead of
                        // highlighting the whole field (see PromptField for why).
                        editor.selectedRange = NSRange(location: editor.string.count, length: 0)
                        PromptField.disableEditorMagic(editor)
                    }
                }
            }
        } else {
            coord.didFocus = false   // re-arm for the next expand
        }
    }

    private func applyStyle(to field: NSTextField) {
        let wantFont = NSFont.systemFont(ofSize: fontSize)
        if field.font != wantFont { field.font = wantFont }
        let wantText = NSColor(Tokens.text2)
        if field.textColor != wantText { field.textColor = wantText }
        let wantPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: NSColor(Tokens.text4),
                .font: wantFont,
            ]
        )
        if field.placeholderAttributedString != wantPlaceholder {
            field.placeholderAttributedString = wantPlaceholder
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: HistorySearchField
        /// One-shot latch: true once we've taken focus for the current rising edge
        /// of `focusTrigger`, reset when it falls.
        var didFocus = false
        init(_ parent: HistorySearchField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            parent.text = field.stringValue
            syncCompositionLevel(field)
        }

        func controlTextDidBeginEditing(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            PromptField.disableEditorMagic(field.currentEditor())
            // Registers the caret only; the level follows the composition, exactly as
            // in PromptField (see `NotchPanel.editingLevel`). The field editor's own
            // storage is watched too, because marked text edits don't reliably reach
            // `controlTextDidChange` — and the candidate window has to clear the
            // island the moment the first pinyin letter lands.
            (field.window as? NotchPanel)?.beginFieldEditing()
            if let editor = field.currentEditor() as? NSTextView,
               let storage = editor.textStorage {
                self.editor = editor
                NotificationCenter.default.addObserver(
                    self, selector: #selector(editorStorageDidProcessEditing),
                    name: NSTextStorage.didProcessEditingNotification, object: storage)
            }
        }

        func controlTextDidEndEditing(_ note: Notification) {
            if let storage = editor?.textStorage {
                NotificationCenter.default.removeObserver(
                    self, name: NSTextStorage.didProcessEditingNotification, object: storage)
            }
            editor = nil
            ((note.object as? NSTextField)?.window as? NotchPanel)?.endFieldEditing()
        }

        /// The field editor this coordinator is currently watching for marked text.
        private weak var editor: NSTextView?

        deinit { NotificationCenter.default.removeObserver(self) }

        @objc private func editorStorageDidProcessEditing() {
            guard let editor else { return }
            (editor.window as? NotchPanel)?.setComposing(editor.hasMarkedText())
        }

        private func syncCompositionLevel(_ field: NSTextField) {
            guard let editor = field.currentEditor() as? NSTextView else { return }
            (field.window as? NotchPanel)?.setComposing(editor.hasMarkedText())
        }
    }
}

/// The send button — a piece of the same **Liquid Glass** as the rest of the
/// island (native `.glassEffect` on macOS 26+, blur fallback below), brightening
/// gently on hover rather than flooding to a flat white fill.
///
/// Two shapes, one control:
///   • Given a `label` ("Ask" / "Note"), it renders a **pill that spells out the
///     destination in words** — because a glyph alone (arrow vs. pencil) doesn't
///     read as "ask vs. note" at a glance. The classifier watches the text as it's
///     typed and swaps the word in place; the glyph beside it is a plain ⏎, marking
///     the key you press. So the button tells you in plain language where Enter
///     sends the line, before you press it.
///   • With no `label` (the mid-thread follow-up), it stays a bare arrow circle:
///     a follow-up is always an ask, so there's nothing to disambiguate and the
///     small inline field has no room for a word.
///
/// The label cross-fades when it flips, so ask⇄note reads as one control changing
/// meaning rather than two different buttons.
struct SendButton: View {
    var compact: Bool = false
    /// SF Symbol for the action the current text will trigger. Defaults to the
    /// classic send arrow; callers pass a note glyph when the input reads as a jot.
    var icon: String = "arrow.up"
    /// The destination spelled out ("Ask" / "Note"). When set, the button renders
    /// as a labeled pill; when `nil`, it's the bare arrow circle (follow-up).
    var label: String? = nil
    var action: () -> Void
    @State private var hovering = false

    private var size: CGFloat { compact ? 27 : 30 }

    var body: some View {
        Button(action: action) {
            if let label {
                pill(label)
            } else {
                glyphCircle
            }
        }
        // Same press-give as the island's other glass chips.
        .buttonStyle(GlassPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
        // The flip rides a quick spring so ask⇄note feels like the control morphing,
        // in step with the rest of the panel's motion language.
        .animation(.spring(response: 0.32, dampingFraction: 0.7), value: icon)
        .animation(.spring(response: 0.32, dampingFraction: 0.7), value: label)
    }

    /// The labeled form: a glass pill reading "Ask ⏎" / "Note ⏎", the word leading
    /// so the destination is the first thing you read. Whole contents keyed on the
    /// label so a change cross-fades rather than hard-cuts.
    private func pill(_ label: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.sf(13, weight: .semibold))
            Image(systemName: icon)
                .font(.sf(12, weight: .semibold))
        }
        .foregroundStyle(hovering ? Tokens.text1 : Tokens.text2)
        .id(label)
        .transition(.scale(scale: 0.7).combined(with: .opacity))
        .padding(.horizontal, 13)
        .frame(height: size)
        .glassCapsule(in: Capsule(), brighter: hovering)
        .contentShape(Capsule())
    }

    /// The bare form: just the send arrow in a glass circle (mid-thread follow-up).
    private var glyphCircle: some View {
        Image(systemName: icon)
            .font(.sf(13, weight: .semibold))
            .foregroundStyle(hovering ? Tokens.text1 : Tokens.text2)
            .id(icon)
            .transition(.scale(scale: 0.55).combined(with: .opacity))
            .frame(width: size, height: size)
            .glassCapsule(in: Circle(), brighter: hovering)
            .contentShape(Circle())
    }
}

/// Keyboard guidance at the trailing edge of an Agent follow-up field. These
/// are intentionally plain labels, not controls: Enter already owns send and
/// Command-Enter owns interrupt, so glass buttons only repeated the same verbs
/// while crowding the line.
struct AgentFollowUpKeyHints: View {
    var showsInterrupt: Bool

    var body: some View {
        Text(showsInterrupt
             ? L("agent.followUp.send") + "  ·  " + L("agent.followUp.interrupt")
             : L("agent.followUp.send"))
        .font(.sf(NotchBody.followUpFontSize))
        .foregroundStyle(Tokens.text4.opacity(0.72))
        .lineLimit(1)
        .fixedSize()
        // `ComposerBox` bottom-aligns trailing content so it follows the last
        // line of a growing draft. Give this label the same one-line slot as
        // the editor, keeping their text vertically centred at rest.
        .frame(height: 27, alignment: .center)
        .padding(.trailing, 6)
        .accessibilityElement(children: .combine)
    }
}

/// The body of an agent run's record: every settled round in order — its
/// prompt, its own slice of the work trail, then its report — followed by the
/// round still in flight and the activity ticker underneath it.
///
/// One implementation, because the panel's detail page and its torn-off window
/// are the same page at two sizes. They had drifted: the panel walks
/// `task.exchanges` so a follow-up thread keeps ALL prior answers on screen,
/// while the detached window rendered the flat trail plus only
/// `exchanges.last?.answer` — so tearing a multi-round run out of the notch
/// silently dropped every earlier round's report (the exact bug the panel page
/// had already been fixed for). The window also skipped `isLazy`, rebuilding
/// hundreds of trail rows on a page that pins to its tail.
///
/// Callers own the scroll, the runways and the tail-follow; this owns what the
/// record is made of.
struct AgentRecordBody: View {
    let task: AgentTaskManager.AgentTask
    /// The tail spacer's id, so the host's ScrollViewReader can chase it.
    let bottomID: String

    var body: some View {
        // The flat trail (`task.log`) spans every round; the settled rounds each
        // own their own slice via `exchange.log`. Whatever's left over belongs to
        // the round in flight — its "› " prompt marker plus the tool rows it has
        // produced so far. Split by entry id, never by index, so a capped/trimmed
        // trail still partitions cleanly.
        let claimedIDs = Set(task.exchanges.flatMap { $0.log.map(\.id) })
        let liveTail = task.log.filter { !claimedIDs.contains($0.id) }
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(task.exchanges.enumerated()), id: \.offset) { _, exchange in
                UserQuestionBubble(text: exchange.prompt)
                // The trail's last narration entry IS this round's report (the
                // parser records it in both places) — drop it so it isn't
                // printed again by the answer just below. See
                // `droppingTrailingAnswer`.
                let trail = exchange.log.droppingTrailingAnswer(exchange.answer)
                if !trail.isEmpty {
                    // Lazy: a long run's trail is hundreds of rows and this page
                    // pins to the tail — see `isLazy`'s doc.
                    AgentWorkTrailView(entries: trail, isLazy: true)
                }
                if !exchange.answer.isEmpty {
                    MarkdownBlocks(source: exchange.answer, baseFont: 15)
                }
            }
            // The round still in flight has no settled exchange yet. Round one
            // carries no "› " marker, so its prompt is the task headline; a
            // follow-up round's prompt already rides the live tail as its
            // leading "› " marker.
            if task.isRunning {
                if task.exchanges.isEmpty {
                    UserQuestionBubble(text: task.prompt)
                }
                if !liveTail.isEmpty {
                    // `live`: the trailing block is still being written, so it
                    // must not fold under the reader.
                    AgentWorkTrailView(entries: liveTail, isLazy: true, live: true)
                }
                // The collapsed row's ticker, following the trail — what the run
                // is doing right now. Same 14pt/text3 face the status row wears.
                // Drop it when the trail already shows the same live activity:
                // tool parsers add the 12pt mono row as soon as a command starts,
                // so repeating it here in the ticker's larger prose face made two
                // adjacent commands look as though they used different styles.
                // Streaming prose is the same duplication in another form.
                let activity = task.activity ?? L("agent.thinking")
                let trailAlreadyShowsActivity = liveTail.last.map { entry in
                    entry.mono && entry.title.hasPrefix(activity)
                } ?? false
                if !NotchBody.trailTailIsStreamingProse(task.log),
                   !trailAlreadyShowsActivity {
                    CrossfadeText(text: activity,
                                  font: 14, color: Tokens.text3)
                        .tracking(-0.1)
                        .lineLimit(1)
                        .padding(.vertical, 2)
                }
            }
            Color.clear.frame(height: 1).id(bottomID)
        }
    }
}
