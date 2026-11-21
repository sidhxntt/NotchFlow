import SwiftUI
import AppKit

/// History row highlight — a *hint* of glass, not a slab of it. The earlier
/// `.ultraThinMaterial` plate rendered at full strength and turned the whole row
/// into a bright frosted block that upstaged the text. Here the same idea is kept
/// but dialled right down: a barely-there white wash to say "this row", with a thin
/// material laid over it at very low opacity so a touch of real glass refraction
/// shows through — present enough to feel like the panel's own material, faint
/// enough that the text stays the hero. Keyboard selection (↑/↓) reads a little
/// firmer than a passing hover; a hovered-selected row firmer still.
struct HistoryRowStyle: ButtonStyle {
    var selected: Bool = false
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        // 0 → nothing, up to 1 → most present. Even "most" is gentle.
        let presence: Double = selected ? (hovering ? 1.0 : 0.72) : (hovering ? 0.5 : 0)
        return configuration.label
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    // Faint white floor so the row reads even where the material has
                    // nothing dark behind it to refract.
                    .fill(.white.opacity(0.03 * presence))
                    // A whisper of real glass on top — thin material, held to a low
                    // opacity so it shimmers rather than slabs.
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.thinMaterial)
                            .opacity(0.22 * presence)
                    )
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: Tokens.rowFade), value: selected)
            .animation(.easeOut(duration: Tokens.rowFade), value: hovering)
    }
}

/// Hover wash for a row sitting on a floating GLASS CARD — the ⋯ manage menu.
/// `HistoryRowStyle` can't do this job here: its highlight is mostly a
/// `.thinMaterial` plate, and a material laid over a `glassEffect` card samples
/// the same backdrop the card already samples, so the wash all but vanishes and
/// the row reads as having no hover at all. Plain white instead — the same
/// treatment the other glass popover menus use (`AskRecentModelRow`,
/// `AgentModelRow`), shaped as a full capsule around the row.
struct ManageMenuRowStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        let wash: Double = configuration.isPressed ? 0.10 : (hovering ? 0.06 : 0)
        return configuration.label
            .background(
                Capsule()
                    .fill(.white.opacity(wash))
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: Tokens.rowFade), value: hovering)
    }
}

/// The ONE colour a source wears wherever it shows a face — the Recent filter
/// chips, the collapsed active-filter tag, the capture rows' "open in Notes /
/// Reminders" pill, and every one of the archive window's chips, rows and
/// bubbles. Note the Notes amber, Remind the Reminders orange, Ask a cool blue,
/// Agent the violet; the values themselves live in `Tokens`, beside the matching
/// `Panel.intentTint` the composer reads, so the input's colour story and the
/// history's are literally the same table.
///
/// This used to be three separate copies (`filterTint` / `captureJumpTint` here,
/// `archiveTint` over in the archive window) that happened to agree — one edit
/// away from a source reading amber in the notch and yellow in the window.
extension NotchModel.HistoryItem.Source {
    var tint: Color {
        switch self {
        case .ask:      return Tokens.askTint
        case .note:     return Tokens.noteTint
        case .reminder: return Tokens.reminderTint
        case .agent:    return Tokens.agentTint
        }
    }
}

/// Recent-row VoiceOver wiring, split by kind. An Ask row combines its children
/// into one element that reopens the thread. A capture row stays a *container*
/// so its separate trailing jump button remains an independently-focusable
/// control — folding it in (`.combine`) would hide the one control that jumps.
struct RecentRowAccessibility: ViewModifier {
    let item: NotchModel.HistoryItem
    func body(content: Content) -> some View {
        if item.source.isThread {
            content
                .accessibilityElement(children: .combine)
                .accessibilityLabel(item.displayTitle)
                .accessibilityHint(L("recent.hint.ask"))
        } else {
            content
                .accessibilityElement(children: .contain)
                .accessibilityLabel(item.displayTitle)
        }
    }
}

