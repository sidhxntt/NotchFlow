import SwiftUI
import AppKit
import Combine
import PDFKit
import ImageIO

/// A single-line field that strips the field editor's completion / prediction
/// magic the moment focus arrives by ANY route. The focusTrigger path in
/// `updateNSView` disables it after its programmatic `makeFirstResponder`, but a
/// direct CLICK into the field creates the editor without that block ever running
/// (its `currentEditor() == nil` guard skips), and `controlTextDidBeginEditing`
/// waits for the first *committed* change — an entire IME composition can play out
/// before that. A click-focused session could therefore reach its first keystrokes
/// with the system completion panel still armed: the intermittent big empty glass
/// box flashing over the panel. Hooking `becomeFirstResponder` covers click, Tab
/// and programmatic focus alike, synchronously, before any keystroke can reach the
/// editor. (Used by the compact filter fields; the prompt itself is a
/// `PromptTextView` — see `PromptField`.)
final class MagiclessTextField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { PromptField.disableEditorMagic(currentEditor()) }
        return accepted
    }
}

/// The prompt's backing text view. Two jobs beyond a plain `NSTextView`:
///  · strip the completion / prediction magic on every route into focus (same
///    reasoning as `MagiclessTextField` above — a click must never reach a
///    keystroke with the system completion panel still armed);
///  · draw the placeholder itself, since `NSTextView` has none. (Both prompt call
///    sites hand the placeholder to a SwiftUI label instead, so it can fade; this
///    keeps the contract intact for any caller that doesn't.)
final class PromptTextView: NSTextView {
    var placeholder: String = ""
    /// Consulted on ⌘V before the text machinery runs. Returning `true` means the
    /// paste was consumed as something other than text (the agent compose
    /// attaches a pasted IMAGE); `false` falls through to the normal text paste.
    var onPasteImage: () -> Bool = { false }
    /// A hand-typed colon / double-quote at the very start of a fresh prompt
    /// switches its mode while remaining ordinary note content. Kept on the
    /// AppKit input path so paste, recall, restored drafts and other programmatic
    /// fills can never switch modes by accident.
    var onInitialNoteTrigger: (Character) -> Void = { _ in }
    /// Consulted on ⌘⏎. Command-modified keys never reach `doCommandBy:` (AppKit
    /// routes them as key equivalents first), so the chord is caught here rather
    /// than beside ⏎ and ⇧⏎ in the delegate.
    var onCommandSubmit: () -> Bool = { false }

    /// True only while `paste(_:)` is asking AppKit to insert clipboard text.
    /// A paste arrives under the same key-down event as a hand-typed character,
    /// so the event type alone cannot distinguish it from direct input.
    private var insertingPaste = false

    /// Colon and double-quotation forms used by common Latin, CJK and European
    /// input sources. The small / vertical punctuation forms matter for IMEs
    /// that emit compatibility characters instead of ASCII/full-width glyphs.
    private static let initialNoteTriggers: Set<Character> = [
        ":", "：", "﹕", "︓",
        "\"", "＂", "“", "”", "„", "‟", "«", "»",
        "〝", "〞", "〟", "「", "」", "『", "』",
    ]

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .command, event.keyCode == 36 /* Return */, onCommandSubmit() {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let inserted = (insertString as? NSAttributedString)?.string
            ?? (insertString as? String)
        let selection = selectedRange()
        if !insertingPaste,
           NSApp.currentEvent?.type == .keyDown,
           selection.location == 0, selection.length == 0,
           let inserted, inserted.count == 1,
           let character = inserted.first,
           Self.initialNoteTriggers.contains(character) {
            onInitialNoteTrigger(character)
        }
        super.insertText(insertString, replacementRange: replacementRange)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { PromptField.disableEditorMagic(self) }
        return accepted
    }

