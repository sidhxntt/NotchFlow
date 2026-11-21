import AppKit
import ApplicationServices
import CoreLocation
import Carbon.HIToolbox
import Carbon.OpenScripting
import EventKit
import SwiftUI
import UserNotifications

/// A collapsed explanatory note: a quiet ⓘ that reveals its text in a popover on
/// click, so the settings rows stay a clean stack instead of carrying an always-on
/// caption under each one. Same register as the answer footer's model-info ⓘ — a
/// faint `info.circle` that brightens on hover, over the panel's own glass.
///
/// Takes either a plain string or a pre-built `AttributedString` (for hints with an
/// inline link), so both the terse captions and the "get a key at …" hints collapse
/// behind the same mark.
/// A bare word-action hanging off a settings row — Save / Test / Change /
/// Cancel / Disconnect / Choose…. Fourteen of these were spelled out by hand
/// across the panel as `.buttonStyle(.plain)` + a fixed ink, which made them the
/// one interactive class in the whole app that answered a hover with *nothing*;
/// several also rested at `text1`, brighter than the very row label they hang
/// off, so the eye read the escape hatch before the setting. One control now:
/// quiet at rest (secondary ink, below its label), full ink under the cursor.
struct SettingActionButton: View {
    var title: String
    /// Rest ink. Defaults to the secondary register; a de-emphasised action (a
    /// settled "Saved", a Save with nothing to save) passes something quieter.
    var tone: Color = Tokens.text2
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.sf(11, weight: .semibold))
            .foregroundStyle(hovering ? Tokens.text1 : tone)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
    }
}

struct SettingInfo: View {
    private let plain: String?
    private let rich: AttributedString?
    /// Glyph size and the square it's hit-tested in. The defaults are the
    /// settings-row register, where the mark hangs off a 13pt label with a whole
    /// row's height to sit in. Stats' token tile passes a smaller pair: there it
    /// trails an 11pt label inside a quarter-width column, and the 20pt square
    /// would set that column's own line height.
    var glyph: CGFloat = 12
    var hit: CGFloat = 20

    @State private var showing = false
    @State private var hovering = false

    init(_ text: String, glyph: CGFloat = 12, hit: CGFloat = 20) {
        plain = text; rich = nil; self.glyph = glyph; self.hit = hit
    }
    init(_ text: AttributedString, glyph: CGFloat = 12, hit: CGFloat = 20) {
        plain = nil; rich = text; self.glyph = glyph; self.hit = hit
    }

    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.sf(glyph, weight: .regular))
                .foregroundStyle(hovering ? Tokens.text2 : Tokens.text4)
                .frame(width: hit, height: hit)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            Group {
                if let rich { Text(rich) } else { Text(plain ?? "") }
            }
            .font(.sf(12))
            .foregroundStyle(Tokens.text2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 240, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .modifier(GlassPopoverBackground())
        }
    }
}

/// A dropdown styled to match the panel instead of the stock `Picker`'s
/// white-on-light `.menu` button (which read as a bright patch on the dark
/// glass). The trigger is a translucent dark chip — faint fill, hairline border,
/// light text, a up/down chevron — that brightens on hover; the popped-open list
/// stays the system's native (dark) context menu. `content` supplies the rows as
/// plain `Button`s that mutate the bound selection.
struct GlassMenu<Content: View>: View {
    var title: String
    /// Tighter fitting for dense rows — the agent card's 25pt bottom bar. The
    /// default is the settings pane's size, where these chips live in 34pt rows.
    var compact: Bool = false
    @ViewBuilder var content: () -> Content

    @State private var hovering = false

    private typealias Metrics = (font: CGFloat, chevron: CGFloat, gap: CGFloat,
                                 height: CGFloat, lead: CGFloat, trail: CGFloat)

    /// The compact fitting, one place: a 20pt pill that sits inside a 25pt bar.
    /// Its corner is always height/2 — fully round, the same capsule the effort
    /// slider's thumb and the compose row's chips use.
    // Computed, not stored: a generic type can't hold static storage.
    private static var compactMetrics: Metrics { (11.5, 8, 5, 20, 10, 8) }
    private static var regularMetrics: Metrics { (13, 10, 7, 30, 11, 9) }

