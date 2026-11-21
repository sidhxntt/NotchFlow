import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Empty prompt-shortcut window

/// A selected-text shortcut with no saved instruction. The selection is already
/// held by the controller; this face deliberately exposes only that fact, the
/// user's own shortcuts, and a focused instruction field. Sending promotes the
/// same shell into the compact streaming result view.
///
/// It is the one face with no window slab behind it: everything lives in ONE
/// floating card — the shortcut buttons over a sunken input row — with the
/// "Using copied text" badge and the band above it belonging to the root view,
/// which carries them unchanged into the answer face. This view is ONLY the
/// card, so asking grows that card in place and moves nothing else
/// (see `DetachedSessionRootView.compactShortcutFace`).
///
/// The card and the field inside it are the app's two existing recipes stacked:
/// the shortcut rows are `MenuCardRow`s (the `/` menu's rows, verbatim), and the
/// input is the `ComposerBox` recess every other input in a slab wears — same
/// 39pt resting row, same 13/6/6 insets, same lit floor and rim. One surface,
/// nothing invented for it.
struct CompactShortcutPromptView: View {
    @ObservedObject var state: DetachedWindowState
    let historyItems: [NotchModel.HistoryItem]
    var onSubmit: (String, ModelPin?) -> Void
    var onToggleHistory: () -> Void
    var onOpenHistory: (UUID) -> Void
    /// Straight to the page where these shortcuts are edited.
    var onOpenSettings: () -> Void = {}
    var onDesiredHeight: (CGFloat) -> Void = { _ in }
    /// Where this face's text cursor actually landed, in the window's own
    /// coordinates. The window is placed by it (`alignCaret`).
    var onCaretOffset: (CGPoint) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var focused = false
    @State private var caretWidth: CGFloat = 0
    @State private var inputHeight: CGFloat =
        PromptField.lineHeight(for: CompactShortcutPromptView.fontSize)
    /// Read once per appearance rather than per render: the list is the user's
    /// saved shortcuts, and the window's whole height is measured off its count
    /// (`restingHeight`) before the first frame is drawn.
    @State private var picks: [PromptShortcut] = CompactShortcutPromptView.quickPicks
    /// Everything above the field — the shortcut rows — arrives on
    /// one beat, coming down from over the card's top edge.
    @State private var contentIn = false

    /// The card's padding around its rows and its field, and the gap between the
    /// two. `cardPad` is what makes the card's corner concentric with the input
    /// recess inside it (`cardShape`).
    static let cardPad: CGFloat = 8
    static let cardGap: CGFloat = 8
    /// Match the field's first glyph to `MenuCardRow`'s title inset. PromptField
    /// contributes its own 2pt text-container inset, so only the remainder lives
    /// on the row itself.
    static let inputLeadingPadding: CGFloat = MenuCard.rowPad - PromptField.textInset
    private static let inputTrailingPadding: CGFloat = 4
    private static let inputVerticalPadding: CGFloat = 4
    /// The input's type size: the card's own row type, not the notch's 16.5 idle
    /// prompt. That size is scaled to the island — dropped into this small card
    /// it towers over the shortcut titles right above it, and the box reads as
    /// two type scales stacked. One size for the whole card.
    private static let fontSize = pickFontSize
    static var restingRowHeight: CGFloat {
        max(34, max(27, PromptField.lineHeight(for: fontSize))
            + inputVerticalPadding * 2)
    }
    static var cardCornerRadius: CGFloat {
        (cardPad * 2 + restingRowHeight) / 2
    }
    /// The shortcut rows' type and slot, raised from the `/` menu's numbers for
    /// the same reason: there they are a completion list under a caret, here they
    /// are the surface's primary buttons.
    static let pickFontSize: CGFloat = 14.5
    static let pickRowHeight: CGFloat = 32
    static let historyRowHeight: CGFloat = 34
    /// Match the main flow: let the Recent content extend naturally until it
    /// reaches the same compact-list ceiling, then hand the overflow to scrolling.
    static let historyMaxHeight: CGFloat = 220
    /// The strip between the composer and the first row's resting top — the main
    /// flow's `immersiveHeaderGap` (12) at card scale. It is NOT the plain
    /// `cardGap` this used to be: the runway lives INSIDE the ledger's scroll (as
    /// a safe-area inset, see `historyDrawer`), so rows dragged up travel into it
    /// and dissolve under the input the way the panel's immersive Recent dissolves
    /// under "Type anything…", instead of ending on a hard cut one gap below the
    /// field.
    static let historyTopRunway: CGFloat = 12
    /// Height of the frost band over that runway. Kept SHORTER than the runway on
    /// purpose (the same 4pt margin the main flow keeps): the band must taper fully
    /// to clear before it reaches the first row's resting top, or that row's
    /// blurred glyphs stack into a halo at rest (see `ProgressiveTopBlur`).
    static let historyTopBand: CGFloat = 8
    /// Give adjacent shortcut capsules enough separation to read as independent
    /// actions; the generic menu's 1pt row rhythm is too tight side by side.
    static let pickSpacing: CGFloat = 6
    /// Taper lengths for the rail's two overflow edges (`scrollEdgeFade`). The
    /// trailing one also sets the runway padding after the last chip.
    static let pickLeadingFade: CGFloat = 10
    static let pickTrailingFade: CGFloat = 24