    /// A plain-text view's `readablePasteboardTypes` carries no image types, so
    /// with a pixels-only clipboard (a bare ⌃⇧⌘4 screenshot — THE case the agent
    /// compose's image attach exists for) AppKit validates Edit ▸ Paste to
    /// disabled and ⌘V dies before `paste(_:)` is ever called. Claim image
    /// types too, purely so the paste command fires; `paste(_:)` below decides
    /// what actually happens to them. `.fileURL` rides along for the other half
    /// of `pasteboardImage()`: an image copied in Finder arrives as a file URL,
    /// which a plain-text view reads no better than raw pixels.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes + [.png, .tiff, .fileURL]
    }

    override func paste(_ sender: Any?) {
        if onPasteImage() { return }
        // The image types above were claimed only to keep ⌘V alive for the
        // hook. When the hook passes (not composing an agent task) and the
        // clipboard holds nothing the plain-text machinery can read, stop —
        // don't let AppKit improvise an attachment glyph out of raw pixels.
        guard NSPasteboard.general.availableType(from: super.readablePasteboardTypes) != nil else { return }
        insertingPaste = true
        defer { insertingPaste = false }
        super.paste(sender)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText(), !placeholder.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor(Tokens.placeholder),
        ]
        (placeholder as NSString).draw(
            at: NSPoint(x: textContainerInset.width, y: textContainerInset.height),
            withAttributes: attrs)
    }
}

