import SwiftUI
import AppKit
import Combine
import PDFKit
import ImageIO

/// The `ask_user` question card: the model paused mid-answer to ask one
/// multiple-choice question, and the round is suspended until the user picks (or
/// walks away and the wait times out).
///
/// It wears the same clothes as the `ClearHistoryConfirm` dialog — Liquid Glass
/// slab, bold question over muted detail, full-width capsule actions — but stays
/// **embedded in the answer's flow** rather than floating over a scrim: this is a
/// step in the reply, not a modal demanding the whole island.
struct UserQuestionCard: View {
    let question: NotchModel.PendingUserQuestion
    /// Called with the option's text when the user picks it.
    var choose: (String) -> Void

    /// `manage_app_settings` hands its confirmation over as one string: the
    /// question on the first line, then one `Label → value` summary per changed
    /// setting. Kept as a single blob it ran as one paragraph that overflowed the
    /// card and collided with the buttons; split, the question can carry a title's
    /// weight and each change gets its own row.
    private var lines: [String] {
        question.question
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var title: String { lines.first ?? question.question }
    private var changes: [String] { Array(lines.dropFirst()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.sf(13.5, weight: .semibold))
                    .foregroundStyle(Tokens.text2)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(changes, id: \.self) { changeRow($0) }
            }

            if question.inlineOptions {
                // Cancel / Confirm as a pair of glass capsules, the dialog's own
                // two-button row. The tool always puts the affirmative last, so
                // the tail option carries the material and the rest stay quiet —
                // two peer capsules would read as two equal choices.
                HStack(spacing: 10) {
                    ForEach(Array(question.options.enumerated()), id: \.element) { index, option in
                        ConfirmDialogButton(
                            title: option,
                            kind: index == question.options.count - 1 ? .neutral : .quiet
                        ) { choose(option) }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    optionRows()
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        // A confirmation is a small decision, so it stops well short of the
        // column — but it still needs a *definite* ceiling, or its detail lines
        // propose a width wider than the panel and get clipped. Longer clarifying
        // questions keep the full-column layout so their option labels can wrap.
        .frame(maxWidth: question.inlineOptions ? 340 : .infinity,
               alignment: .leading)
        .background { glass }
    }

    /// One pending change, already written as a whole sentence upstream ("Dock
    /// icon will change to Hidden") — so it renders as plain body text, the thing
    /// actually being asked about, and carries the card's largest type.
    private func changeRow(_ line: String) -> some View {
        Text(line)
            .font(.sf(15))
            .foregroundStyle(Tokens.text1)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The card's material — the confirmation dialog's Liquid Glass recipe
    /// (`nativeGlass` refraction, top-down sheen, specular rim), run airy: it
    /// floats on the panel's own glass rather than over arbitrary windows, so it
    /// needs no occluding veil and no drop shadow to sit apart.
    private var glass: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return ZStack {
            shape.fill(.clear)
                .nativeGlass(in: shape, tintOpacity: 0.14)
                .overlay(shape.fill(Color.white.opacity(0.04)))
            shape
                .fill(LinearGradient(colors: [.white.opacity(0.10), .clear],
                                     startPoint: .top, endPoint: .center))
                .blendMode(.plusLighter)
            shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.06)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 0.75)
        }
        .compositingGroup()
    }

    /// Options are de-duplicated by the tool before they get here, so the string
    /// itself is a safe `ForEach` id.
    @ViewBuilder
    private func optionRows() -> some View {
        ForEach(question.options, id: \.self) { option in
            UserQuestionOptionRow(title: option) { choose(option) }
        }
    }
}

/// One tappable option row on the question card. Full-width and left-aligned so
/// the whole line is the target; brightens on hover like the other quiet controls.
private struct UserQuestionOptionRow: View {
    var title: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.sf(12.5))
                .foregroundStyle(hovering ? Tokens.text1 : Tokens.text2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(hovering ? 0.13 : 0.07))
                )
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
    }
}