/// What the input is wearing right now. `Panel` has no agent case on purpose —
/// the agent isn't a classifier destination, it's an armed mode — so an active
/// agent compose would otherwise fall back to Ask's blue while its chips and
/// Recent rows wear violet. These two resolve that: agent compose paints the
/// input the agent violet, everything else its destination's colour.
extension NotchModel {
    /// Saturated body — for the field's low-opacity background wash.
    var submitTint: Color {
        submitGoesToAgent ? Tokens.agentTint : effectiveSubmitPanel.intentTint
    }
    /// The luminous face — for the rim pulse and other ink on the dark glass.
    var submitInk: Color {
        submitGoesToAgent ? Tokens.agentInk : effectiveSubmitPanel.intentInk
    }
}

/// The destination colour of an intent — the SAME palette everywhere a
/// destination shows its face: Ask a cool blue, Capture the amber sitting
/// halfway between the Notes yellow and the Reminders orange (its two leaves
/// route to both, so the mode wears neither). Read by the destination pill
/// under the prompt, the follow-up field's background wash, and the
/// intent-change rim pulse, so the
/// input's colour story always matches the filter chips and capture chips.
extension NotchModel.Panel {
    /// Saturated body colour — right for low-opacity WASHES over the dark glass
    /// (the follow-up box's background lean), where saturation survives dilution.
    var intentTint: Color {
        switch self {
        case .chat:              return Tokens.askTint
        case .note, .reminder:   return Tokens.captureTint
        }
    }

    /// The same hue lifted toward white — for TEXT and glows on the dark glass.
    /// A fully saturated colour used as ink sinks into the dark background (blue
    /// especially reads as a murky shadow); these luminous pastels read as
    /// coloured *light* instead, keeping the hue legible and the ghost elegant.
    var intentInk: Color {
        switch self {
        case .chat:              return Tokens.askInk
        case .note, .reminder:   return Tokens.captureInk
        }
    }
}

/// A glass pill carrying an icon and a word, used for the two actions parked at the
/// bottom of the recent list. Same Liquid Glass language as `GlassTextButton` — it
/// brightens on hover and gives under a press — with a `destructive` face that reads
/// soft red so Clear can never be mistaken for the archive link beside it.
struct HistoryFooterButton: View {
    var icon: String
    var title: String
    var action: () -> Void

    @State private var hovering = false

    /// Both footer pills read the same weight — Clear used to sit at near-white
    /// while "See all history" was meta-dim, and the mismatch made the pair look
    /// like two different controls rather than one row. The destructive step is
    /// carried by the confirmation card, not by a brighter label.
    private var tint: Color {
        hovering ? Tokens.text2 : Tokens.text4
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.sf(10, weight: .medium))
                Text(title)
                    .font(.sf(11, weight: .medium))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassCapsule(in: Capsule(), brighter: hovering)
            .contentShape(Capsule())
        }
        .buttonStyle(GlassPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
    }
}

/// The one place a history source maps to its filter-chip face: the label key
/// and the source's app colour (Notes amber, Reminders orange, Ask a cool blue,
/// Agent a violet).
/// Shared by the manage menu's chips and the collapsed active-filter chip so the
/// two can never drift apart.
extension NotchModel.HistoryItem.Source {
    fileprivate var filterTitle: String {
        switch self {
        case .note:     return L("recent.filter.note")
        case .reminder: return L("recent.filter.remind")
        case .ask:      return L("recent.filter.ask")
        case .agent:    return L("recent.filter.agent")
        }
    }
}

/// The collapsed-state reminder that a source filter is narrowing the list: a
/// small tinted capsule beside the ⋯ naming the filter, with an × — tap anywhere
/// on it to clear the filter and show everything again. Brightens on hover like
/// every other glass chip.
struct ActiveFilterChip: View {
    @ObservedObject var model: NotchModel
    var source: NotchModel.HistoryItem.Source

    @State private var hovering = false

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                model.historySourceFilter = nil
            }
        } label: {
            HStack(spacing: 5) {
                Text(source.filterTitle)
                    .font(.sf(11, weight: .medium))
                    .foregroundStyle(hovering ? Tokens.text1 : Tokens.text2)
                Image(systemName: "xmark")
                    .font(.sf(8, weight: .semibold))
                    .foregroundStyle(hovering ? Tokens.text2 : Tokens.text4)
            }
            .padding(.horizontal, 12)
            // Match the ⋯ chip beside it exactly (GlassIconButton size 34), so the
            // pair reads as one bar of same-height controls, not a big circle with
            // a smaller tag hanging off it.
            .frame(height: 34)
            .glassCapsule(in: Capsule(), brighter: hovering, tint: source.tint)
            .contentShape(Capsule())
        }
        .buttonStyle(GlassPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
    }
}

