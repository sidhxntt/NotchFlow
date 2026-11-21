import SwiftUI
import AppKit
import Combine
import PDFKit
import ImageIO

// MARK: - Floating menu card

/// The floating-menu idiom, shared by every little card that pops off the panel
/// in its own window: the `/` command menu and the Ask chip's model quick menu.
///
/// One recipe, one set of numbers — a glass slab with a generous radius, rows as
/// capsule washes inside it, one short word per row with at most one bit of
/// trailing furniture (a shortcut chord, a `CLI` tag). Anything that wants to be
/// "a menu hanging off the island" wears this instead of inventing its own
/// paddings and radii, so the two can never drift apart again.
enum MenuCard {
    /// The card's padding around its rows, and each row's around its word.
    /// `rowPad` clears the capsule wash's own curve, so a word never sits in it.
    static let cardPad: CGFloat = 6
    static let rowPad: CGFloat = 12
    static let fontSize: CGFloat = 11.5
    /// The trailing accessory's type size, and the minimum gap it keeps from the
    /// word (a row's HStack spacing sits on both sides of the `Spacer`) — both
    /// feed `width(titles:)`.
    static let accessoryFontSize: CGFloat = 10
    static let accessoryGap: CGFloat = 12
    /// Concentric with the rows: `cardPad` + a row capsule's own radius.
    static let radius: CGFloat = 18
    /// Rows are a fixed height at a fixed spacing, so a card that glides one wash
    /// across its rows (the agent picker) can do the arithmetic instead of
    /// measuring — and every menu keeps the same rhythm.
    static let rowHeight: CGFloat = 26
    static let rowSpacing: CGFloat = 1
    /// Row top to the next row's top.
    static var rowStride: CGFloat { rowHeight + rowSpacing }

    /// The width a card needs to show every one of its rows whole: the widest
    /// `word + gap + accessory`, plus both paddings. Measured in the very fonts
    /// SwiftUI will draw them in (`Font.sf` IS the system face, the same trick
    /// `BucketWord.labelWidth` uses) — plain arithmetic instead of a geometry
    /// read, so the card is right on its first frame.
    ///
    /// A point of slack over the measurement: glyphs drawn from a fallback face
    /// (a chord's ⌥, a vendor mark) can round a hair past what the attributed
    /// measure reports, and any overshoot lands on the word as an ellipsis.
    static func width(titles: [(String, String?)], max cap: CGFloat = .infinity) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let accessoryFont = NSFont.systemFont(ofSize: accessoryFontSize, weight: .regular)
        let widest = titles.map { title, accessory -> CGFloat in
            let word = NSAttributedString(string: title, attributes: [.font: font]).size().width
            guard let accessory else { return word }
            let tail = NSAttributedString(string: accessory,
                                          attributes: [.font: accessoryFont]).size().width
            return word + accessoryGap + tail
        }.max() ?? 0
        return min(ceil(widest) + 2 + (rowPad + cardPad) * 2, cap)
    }
}

/// Geometry and typography of the Recent ⋯ menu. Result metadata cards use
/// these same values so the two floating-card species cannot drift by a point or
/// a font weight again.
enum ManageMenuMetrics {
    static let radius: CGFloat = 20
    static let cardPadding: CGFloat = 6
    static let rowSpacing: CGFloat = 2
    static let rowHorizontalPadding: CGFloat = 8
    static let rowVerticalPadding: CGFloat = 7
    static let rowContentSpacing: CGFloat = 8
    static let fontSize: CGFloat = 12
    static let accessoryFontSize: CGFloat = 10
    static var rowTextHeight: CGFloat {
        ceil(NSFont.systemFont(ofSize: fontSize, weight: .medium)
            .boundingRectForFont.height)
    }
}

/// The stable colour wash shared by a Prompt Shortcut everywhere it appears.
/// Its UUID, rather than list position or process-seeded `hashValue`, chooses the
/// hue, so Settings and the compact picker always show the
/// same shortcut with the same light across launches and reordering.
private enum PromptShortcutCardPalette {
    static let hues: [Color] = [
        Color(red: 0.22, green: 0.48, blue: 0.68),
        Color(red: 0.38, green: 0.30, blue: 0.62),
        Color(red: 0.60, green: 0.27, blue: 0.39),
        Color(red: 0.56, green: 0.40, blue: 0.20),
        Color(red: 0.20, green: 0.51, blue: 0.43),
    ]

    static func light(_ id: UUID) -> Color {
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        let sum = bytes.reduce(0) { $0 &+ Int($1) }
        return hues[sum % hues.count]
    }
}

struct PromptShortcutCardSurface<S: InsettableShape>: View {
    let id: UUID
    let hovering: Bool
    let shape: S