    private var metrics: Metrics { compact ? Self.compactMetrics : Self.regularMetrics }
    /// The width a compact chip needs for `title`, measured in the face SwiftUI
    /// will draw it in. Callers that must size a rigid row around the chip (the
    /// agent card's bottom bar) can then do arithmetic instead of a geometry read.
    static func compactWidth(for title: String) -> CGFloat {
        let m = compactMetrics
        let font = NSFont.systemFont(ofSize: m.font, weight: .medium)
        let text = NSAttributedString(string: title, attributes: [.font: font]).size().width
        // text + gap + chevron glyph + both paddings
        return ceil(text) + m.gap + 10 + m.lead + m.trail
    }

    var body: some View {
        let m = metrics
        return Menu {
            content()
        } label: {
            HStack(spacing: m.gap) {
                if !title.isEmpty {
                    Text(title)
                        .font(.sf(m.font, weight: compact ? .medium : .regular))
                        .foregroundStyle(Tokens.text1)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.sf(m.chevron, weight: .semibold))
                    .foregroundStyle(Tokens.text3)
            }
            // Icon-only (empty title) pills get symmetric padding so the chevron
            // sits centered; labelled pills keep the tighter trailing inset.
            .padding(.leading, title.isEmpty ? m.trail : m.lead)
            .padding(.trailing, m.trail)
            .frame(height: m.height)
            .recessedSurface(in: Capsule(), lit: hovering)
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
    }
}

/// An invisible helper that captures the next key chord while `active` is true.
/// Installs a local `.keyDown` monitor (scoped to this app's own key window, so
/// it can't see other apps' input) and hands the virtual key code + modifier
/// flags to `onCapture`. Swallowing the event while recording keeps Esc/Space
/// from leaking into the panel underneath. The monitor is torn down the moment
/// `active` flips false or the view disappears — no global tap, no leak.
/// The shared shell behind the placement and Dock-icon picker cards: fixed
/// width, rounded fill + hairline border, and a hover lift that brightens both
/// by the same step the About rows use — so an unselected card answers the
/// pointer instead of sitting dead until it's clicked.
struct PickerCard<Content: View>: View {
    let selected: Bool
    /// The two-card rows keep the standard width; a three-card row asks for a
    /// narrower one so it still clears the pane's edge.
    var width: CGFloat = 108
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content()
                .padding(.vertical, 8)
                .frame(width: width)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(.white.opacity((selected ? 0.10 : 0.04) + (hovering ? 0.05 : 0)))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(.white.opacity((selected ? 0.40 : 0.10) + (hovering ? 0.10 : 0)),
                                      lineWidth: selected ? 1 : 0.5)
                )
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.rowFade), value: hovering)
    }
}

/// A miniature display glyph for the placement picker: a screen with a bright
/// pill on its top edge when it carries a notch island, over a laptop deck or a
/// monitor stand so the pair reads as built-in vs. external at a glance.
struct MiniDisplay: View {
    enum Kind { case laptop, external }
    let kind: Kind
    /// Whether this screen gets an island under the option being drawn — the
    /// pill and the brighter screen are the whole point of the diagram.
    let hasIsland: Bool

    var body: some View {
        VStack(spacing: kind == .laptop ? 1 : 0) {
            screen
            base
        }
    }

    private var screen: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 3)
                .fill(.white.opacity(hasIsland ? 0.16 : 0.05))
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(.white.opacity(hasIsland ? 0.55 : 0.20), lineWidth: 1)
            if hasIsland {
                Capsule()
                    .fill(.white.opacity(0.95))
                    .frame(width: 10, height: 3)
                    .padding(.top, 2)
            }
        }
        .frame(width: kind == .laptop ? 30 : 34,
               height: kind == .laptop ? 19 : 21)
    }

    @ViewBuilder private var base: some View {
        let tint = Color.white.opacity(hasIsland ? 0.45 : 0.18)
        switch kind {
        case .laptop:
            // The hinge-forward deck, a touch wider than the lid.
            RoundedRectangle(cornerRadius: 1)
                .fill(tint)
                .frame(width: 36, height: 2)
        case .external:
            // Monitor neck + foot.
            VStack(spacing: 0) {
                Rectangle()
                    .fill(tint)
                    .frame(width: 2, height: 3)
                RoundedRectangle(cornerRadius: 1)
                    .fill(tint)
                    .frame(width: 12, height: 2)
            }
        }
    }
}