/// "Using selected text from Safari": the selection the panel came in with,
/// stated above the input, with an × to drop it.
///
/// Why it is a statement rather than silent plumbing: the text was picked up
/// without anyone asking for it, out of a window the user may not even be
/// looking at any more — so the panel has to say what it is about to send, and
/// hand back a way to say no. Modelled on `ActiveFilterChip`, the other "this
/// context is in effect, here is how to end it" chip, sized down to the footnote
/// scale of the compact composer's badge since this one sits over the input
/// instead of in a row of buttons. Only the × is a control: dropping the
/// selection can't be undone without going back and highlighting it again, so a
/// stray click anywhere on the chip must not do it.
struct SelectionContextChip: View {
    var source: String?
    var selection: String
    var drop: () -> Void

    @State private var hovering = false
    @State private var hoveringDrop = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "text.quote")
                .font(.sf(9.5, weight: .semibold))
                .foregroundStyle(Tokens.text4)
            Text(source.map { L("selection.context.from", $0) } ?? L("selection.context"))
                .font(.sf(11.5, weight: .medium))
                .foregroundStyle(hovering ? Tokens.text2 : Tokens.text3)
                .lineLimit(1)
            Button(action: drop) {
                Image(systemName: "xmark")
                    .font(.sf(8.5, weight: .bold))
                    .foregroundStyle(hoveringDrop ? Tokens.text1 : Tokens.text4)
                    .frame(width: 14, height: 14)
                    .background(Circle().fill(.white.opacity(hoveringDrop ? 0.14 : 0)))
                    .contentShape(Circle())
            }
            .buttonStyle(GlassPressStyle())
            .onHover { hoveringDrop = $0 }
            .accessibilityLabel(L("selection.context.drop"))
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .frame(height: 24)
        .glassCapsule(in: Capsule(), brighter: hovering)
        .contentShape(Capsule())
        // The chip names the source; the tooltip shows what is actually riding
        // along, so "which selection?" is answerable without sending anything.
        .help(preview)
        .onHover { inside in
            hovering = inside
            if !inside { hoveringDrop = false }
        }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
        .animation(.easeOut(duration: Tokens.hoverFade), value: hoveringDrop)
    }

    /// One line of the selection for the tooltip — enough to recognise it by,
    /// never a wall of text hanging off the pointer.
    private var preview: String {
        let flat = selection
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return flat.count > 140 ? String(flat.prefix(140)) + "…" : flat
    }
}

/// The directional slide-in applied to the idle prompt while ↑/↓ recall swaps a
/// past question in. `offset` is the live vertical displacement (driven from a
/// spring back to 0); opacity is derived from it so the text fades up as it
/// settles — full at rest, dipping to ~0.4 at the 7pt extreme. A no-op when
/// `active` is false (the follow-up field), so it never touches that path.
struct RecallSlide: ViewModifier {
    var offset: CGFloat
    var active: Bool
    func body(content: Content) -> some View {
        if active {
            content
                .offset(y: offset)
                .opacity(1 - min(abs(offset) / 7, 1) * 0.6)
        } else {
            content
        }
    }
}

/// A compact three-dot wave for a Recent row whose answer is still streaming —
/// the same calm cadence as `ThinkingDots`, sized down to sit in the trailing
/// slot where the timestamp lands once the answer settles. Sits in the row at
/// `.firstTextBaseline`, so the dots align with the title rather than floating.
struct RecentPendingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false
    var body: some View {
        HStack(spacing: 3.5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Tokens.text4)
                    .frame(width: 3.5, height: 3.5)
                    .opacity(reduceMotion ? 0.55 : (phase ? 0.9 : 0.25))
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.62)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.16),
                        value: phase
                    )
            }
        }
        .onAppear { if !reduceMotion { phase = true } }
        .accessibilityLabel(L("recent.answering"))
    }
}