    /// The shortcuts offered as buttons: the user's own, in the order they saved
    /// them, minus the ones with nothing to run and the ones the user has taken
    /// out of this box (each row's overflow menu). A chord is NOT required here —
    /// the button is the way to run it. ALL of them — the list scrolls.
    static var quickPicks: [PromptShortcut] {
        PromptShortcutStore.current
            .filter { !$0.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .filter(\.appearsInForceTouch)
    }

    /// Quick actions always occupy one horizontal rail; additional actions scroll
    /// sideways instead of making the pointer card grow vertically.
    static func picksHeight(_ count: Int) -> CGFloat {
        count > 0 ? pickRowHeight : 0
    }

    /// …plus its gap to the field — zero when the user has no shortcuts, so the
    /// card is then just the input it has always been.
    static func picksBlock(_ count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return picksHeight(count) + cardGap
    }

    /// Short history lists grow the card normally. Only long lists become a
    /// viewport, using the same 220pt ceiling as the main flow's compact Recent.
    static func historyHeight(_ count: Int) -> CGFloat {
        guard count > 0 else { return historyRowHeight }
        let whole = CGFloat(count) * historyRowHeight
            + CGFloat(max(0, count - 1)) * MenuCard.rowSpacing
        return min(whole, historyMaxHeight)
    }

    static func historyOverflows(_ count: Int) -> Bool {
        guard count > 0 else { return false }
        let whole = CGFloat(count) * historyRowHeight
            + CGFloat(max(0, count - 1)) * MenuCard.rowSpacing
        return whole > historyMaxHeight
    }

    /// The window's height with a one-line prompt: the band's chrome, the card
    /// (its padding, the picks, one input row) and the badge's own band under it
    /// — the same slot the answer's action pill lands in. A wrapped draft grows
    /// it from here.
    static func restingHeight(withPicks: Bool) -> CGFloat {
        CompactShortcutMetrics.chrome + cardPad * 2
            + (withPicks ? picksBlock(quickPicks.count) : 0)
            + restingRowHeight
    }
    /// The card at its shortest: the header line and the field, nothing between
    /// them — a box summoned on no selection, and the size the pressure cue is
    /// drawn at (nothing has been read yet when it goes up).
    static var restingHeight: CGFloat { restingHeight(withPicks: false) }

    /// The same height with the ledger already open — the size this face takes on
    /// the way BACK from an answer, where the draft is cleared (so the field is one
    /// line) and the drawer is expanded. Computed from the very numbers the layout
    /// uses (`cardHeight`), so the controller can put the window there in one set
    /// before the face mounts and the face's own first report is then a no-op.
    static func expandedHeight(withPicks: Bool, historyCount: Int) -> CGFloat {
        restingHeight(withPicks: withPicks) + historyBlock(historyCount)
    }

    /// Everything the open ledger adds under the input: its lead-in runway and
    /// the rows themselves. Named because it is also what has to come back OFF
    /// the window when the drawer's face leaves (see `openCompactAnswer`) — the
    /// ledger is a drawer hung under the box, never part of the box.
    static func historyBlock(_ count: Int) -> CGFloat {
        historyTopRunway + historyHeight(count)
    }

    private var trimmed: String {
        state.compactPromptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Quick actions operate on the captured selection. They stay out of a plain
    /// empty composer, and fold away on the first typed character.
    private var visiblePicks: [PromptShortcut] {
        let hasSelection = !state.compactSourceText
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasSelection && trimmed.isEmpty ? picks : []
    }

    /// The field's own slot — one line of its type size until it has reported a
    /// real layout, exactly as `ComposerBox` measures it.
    private var fieldHeight: CGFloat {
        inputHeight > 0 ? inputHeight : PromptField.lineHeight(for: Self.fontSize)
    }
    /// The input row: the field's slot plus the compact vertical inset.
    private var rowHeight: CGFloat {
        max(34, max(27, fieldHeight) + Self.inputVerticalPadding * 2)
    }

    private var cardHeight: CGFloat {
        Self.cardPad * 2 + Self.picksBlock(visiblePicks.count)
            + rowHeight
            + (state.forceTouchHistoryExpanded
                ? historyBlockHeight
                : 0)
    }

    private var historyBlockHeight: CGFloat {
        Self.historyBlock(historyItems.count)
    }

    private var desiredHeight: CGFloat {
        CompactShortcutMetrics.chrome + cardHeight
    }

    var body: some View {
        card
            .onAppear {
                picks = Self.quickPicks
                onDesiredHeight(desiredHeight)
                focused = false
                // The next runloop pass, not a timed beat: the window is already
                // key by the time this lands (`finishSettle` runs synchronously
                // after the hosting view is set), and a delay here is a delay
                // before the box takes a keystroke — the whole point of opening
                // it at the pointer.
                DispatchQueue.main.async { focused = true }
                guard !reduceMotion else { contentIn = true; return }
                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                    contentIn = true
                }
            }
            .onChange(of: desiredHeight) { _, height in onDesiredHeight(height) }
    }

    /// The whole face: the input first, then the user's shortcuts and History
    /// continuing below it in one card.
    ///
    /// The shortcuts unfold downward from the line the caret is already sitting
    /// on, so the input remains the card's stable anchor.
    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            composerRow

            VStack(alignment: .leading, spacing: 0) {
                if !visiblePicks.isEmpty {
                    GeometryReader { proxy in
                        let count = visiblePicks.count
                        let spacing = Self.pickSpacing
                        let visibleSlots = count <= 2 ? CGFloat(count) : 2.25
                        let visibleGaps: CGFloat = count <= 1 ? 0 : (count == 2 ? 1 : 2)
                        let itemWidth = max(1,
                            (proxy.size.width - spacing * visibleGaps) / visibleSlots)

                        ScrollView(.horizontal) {
                            LazyHStack(spacing: spacing) {
                                ForEach(visiblePicks) { pick in
                                    // No accessory: the shortcut that opened this
                                    // window is the one the user just pressed. One
                                    // item fills the rail, two split it, and a longer
                                    // list leaves the next item peeking into view.
                                    MenuCardRow(title: pick.displayName,
                                                fontSize: Self.pickFontSize,
                                                height: Self.pickRowHeight,
                                                selected: false,
                                                promptShortcutID: pick.id,
                                                action: { onSubmit(pick.prompt, pick.pin) })
                                        .frame(width: itemWidth)
                                }
                            }
                            .frame(height: Self.pickRowHeight)
                            // Runway past the trailing fade, so the last chip can
                            // scroll fully clear of the taper instead of resting
                            // dimmed at the end of the rail (same trick the
                            // settings page's shortcut rail uses).
                            .padding(.trailing, Self.pickTrailingFade)
                        }
                        .scrollIndicators(.never)
                        // The rail dissolves into both boundaries rather than
                        // being sliced by the viewport — the panel's shared
                        // overflow language (`scrollEdgeFade`), the same one the
                        // History drawer below and the settings page's shortcut
                        // rail already speak. It replaces a per-item
                        // `scrollTransition` that snapped a whole capsule between
                        // opaque and clear: a chip crossing the edge became a flat
                        // half-transparent slab with a hard cut down its side,
                        // which is exactly the harshness this taper removes.
                        // Leading taper is kept short: at rest the first chip sits
                        // flush at 0, so anything longer would visibly thin its
                        // own corner instead of only softening what scrolls past.
                        .scrollEdgeFade(leading: true,
                                        trailing: true,
                                        leadingFade: Self.pickLeadingFade,
                                        trailingFade: Self.pickTrailingFade)
                    }
                    .frame(height: Self.picksHeight(visiblePicks.count))
                    .padding(.top, Self.cardGap)
                }
            }
            .opacity(contentIn ? 1 : 0)
            .offset(y: contentIn ? 0 : -10)
            // Keep the ledger laid out even while it is closing. The window's
            // top-aligned reveal mask folds these rows away progressively; making
            // this slot zero-height (or transparent) as soon as the state flipped
            // cleared every row before that fold had a chance to pass over it.
            historyDrawer
                .frame(height: historyBlockHeight, alignment: .top)
                .clipped()
                .opacity(state.forceTouchHistoryExpanded ? 1 : 0)
                .scaleEffect(state.forceTouchHistoryExpanded ? 1 : 0.97,
                             anchor: .top)
                .offset(y: state.forceTouchHistoryExpanded ? 0 : -8)
                .allowsHitTesting(state.forceTouchHistoryExpanded)
                .animation(reduceMotion ? nil : CompactHistoryMotion.spring,
                           value: state.forceTouchHistoryExpanded)
        }
        // While a force click is still being decided the card is drawn as its own
        // cap, and a field laid out inside a 48pt circle is neither useful nor
        // cheap — the glass is the whole cue. The content keeps its full-width
        // layout underneath (it is the glass that is narrow, see `cardGlass`), so
        // the stretch never re-wraps a line of text.
        .opacity(state.pressDepth == nil ? 1 : 0)
        .padding(Self.cardPad)
        .frame(height: cardHeight, alignment: .top)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: inputHeight)
        .animation(CompactHistoryMotion.spring, value: trimmed.isEmpty)
    }

    /// The field and its one trailing slot: collapsed History at rest, replaced
    /// in place by Send while the user is typing. Once expanded, the History
    /// disclosure moves to the drawer's bottom bar beside Settings.
    private var composerRow: some View {
        HStack(alignment: .center, spacing: 6) {
            inputRow
                .frame(maxWidth: .infinity)

            CompactShortcutTrailingControl(
                hasText: !trimmed.isEmpty,
                showsHistory: state.forceTouchInvocation,
                historyExpanded: state.forceTouchHistoryExpanded,
                send: send,
                toggleHistory: onToggleHistory)
        }
    }

    /// The Force Touch-only ledger, physically inside the composer card. Its rows
    /// continue directly below the input; selecting one asks the controller to
    /// replace this face with that thread in the same NSWindow.
    private var historyDrawer: some View {
        Group {
            if historyItems.isEmpty {
                Text("No Force Touch history yet")
                    .font(.sf(13))
                    .foregroundStyle(Tokens.text4)
                    .frame(maxWidth: .infinity, minHeight: Self.historyRowHeight,
                           alignment: .center)
                    // Sit in the same slot a first row would, below the runway.
                    .padding(.top, Self.historyTopRunway)
            } else {
                ScrollView {
                    // Lazy, like the main flow's Recent: the ledger holds every
                    // Force Touch conversation but only ~6 rows fit the drawer.
                    // Eager rows were built for the whole ledger on every layout
                    // pass — including while the card sat collapsed, since the
                    // drawer stays mounted for the fold mask — and again on every
                    // frame of the disclosure.
                    LazyVStack(spacing: MenuCard.rowSpacing) {
                        ForEach(historyItems) { item in
                            MenuCardRow(
                                title: item.displayTitle,
                                accessory: relativeTime(item.t),
                                fontSize: 13.5,
                                accessoryFontSize: 11.5,
                                height: Self.historyRowHeight,
                                selected: false,
                                action: { onOpenHistory(item.id) })
                        }
                    }
                }
                .scrollIndicators(.never)
                // The runway is a SAFE-AREA INSET, not `.padding(.top)` — the
                // main flow's hard-won distinction (see `historyList(immersive:)`
                // in NotchBody): padding is content, and a LazyVStack settling its
                // height re-anchors the scroll to the first *item*, which steals a
                // padded runway and rests row 0 under the field. An inset lives
                // outside the scrollable content, so there is nothing there to
                // scroll away — rows still travel up into it, they just come to
                // rest clear of the composer.
                .safeAreaInset(edge: .top, spacing: 0) {
                    Color.clear.frame(height: Self.historyTopRunway)
                }
                // Both edges taper now, as they do in the panel: the top dissolves
                // rows sliding up under the input, the bottom rows sliding down
                // behind the settings chip.
                .scrollEdgeFade(top: true,
                                bottom: Self.historyOverflows(historyItems.count),
                                topFade: Self.historyTopRunway,
                                bottomFade: 10)
                // …and frost them on the way, so a row passing under "Type
                // anything…" reads as pushed back behind the field rather than
                // crossing its glyphs. Band shorter than the runway, so no
                // resting row sits inside it.
                .progressiveTopBlur(height: Self.historyTopBand, maxRadius: 10)
            }
        }
        .frame(height: Self.historyTopRunway + Self.historyHeight(historyItems.count))
        // Match the main flow's immersive Recent: bottom chrome floats over the
        // list instead of reserving a separate row beneath it. Settings anchors
        // the left corner and the expanded History disclosure moves to the right,
        // so the way out of the list sits on the same bottom baseline.
        .overlay(alignment: .bottom) {
            HStack(spacing: 6) {
                settingsControl
                Spacer(minLength: 8)
                CompactHistoryDisclosure(
                    expanded: true,
                    action: onToggleHistory)
            }
        }
    }

    private var settingsControl: some View {
        GlassIconButton(
            systemName: "slider.horizontal.3",
            hoverSystemName: "arrow.up.right",
            help: L("recent.menu.settings"),
            size: 34,
            showsTooltip: false,
            action: onOpenSettings)
    }

    /// The instruction line sits directly on the compact card's glass so the
    /// composer reads as one continuous surface rather than a nested recess.
    private var inputRow: some View {
        ZStack(alignment: .leading) {
            PromptField(
                text: $state.compactPromptDraft,
                placeholder: "",
                fontSize: Self.fontSize,
                focusTrigger: focused,
                maxVisibleLines: NotchBody.promptMaxLines,
                onSubmit: send,
                // Match the visible disclosure: with an empty Force Touch
                // composer, ↓ pulls the popup-local History ledger open.
                onDown: {
                    guard state.forceTouchInvocation,
                          !state.forceTouchHistoryExpanded
                    else { return false }
                    onToggleHistory()
                    return true
                },
                onTab: { true },
                onCaretWidth: { caretWidth = $0 },
                onHeightChange: { inputHeight = $0 }
            )
            .frame(height: fieldHeight)

            if state.compactPromptDraft.isEmpty && caretWidth == 0 {
                // "What should I do with it?" only means something when there IS
                // an "it". Pressed on nothing (or with the context dropped), this
                // is the ordinary prompt and says what the notch's own box says.
                Text(L(state.compactSourceText.isEmpty
                       ? "input.placeholder"
                       : "shortcuts.promptAction.window.placeholder"))
                    .font(.sf(Self.fontSize))
                    .foregroundStyle(Tokens.placeholder)
                    .lineLimit(1)
                    .padding(.leading, PromptField.textInset)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .frame(height: max(27, fieldHeight))
        .background(CaretProbe(report: onCaretOffset))
        .animation(.easeOut(duration: 0.16), value: caretWidth == 0)
        .animation(.easeOut(duration: 0.16), value: state.compactPromptDraft.isEmpty)
        .padding(.leading, Self.inputLeadingPadding)
        .padding(.trailing, Self.inputTrailingPadding)
        .padding(.vertical, Self.inputVerticalPadding)
    }

    private func send() {
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed, nil)
    }
}
