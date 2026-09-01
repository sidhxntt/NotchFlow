import AppKit
import SwiftUI

/// Immediate utility actions that sit above the File tray and Calendar, in a
/// horizontally scrolling strip.
///
/// Was a fixed three-up row of equal-width chips. Six actions do not fit at
/// equal width in a notch-wide panel — shrinking them to fit would make every
/// label truncate — so the strip scrolls instead, and each chip sizes to its
/// own content.
struct NotchQuickUtilitiesView: View {
    /// Which action's overlay is on screen right now, so its chip can show
    /// that it is the one currently selected — the same "which tab is active"
    /// signal the Chat/Media/Utilities bar gives, at chip scale.
    let selection: QuickUtilityAction?
    let onSelect: (QuickUtilityAction) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                // Not `allCases` — Settings → Utilities can retire a chip nobody
                // uses so the strip stops scrolling past it (see
                // `QuickUtilityStrip`). The surfaces themselves are unaffected.
                ForEach(QuickUtilityStrip.visibleActions) { action in
                    chip(for: action)
                }
            }
            // The scroll view's own edge insets, not the row's padding — so the
            // first and last chip get the same breathing room from the panel
            // edge that a fixed row would have had, instead of being flush
            // against it the moment the content is wide enough to scroll.
            .padding(.horizontal, 7)
            .padding(.vertical, 7)
        }
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private func chip(for action: QuickUtilityAction) -> some View {
        let isSelected = selection == action
        return Button {
            perform(action)
        } label: {
            Label(action.title, systemImage: action.symbolName)
                .font(.sf(10.5, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .padding(.vertical, 7)
                .padding(.horizontal, 9)
                // The capsule IS the button. A plain-styled button hit-tests
                // only its drawn glyphs otherwise, so clicks landed on the
                // word and nowhere else on the chip.
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Tokens.accent : Tokens.text2)
        .background {
            Capsule(style: .continuous)
                .fill(isSelected ? Tokens.accent.opacity(0.16) : Color.white.opacity(0.07))
        }
        .accessibilityLabel(action.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Every action now has a card of its own in the panel — Reminder used to
    /// launch Reminders.app, which threw the user out of the notch to type one
    /// line.
    private func perform(_ action: QuickUtilityAction) {
        onSelect(action)
    }
}