/// A borderless prompt box styled to the design tokens.
///
/// Backed by an AppKit `NSTextView` (in a scroll view) rather than SwiftUI's
/// `TextField`/`TextEditor` for two reasons:
///
///  1. **No completion panel.** AppKit's text machinery pops a floating
///     autocomplete/prediction panel while typing (the empty glass box) and
///     SwiftUI gives no hook to turn it off — `disableEditorMagic` does.
///  2. **It grows down, not sideways.** A long prompt WRAPS and the box gains a
///     line at a time, up to `maxVisibleLines`, after which it scrolls internally.
///     The old single-line field scrolled horizontally, hiding everything but the
///     tail of what you'd typed.
///
/// The caller sizes the row from `onHeightChange` (the box's current height,
/// already clamped to the line cap).
struct PromptField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var fontSize: CGFloat
    /// When this flips true the field grabs first-responder (caret in the box) —
    /// our replacement for SwiftUI `@FocusState`, which can't drive an AppKit view.
    var focusTrigger: Bool = false
    /// How tall the box may grow, in lines of text, before it stops growing and
    /// starts scrolling its content instead.
    var maxVisibleLines: Int = 5
    var onSubmit: () -> Void
    /// Invoked when ← is pressed while the field is empty — lets a result view bind
    /// it to "back / new conversation". No-op by default (e.g. the idle prompt),
    /// so left-arrow there just moves the caret as usual.
    var onBack: () -> Void = {}
    /// Invoked when ↓ is pressed while the field is empty — the idle prompt binds
    /// it to "open / step down the recent list". Returns `true` if it consumed the
    /// key (so the field swallows it); `false` lets ↓ move the caret as usual.
    var onDown: () -> Bool = { false }
    /// Invoked when ↑ is pressed while the field is empty — steps the recent-list
    /// highlight back up (and folds it away past the top). Same return contract as
    /// `onDown`.
    var onUp: () -> Bool = { false }
    /// Whether a keyboard-driven menu is open over the field — the `/` command
    /// menu today. While it is, ↑/↓ go to `onUp`/`onDown` (they walk its rows)
    /// even though the box holds text, which the empty-field rule below would
    /// otherwise send to the caret. Default `false`: no menu, no change.
    var isMenuOpen: () -> Bool = { false }
    /// Whether an ↑/↓ history-recall session is live. When `true`, ↑/↓ keep going
    /// to `onUp`/`onDown` even though the box now holds a recalled question (so the
    /// user can press ↑ again to step further back), instead of moving the caret.
    /// Default `false`: ↑/↓ only fire the callbacks on an empty field.
    var isRecalling: () -> Bool = { false }
    /// Invoked on Enter *before* `onSubmit` — lets the idle prompt open a
    /// keyboard-highlighted recent row instead of submitting. Returns `true` when
    /// it handled the key (a row was open); `false` falls through to `onSubmit`.
    var onSubmitNav: () -> Bool = { false }
    /// Invoked on Tab (⇥) — the idle prompt binds it to step the destination
    /// cycle (Ask → Note → Remind), overriding the classifier for the current
    /// line. Returns `true` when consumed; `false` lets Tab do its default focus
    /// move.
    var onTab: () -> Bool = { false }
    /// Invoked on Shift-Tab (⇧⇥). `nil` (the default) means "same as Tab", so a
    /// caller that doesn't distinguish the two keys keeps the old shared
    /// behaviour on both; the idle prompt binds this separately to flip the
    /// Ask ⇄ Agent bucket. Returns `true` when consumed.
    var onBackTab: (() -> Bool)? = nil
    /// Invoked on ⌘V *before* the text paste — the idle prompt binds it to "attach
    /// a pasted image to the agent compose". Returns `true` when it consumed
    /// the paste (the clipboard held pixels and the compose took them); `false`
    /// lets the paste insert text as usual.
    var onPasteImage: () -> Bool = { false }
    /// Invoked when the user directly types a colon or double-quote at insertion
    /// position zero. The sigil is still inserted normally; paste and model-side
    /// text changes never call this hook.
    var onInitialNoteTrigger: (Character) -> Void = { _ in }
    /// Invoked on ⌘⏎ — the agent detail's "interrupt the round and send this
    /// now", the second meaning Enter can't carry (plain ⏎ queues). Returns
    /// `true` when consumed; `false` lets the key do whatever it normally would.
    var onCommandSubmit: () -> Bool = { false }
    /// Reports the width (pt) of the LAST line the box is currently *showing* —
    /// committed text PLUS any in-progress IME composition (the pinyin/marked text
    /// that isn't yet in `text`). The overlay placeholder watches it so it clears
    /// while pinyin is still composing, instead of trailing the stale committed
    /// text. `0` when the box is empty. No-op by default.
    var onCaretWidth: (CGFloat) -> Void = { _ in }
    /// Reports where that last line sits vertically, as an offset (pt) from the
    /// box's own centre — for anything that needs to ride down with the text as the
    /// box grows into a second, third… line. `0` for a single-line prompt. No-op by
    /// default (nothing reads it today).
    var onCaretY: (CGFloat) -> Void = { _ in }
    /// Reports the box's current height (pt): one line at rest, growing a line at a
    /// time with the wrapped text, clamped at `maxVisibleLines`. The caller frames
    /// the field with it and sizes the row around it. No-op by default.
    var onHeightChange: (CGFloat) -> Void = { _ in }

    /// The text's left inset inside the box — matched to the ~2pt an `NSTextField`
    /// cell used to draw with, so the placeholder labels and the inline hint (which
    /// both carry the same 2pt) still land exactly on the glyphs.
    static let textInset: CGFloat = 2

    /// One line of `fontSize` text, in the same metrics the layout manager lays the
    /// box out with — the unit the row heights and the line cap are counted in.
    static func lineHeight(for fontSize: CGFloat) -> CGFloat {
        NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: fontSize))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // Build the TextKit 1 stack by hand. A bare `NSTextView()` comes up on
        // TextKit 2, where every `layoutManager` touch silently falls back with a
        // console warning — and the layout manager is exactly what measures the
        // box's height and its last line's width here.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)

        let tv = PromptTextView(
            frame: NSRect(x: 0, y: 0, width: 200, height: Self.lineHeight(for: fontSize)),
            textContainer: container)
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.focusRingType = .none
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude)
        tv.textContainerInset = NSSize(width: Self.textInset, height: 0)
        // Wrap to the box's width, grow without bound downward — the scroll view
        // caps what's *visible*, not what can be typed.
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        Self.disableEditorMagic(tv)
        applyStyle(to: tv)
        // Route ⌘V through the coordinator so the closure the view calls is
        // always the CURRENT one (coordinator.parent is refreshed every update),
        // never the copy captured at makeNSView time.
        let coord = context.coordinator
        tv.onPasteImage = { coord.parent.onPasteImage() }
        tv.onInitialNoteTrigger = { coord.parent.onInitialNoteTrigger($0) }
        tv.onCommandSubmit = { coord.parent.onCommandSubmit() }

        let scroll = NSScrollView(frame: tv.frame)
        scroll.documentView = tv
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.borderType = .noBorder
        // OFF until the text actually exceeds the line cap (see `report`). Leaving
        // this on unconditionally let macOS flash the overlay knob whenever a
        // relayout (panel open, list expand) transiently made content > viewport —
        // the ghost "rectangular cursor" at the field's trailing edge.
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        // Overlay scrollers only surface while scrolling, so a capped-out prompt
        // shows the bar it needs and the resting one-liner shows nothing.
        scroll.scrollerStyle = .overlay
        scroll.verticalScrollElasticity = .none
        scroll.contentView.drawsBackground = false
        // The inline hint rides the last line, so it has to follow the box as its
        // content scrolls under the cap.
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observe(scroll: scroll, textView: tv)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? PromptTextView else { return }
        // Refresh the coordinator's view of us so its callbacks (onCaretWidth, the
        // nav hooks) run against the current closures, not the ones captured at init.
        context.coordinator.parent = self
        // NEVER touch the text while an IME composition (marked text) is in flight.
        // During composition the bound `text` lags the display (pinyin isn't
        // committed yet), so the `string != text` check below would "correct" the box
        // back to the stale committed text — wiping the user's half-typed pinyin. And
        // re-renders DO happen mid-composition: the caret/height reports driving the
        // hint and the row size are SwiftUI state changes.
        let composing = tv.hasMarkedText()
        if !composing, tv.string != text {
            // A recall / submit / other model-side replacement starts a genuinely
            // new layout. Do not carry the IME wrap floor from the previous draft
            // into it (programmatic storage edits do not call `textDidChange`).
            context.coordinator.resetHeightStabilization()
            // Set the storage rather than `.string` so the glyphs carry our font and
            // ink outright — a plain string assignment leans on typing attributes and
            // can land unstyled.
            tv.textStorage?.setAttributedString(
                NSAttributedString(string: text, attributes: Self.attributes(fontSize: fontSize)))
            tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        applyStyle(to: tv)
        if tv.placeholder != placeholder { tv.placeholder = placeholder; tv.needsDisplay = true }
        // Re-measure on every pass: a programmatic set (submit clears the box, ↑
        // recall fills it) posts no edit notification to measure from, and a width
        // change re-wraps the text without touching it at all. Deferred a tick — the
        // reports write SwiftUI state, and we're inside SwiftUI's update.
        context.coordinator.reportAfterUpdate(for: tv)

        // Take focus exactly ONCE per rising edge of focusTrigger. SwiftUI calls
        // updateNSView on every render while the panel is open; without this latch
        // we'd enqueue a `makeFirstResponder` on each pass, piling up async blocks
        // that ping-pong the caret (and, with two PromptFields on screen, fight
        // each other) — a prime suspect for the recurring freeze.
        let coord = context.coordinator
        if focusTrigger {
            if !coord.didFocus, let window = tv.window, window.firstResponder !== tv {
                coord.didFocus = true
                DispatchQueue.main.async { [weak tv] in
                    guard let tv, let window = tv.window, window.firstResponder !== tv else { return }
                    window.makeFirstResponder(tv)
                    // Park the caret at the end rather than leaving a selection: a
                    // re-focus that lands on existing text (the mode/history/clip
                    // `onChange`s all fire `refocusInput`) must never come back with
                    // the whole line highlighted — the next keystroke would replace it.
                    tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
                    Self.disableEditorMagic(tv)
                }
            }
        } else {
            coord.didFocus = false   // re-arm for the next open
        }
    }

    /// The real source of the floating suggestion box: the **field editor** (the
    /// shared `NSTextView` that backs editing). Its own auto-completion / text-
    /// prediction / substitution switches are separate from the NSTextField's and
    /// stay ON unless turned off here. We can only reach it once editing starts
    /// (the editor is created lazily), so this runs right after we take focus and
    /// again whenever editing begins.
    static func disableEditorMagic(_ editor: NSText?) {
        guard let tv = editor as? NSTextView else { return }
        tv.isAutomaticTextCompletionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.smartInsertDeleteEnabled = false
        // Inline predictions (macOS 14+) ride their own NSTextInputTraits switch
        // — none of the flags above turn them off.
        tv.inlinePredictionType = .no
        // Writing Tools (macOS 15.2+) brings its own floating affordance/panel;
        // keep it out of the prompt box entirely.
        if #available(macOS 15.2, *) {
            tv.writingToolsBehavior = .none
        }
    }

    /// The glyph attributes the box types (and pastes) in.
    private static func attributes(fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: NSColor(Tokens.ink).withAlphaComponent(0.96),
        ]
    }

    /// Only writes a property when its value actually changed. AppKit setters here
    /// rebuild layout/redraw on every assignment; doing that unconditionally on each
    /// keystroke was wasteful churn. Cheap equality guards keep typing smooth.
    private func applyStyle(to tv: NSTextView) {
        let wantFont = NSFont.systemFont(ofSize: fontSize)
        if tv.font != wantFont { tv.font = wantFont }

        let wantInk = NSColor(Tokens.ink).withAlphaComponent(0.96)
        if tv.textColor != wantInk { tv.textColor = wantInk }
        // An NSTextView's caret defaults to the system text colour (near-black) —
        // invisible on the glass. It's the field's ink, like the field editor's was.
        if tv.insertionPointColor != wantInk { tv.insertionPointColor = wantInk }
        // Guarded like the rest: re-stamping typing attributes on every render would
        // churn them mid-IME-composition for no reason.
        if (tv.typingAttributes[.font] as? NSFont) != wantFont
            || (tv.typingAttributes[.foregroundColor] as? NSColor) != wantInk {
            tv.typingAttributes = Self.attributes(fontSize: fontSize)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        /// Refreshed on every `updateNSView` so the callbacks below (notably
        /// `onCaretWidth`) never fire through a stale closure captured at init.
        var parent: PromptField
        /// One-shot latch: true once we've taken focus for the current rising edge
        /// of `focusTrigger`, reset when it falls. Prevents re-enqueuing focus on
        /// every render. (See updateNSView.)
        var didFocus = false
        /// The box we measure and the scroll view that clips it. Weak — AppKit owns
        /// the view tree; this is just our handle back into it from a notification.
        private weak var textView: PromptTextView?
        private weak var scrollView: NSScrollView?
        /// Last values pushed up, so a re-measure that lands on the same numbers
        /// doesn't kick SwiftUI into another render pass.
        private var lastHeight: CGFloat = -1
        private var lastCaretWidth: CGFloat = -1
        private var lastCaretY: CGFloat = .greatestFiniteMagnitude
        /// Pinyin/kana marked text is commonly wider than the glyph eventually
        /// committed. At a line boundary it can therefore wrap to line N+1, then
        /// snap back to line N as soon as the candidate is chosen. Remember the
        /// tallest layout reached by the active composition and hold that height
        /// after commit until committed text really reaches it. The next IME word
        /// normally does so; meanwhile the row no longer pumps up and down for each
        /// syllable near the boundary.
        private var wasComposing = false
        private var compositionPeakHeight: CGFloat = 0
        private var heldCompositionHeight: CGFloat?
        init(_ parent: PromptField) { self.parent = parent }
        deinit { NotificationCenter.default.removeObserver(self) }

        /// Subscribe to the two things the row's size and the inline hint ride on:
        ///  · the text STORAGE, because IME composition (typing pinyin before it
        ///    commits) edits marked text directly in the storage WITHOUT ever firing
        ///    `textDidChange` — `didProcessEditing` is the only hook that sees it, so
        ///    it's what lets the hint trail the pinyin live;
        ///  · the clip view's bounds, because once the box is capped at
        ///    `maxVisibleLines` the last line moves by SCROLLING, not by growing.
        func observe(scroll: NSScrollView, textView tv: PromptTextView) {
            self.scrollView = scroll
            self.textView = tv
            if let storage = tv.textStorage {
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(storageDidProcessEditing),
                    name: NSTextStorage.didProcessEditingNotification,
                    object: storage)
            }
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(clipBoundsDidChange),
                name: NSView.boundsDidChangeNotification,
                object: scroll.contentView)
        }

        func textDidBeginEditing(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            PromptField.disableEditorMagic(tv)
            // Registers the caret only — the island's LEVEL now follows the
            // composition (`syncCompositionLevel`), not merely having focus. Dropping
            // it for the whole session parked the island below the menu bar, which
            // then drew over the black notch cap (see `NotchPanel.editingLevel`).
            (tv.window as? NotchPanel)?.beginFieldEditing()
        }

        func textDidEndEditing(_ notification: Notification) {
            // Restore the resting level now that this box is done editing.
            guard let tv = notification.object as? PromptTextView else { return }
            (tv.window as? NotchPanel)?.endFieldEditing()
            // Once the caret leaves, there is no following composition to bridge
            // into. Return a provisional extra line to its real content height.
            resetHeightStabilization()
            report(for: tv)
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? PromptTextView else { return }
            // A non-IME edit (plain typing, delete, paste) is an explicit new
            // layout decision and may shrink normally. An IME commit arrives while
            // `wasComposing` is still true; that edge deliberately keeps the floor.
            if !tv.hasMarkedText(), !wasComposing {
                resetHeightStabilization()
            }
            parent.text = tv.string
            // Belt-and-suspenders: macOS can re-arm prediction as you type, so keep
            // it disabled on every change (cheap idempotent set).
            PromptField.disableEditorMagic(tv)
            // The commit edge, for the case where the storage observer isn't installed.
            syncCompositionLevel(tv)
            // Keeping the caret in view is `report`'s job, not this one's — it is
            // the only place that knows whether the box is actually scrolling yet.
            // Chasing the caret from here scrolled a box that had merely WRAPPED,
            // against a frame that hadn't grown yet: see `report`.
            report(for: tv)
        }

        /// The IME path: fires on EVERY storage edit, marked text included. Posted
        /// from inside `processEditing`, so defer one runloop tick before reading the
        /// layout — measuring mid-edit would read a half-applied state.
        @objc private func storageDidProcessEditing() {
            // The window level, unlike the measurement, is read SYNCHRONOUSLY: this
            // notification lands while the input server is handling the keystroke that
            // set the marked text, so stepping aside now means the candidate window
            // never gets a frame with the island on top of it.
            if let tv = textView { syncCompositionLevel(tv) }
            DispatchQueue.main.async { [weak self] in
                guard let self, let tv = self.textView else { return }
                self.report(for: tv)
            }
        }

        /// Park the island under the IME candidate window for exactly as long as
        /// there's a composition to show it for, and put it back above the menu bar
        /// the instant the candidate commits — see `NotchPanel.editingLevel` for why
        /// the level can't just stay down for the whole editing session.
        private func syncCompositionLevel(_ tv: NSTextView) {
            (tv.window as? NotchPanel)?.setComposing(tv.hasMarkedText())
        }

        @objc private func clipBoundsDidChange() {
            guard let tv = textView else { return }
            report(for: tv)
        }

        // MARK: Measurement (row height + where the last line ends, IME-aware)

        /// `report`, one runloop tick later. The only safe way to measure from inside
        /// `updateNSView`: the reports write SwiftUI state, which is illegal during
        /// SwiftUI's own update pass.
        func reportAfterUpdate(for tv: PromptTextView) {
            DispatchQueue.main.async { [weak self, weak tv] in
                guard let self, let tv else { return }
                self.report(for: tv)
            }
        }

        /// Drop only the IME wrap hysteresis. `lastHeight` stays intact so the next
        /// report publishes the real height when it differs from the held value.
        func resetHeightStabilization() {
            wasComposing = false
            compositionPeakHeight = 0
            heldCompositionHeight = nil
        }

        /// Lay the text out and push up the two numbers the row is built from: the
        /// box's height (clamped to the line cap) and where the last line ENDS — its
        /// width, and its vertical offset from the box's centre. Everything is read
        /// from the layout manager, so a wrapped line, a pasted paragraph and a
        /// half-composed pinyin syllable all measure the same way.
        func report(for tv: PromptTextView) {
            guard let layout = tv.layoutManager, let container = tv.textContainer else { return }
            layout.ensureLayout(for: container)

            let line = PromptField.lineHeight(for: parent.fontSize)
            // `usedRect` stops at the last GLYPH, so a trailing newline (an empty last
            // line the caret sits on) needs the extra fragment to be counted too.
            var used = layout.usedRect(for: container).height
            if layout.extraLineFragmentTextContainer != nil {
                used = max(used, layout.extraLineFragmentRect.maxY)
            }
            let cap = line * CGFloat(max(1, parent.maxVisibleLines))
            let measuredHeight = min(max(used, line), cap).rounded(.up)

            // Stabilize the IME boundary case described above. Growing is immediate
            // so marked text and its caret remain visible. Shrinking is deferred
            // only when the just-committed candidate is narrower than its marked
            // spelling; ordinary edits never acquire this floor.
            let composing = tv.hasMarkedText()
            if composing {
                if !wasComposing {
                    // Carry only an IME floor from the previous syllable. Using
                    // `lastHeight` here would also carry a stale height across a
                    // programmatic recall/submit before its deferred re-measure.
                    compositionPeakHeight = max(
                        measuredHeight, heldCompositionHeight ?? 0)
                } else {
                    compositionPeakHeight = max(compositionPeakHeight, measuredHeight)
                }
            } else if wasComposing {
                if compositionPeakHeight > measuredHeight + 0.5 {
                    heldCompositionHeight = max(
                        heldCompositionHeight ?? 0, compositionPeakHeight)
                }
                compositionPeakHeight = 0
            }
            wasComposing = composing

            var height = measuredHeight
            if let held = heldCompositionHeight {
                if measuredHeight >= held - 0.5 {
                    // Committed text has naturally occupied the provisional line;
                    // from here the real measurement owns the height again.
                    heldCompositionHeight = nil
                } else {
                    height = held
                }
            }

            // The scroller exists only once the text has capped out and truly
            // scrolls. Kept OFF otherwise so transient mid-animation layouts can't
            // flash the overlay knob over the panel (the ghost "cursor" bug).
            let scrollable = used > cap + 0.5
            if let scroll = scrollView {
                if scroll.hasVerticalScroller != scrollable {
                    scroll.hasVerticalScroller = scrollable
                }
                // Below the cap the box does not scroll, it GROWS — so the one
                // correct offset is the top, always. This used to be a blind
                // `scrollRangeToVisible` on every edit, and on the keystroke that
                // wrapped a line it did real damage: the caret had just moved to a
                // line the box wasn't tall enough for yet (the frame only catches up
                // a runloop tick later, once this report reaches SwiftUI), so AppKit
                // did the only thing it could and scrolled a whole line down —
                // shoving every already-drawn line up and slicing the first one off
                // at the top edge. Measured off a screen recording: the text jumped
                // up a full line, the top line was cut to a 5pt sliver, and it took
                // ~90ms to slide back. Pinning to the top means a wrap simply
                // reveals the new line at the bottom and never moves what's already
                // there.
                //
                // Past the cap the box really is a scroller and the caret has to be
                // chased — but now it happens AFTER the height is settled (the frame
                // stops changing at the cap), so it can only ever scroll content
                // that genuinely doesn't fit.
                if scrollable {
                    tv.scrollRangeToVisible(tv.selectedRange())
                } else if scroll.contentView.bounds.origin.y != 0 {
                    // Re-entrant by design: this posts a bounds change, which calls
                    // back into `report`. It terminates on the next pass — the
                    // origin is 0 by then, so this branch doesn't run again.
                    scroll.contentView.scroll(to: .zero)
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            }

            // Where the last line ends — the anchor the inline hint hangs off.
            var lineRect = NSRect(x: 0, y: 0, width: 0, height: line)
            var endX: CGFloat = 0
            if layout.extraLineFragmentTextContainer != nil {
                lineRect = layout.extraLineFragmentRect
                endX = layout.extraLineFragmentUsedRect.maxX
            } else if layout.numberOfGlyphs > 0 {
                let last = layout.numberOfGlyphs - 1
                lineRect = layout.lineFragmentRect(forGlyphAt: last, effectiveRange: nil)
                endX = layout.lineFragmentUsedRect(forGlyphAt: last, effectiveRange: nil).maxX
            }
            // The box scrolls under the cap, so the visible y of that line is its
            // position in the text MINUS however far the content has scrolled.
            let scrolled = scrollView?.contentView.bounds.origin.y ?? 0
            let centreY = lineRect.midY + tv.textContainerInset.height - scrolled
            let caretY = centreY - height / 2

            if height != lastHeight {
                lastHeight = height
                parent.onHeightChange(height)
            }
            let width = tv.string.isEmpty ? 0 : ceil(endX)
            if width != lastCaretWidth {
                lastCaretWidth = width
                parent.onCaretWidth(width)
            }
            if abs(caretY - lastCaretY) > 0.5 {
                lastCaretY = caretY
                parent.onCaretY(caretY)
            }
        }

        // MARK: Keys

        /// The authoritative kill switch for the word-completion popup: the text view
        /// asks its delegate for completions on every edit; returning an empty list
        /// (and -1 selection) means there's never anything to show, so the panel never
        /// appears. (Calling `complete(_:)` ourselves did the OPPOSITE — it *opened*
        /// the panel and looped — so that's gone.)
        func textView(_ textView: NSTextView,
                      completions words: [String],
                      forPartialWordRange charRange: NSRange,
                      indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            index?.pointee = -1
            return []
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Defensively swallow the "show completions" command too.
            if commandSelector == #selector(NSResponder.complete(_:)) {
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                // ⇧⏎ breaks the line instead of sending it — the way to write the
                // second paragraph the box can now show. Plain ⏎ still submits.
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                // Give the recent-list highlight first crack at Enter — if a row is
                // keyboard-selected, open it; otherwise submit the prompt as usual.
                if parent.onSubmitNav() { return true }
                parent.onSubmit()
                return true
            }
            // ⌥⏎ — AppKit's own "newline, don't submit" command. Let it through.
            if commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
                return false
            }
            // Tab steps the idle prompt's destination cycle (Ask → Note →
            // Remind); Shift-Tab flips the Ask ⇄ Agent bucket. A caller that
            // wants only one behaviour leaves `onBackTab` nil, and Shift-Tab
            // falls back to `onTab` (the old shared behaviour). The caller
            // decides whether to consume the key; unconsumed, it falls through
            // to its usual focus move.
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                return parent.onTab()
            }
            if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                return (parent.onBackTab ?? parent.onTab)()
            }
            // ← on an empty field means "go back" (start a new conversation) rather
            // than moving a caret that has nothing to move. With text present we let
            // it fall through so normal cursor movement still works while editing.
            if commandSelector == #selector(NSResponder.moveLeft(_:)),
               parent.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parent.onBack()
                return true
            }
            // ↓ / ↑ drive history recall / the recent list. They fire on an empty
            // field, and *also* while a recall session is live (`isRecalling`) — so
            // once ↑ has pulled a past question into the box, pressing ↑/↓ again
            // steps through history instead of moving the caret. Otherwise (text
            // present, no recall) the arrows move the caret as usual. `onDown`/`onUp`
            // return whether they consumed the key, so ↓ with no history at all still
            // falls through to default behaviour.
            // …and an open menu takes them first, text or no text: with `/no` in
            // the box the arrows belong to the menu's rows, not to the caret.
            let emptyOrRecalling =
                parent.isMenuOpen()
                || parent.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || parent.isRecalling()
            if commandSelector == #selector(NSResponder.moveDown(_:)), emptyOrRecalling {
                return parent.onDown()
            }
            if commandSelector == #selector(NSResponder.moveUp(_:)), emptyOrRecalling {
                return parent.onUp()
            }
            return false
        }
    }
}
