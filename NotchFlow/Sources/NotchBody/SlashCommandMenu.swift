import SwiftUI
import AppKit

/// The `/` command menu — a small floating card of plain words under the prompt.
///
/// Deliberately spare: one word per row, no icons, no descriptions, no shortcut
/// column. The whole menu is a completion list for what the user is already
/// typing, so the words ARE the content — anything else beside them is furniture
/// competing with the four things that matter. It sizes to its longest word and
/// hangs at the prompt's left edge, in the same Liquid Glass the manage menu
/// wears, so it reads as a card hovering over the panel rather than a new block
/// bolted into it.
///
/// Keyboard and pointer drive the SAME highlight (`model.slashHighlight`): ↑/↓
/// walk it, hover moves it under the cursor, Enter/Tab land it. One index, so the
/// row the eye is on is always the row Enter picks.
///
/// The card itself knows nothing about where it is drawn — `SlashMenuHost` puts it
/// in its own window.
struct SlashCommandMenu: View {
    @ObservedObject var model: NotchModel

    /// The chord that runs a row, when it has one. Only prompt shortcuts do — a
    /// `/` destination is a mode, not a globally bound key. Its name and its chord
    /// sit side by side (the card widens to fit both) rather than the chord
    /// truncating the name under it.
    static func chord(for match: NotchModel.SlashMatch) -> String? {
        switch match {
        case .shortcut(let shortcut): return shortcut.shortcut?.displayString
        case .skill: return "Skill"
        case .mode: return nil
        }
    }

    private static func title(for match: NotchModel.SlashMatch) -> String {
        switch match {
        case .mode(let command): return command.title
        case .shortcut(let shortcut): return shortcut.displayName
        case .skill(let skill): return skill.displayName
        }
    }

    /// Measured off ALL the rows the menu can ever hold — modes, ready prompt
    /// shortcuts, and enabled skills — so the card holds still as the list filters
    /// down instead of breathing in and out per keystroke.
    private var cardWidth: CGFloat {
        let modes = NotchModel.SlashCommand.allCases.map { ($0.title, String?.none) }
        let shortcuts = PromptShortcutStore.current.filter(\.isReady)
            .map { ($0.displayName, $0.shortcut?.displayString) }
        let skills = model.agentSkills.map { ($0.displayName, String?.some("Skill")) }
        return MenuCard.width(titles: modes + shortcuts + skills, max: 260)
    }

    private var menuHeight: CGFloat {
        let rows = min(model.slashMatches.count, 9)
        guard rows > 0 else { return 0 }
        return MenuCard.cardPad * 2
            + CGFloat(rows) * MenuCard.rowHeight
            + CGFloat(rows - 1) * MenuCard.rowSpacing
    }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: MenuCard.rowSpacing) {
                ForEach(Array(model.slashMatches.enumerated()), id: \.element.id) { index, match in
                    MenuCardRow(
                        title: Self.title(for: match),
                        accessory: Self.chord(for: match),
                        selected: index == model.slashHighlight,
                        onHoverIn: { model.slashHighlight = index },
                        action: {
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                                model.applySlashCommand(match)
                            }
                        }
                    )
                }
            }
            .padding(MenuCard.cardPad)
        }
        .scrollIndicators(.hidden)
        .frame(height: menuHeight)
        // Sized by its own words, pinned left under the caret — a menu, not a bar.
        // An explicit width rather than `fixedSize()`: under a fixed size every row
        // gets its IDEAL width, so the selected row's wash would stop at the end of
        // its own word instead of spanning the card.
        .frame(width: cardWidth, alignment: .leading)
    }
}