    var body: some View {
        let light = PromptShortcutCardPalette.light(id)
        ZStack {
            shape.fill(.black.opacity(0.42))
            shape.fill(light.opacity(hovering ? 0.20 : 0.07))
            shape.fill(.white.opacity(hovering ? 0.045 : 0))
            shape.fill(
                LinearGradient(
                    stops: [
                        .init(color: light.opacity(0.46), location: 0),
                        .init(color: light.opacity(0.14), location: 0.38),
                        .init(color: light.opacity(0.01), location: 0.88),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .blendMode(.plusLighter)
            .opacity(hovering ? 0.88 : 0.55)
            shape.strokeBorder(.white.opacity(hovering ? 0.28 : 0.09),
                               lineWidth: hovering ? 0.8 : 0.5)
        }
        .compositingGroup()
    }
}

/// One row of a `MenuCard`: a word, and at most one bit of trailing furniture.
///
/// The wash is a full capsule — one short word wide, it reads as a pill at this
/// size and nests concentrically inside the card's own radius. Two states, never
/// competing: `selected` is the card's real highlight (the `/` menu's shared
/// keyboard+pointer cursor, the Ask menu's armed model), and a plain hover wears
/// a fainter wash under it. Each row catching the cursor taps the trackpad — the
/// alignment tap, so running down a menu feels like detents — but only when the
/// cursor actually changes what's highlighted, and only on the way in.
struct MenuCardRow: View {
    let title: String
    /// The row's one bit of trailing furniture: a shortcut chord, a `CLI` tag.
    var accessory: String? = nil
    /// The row's type size and slot. Defaulted to the `/` menu's own numbers —
    /// a completion list under a caret reads at 11.5 — and raised where the rows
    /// are the surface's primary buttons rather than a filtered list of words
    /// (the prompt-shortcut composer).
    var fontSize: CGFloat = MenuCard.fontSize
    var accessoryFontSize: CGFloat = MenuCard.accessoryFontSize
    var height: CGFloat = MenuCard.rowHeight
    /// Draw the word in the emphasized weight — for menus where the highlight
    /// means "this is the one in effect" rather than "this is where the cursor is".
    var emphasized: Bool = false
    let selected: Bool
    /// Draw the selected wash here. Off for a card that gilides ONE wash across
    /// its rows (the agent picker's springy glide) — the row still takes the
    /// selected ink, it just doesn't paint a second highlight under it.
    var wash: Bool = true
    /// Prompt Shortcut rows reuse the exact stable colour surface from Settings.
    /// Nil leaves every ordinary menu row on its existing neutral wash.
    var promptShortcutID: UUID? = nil
    /// For menus whose highlight follows the pointer: called as the row catches
    /// the cursor, so hover and the keyboard drive the SAME highlight instead of
    /// painting a second one.
    var onHoverIn: (() -> Void)? = nil
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        let shape = Capsule(style: .continuous)
        return Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.sf(fontSize, weight: emphasized && selected ? .medium : .regular))
                    .foregroundStyle(selected || (promptShortcutID != nil && hovering)
                        ? Tokens.text1 : Tokens.text3)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let accessory {
                    Spacer(minLength: 0)
                    Text(accessory)
                        .font(.sf(accessoryFontSize, weight: .regular))
                        .foregroundStyle(selected ? Tokens.text2 : Tokens.text4)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, MenuCard.rowPad)
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if let promptShortcutID {
                    PromptShortcutCardSurface(id: promptShortcutID,
                                              hovering: hovering,
                                              shape: shape)
                } else if wash, selected {
                    shape.fill(Color.white.opacity(0.14))
                } else if hovering, !selected {
                    shape.fill(Color.white.opacity(0.06))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovering = inside
            guard inside else { return }
            if !selected { Haptics.alignment() }
            onHoverIn?()
        }
        .animation(.easeOut(duration: Tokens.rowFade), value: selected)
        .animation(.easeOut(duration: Tokens.rowFade), value: hovering)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// The card's own material: `.clear` glass refracting what's behind it under a
/// dark veil, a top sheen, and a specular rim — the manage menu's recipe.
///
/// The veil is heavy (0.66) because these cards live in their OWN windows and
/// routinely hang off the island onto whatever the desktop happens to be — a
/// bright Finder window, a white page. Lighter, the words washed out the moment
/// the card left the glass; this makes a menu read the same over anything.
struct MenuCardSlab: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: MenuCard.radius, style: .continuous)
        ZStack {
            shape.fill(.clear).nativeGlass(in: shape)
                .overlay(shape.fill(Color.black.opacity(0.66)))
            shape
                .fill(LinearGradient(colors: [.white.opacity(0.10), .clear],
                                     startPoint: .top, endPoint: .center))
                .blendMode(.plusLighter)
            shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(0.30), .white.opacity(0.07)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 0.75)
        }
        .allowsHitTesting(false)
    }
}

extension View {
    /// The exact glass slab worn by Recent's ⋯ menu: same radius, veil, sheen,
    /// rim, clipping and shadows. Metadata cards use this instead of the denser
    /// generic `MenuCard` slab.
    func manageMenuCardBackground() -> some View {
        let shape = RoundedRectangle(cornerRadius: ManageMenuMetrics.radius,
                                     style: .continuous)
        return background {
            shape.fill(.clear).nativeGlass(in: shape)
                .overlay(shape.fill(Color.black.opacity(0.38)))
        }
        .overlay(
            shape.fill(
                LinearGradient(colors: [.white.opacity(0.09), .clear],
                               startPoint: .top, endPoint: .center)
            )
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
        )
        .overlay(
            shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(0.30), .white.opacity(0.07)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 0.75
            )
            .allowsHitTesting(false)
        )
        .clipShape(shape)
        .shadow(color: .black.opacity(0.30), radius: 3, y: 1)
        .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
    }

    /// The slab behind a menu that draws its own window (the `/` card), plus the
    /// two shadows that lift it off whatever it hangs over.
    func menuCardBackground() -> some View {
        let shape = RoundedRectangle(cornerRadius: MenuCard.radius, style: .continuous)
        return background { MenuCardSlab() }
            .clipShape(shape)
            .shadow(color: .black.opacity(0.30), radius: 3, y: 1)
            .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
    }

    /// The same slab for a menu presented in an `NSPopover` — the popover owns the
    /// window (and its shadow), so this replaces its background instead of drawing
    /// one behind the content. Same call `GlassPopoverBackground` makes.
    func menuCardPresentationBackground() -> some View {
        Group {
            if #available(macOS 13.3, *) {
                presentationBackground { MenuCardSlab() }
            } else {
                background { MenuCardSlab() }
            }
        }
    }
}
