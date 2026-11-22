import SwiftUI
import AppKit

@MainActor
extension NotchBody {
    // MARK: - Note save feedback

    /// The line under the input after a note save — `nil` when there's nothing to
    /// report, so the row simply doesn't exist (zero height) and the resting prompt
    /// is just the input.
    ///
    /// Deliberately quiet: no icons, no colour, no echo of what was typed — just one
    /// small line in the same `text4` grey as RECENT and the timestamps, so a save
    /// confirms without ever shouting. The success path settles to "Added to Notes";
    /// "Saving…" reads the same grey while the write is in flight. The error path is
    /// the one exception — it's actionable (usually "grant permission"), so it gets
    /// a touch more presence (text2, still no loud icon/colour) to make sure it's
    /// seen, since silently failing to save would be worse than a quiet cue.
    var noteFeedbackContent: AnyView? {
        if let err = model.noteError {
            return AnyView(
                Text(err)
                    .font(.sf(12))
                    .foregroundStyle(Tokens.text2)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            )
        }
        // Both save paths now store their full display string (e.g.
        // "Added to Reminders · Daily" / "Added to Notes") in lastSavedNote,
        // so the cue text is whatever the model put there — no binary rebuild here.
        if let cue = model.lastSavedNote {
            return AnyView(feedbackLine(cue))
        }
        if model.noteSaving {
            return AnyView(feedbackLine(L("input.saving")))
        }
        return nil
    }

    /// One line of the calm note-save feedback: small, `text4` grey, no icon —
    /// the same whisper as the RECENT label.
    func feedbackLine(_ text: String) -> some View {
        Text(text)
            .font(.sf(12))
            .tracking(0.2)
            .foregroundStyle(Tokens.text4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The carried-selection chip in its slot above the input (see
    /// `SelectionContextChip`). Leading-aligned like every other line in this
    /// stack, and it fades out the moment the × is hit — the drop has to look
    /// like the panel letting go of something, not a row blinking off.
    func selectionContextLine(_ selection: String) -> some View {
        SelectionContextChip(source: model.selectionContextSource,
                             selection: selection) {
            withAnimation(.easeOut(duration: 0.18)) { model.dropSelectionContext() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Said once, in the slot the chip just vacated, the first time the user drops
    /// a carried selection: there's a switch for this. It takes the same footnote
    /// voice as the note-save cue and retires itself after a few seconds — and it
    /// is a button, because a hint that names Settings and then makes you go find
    /// them yourself is half a hint. Tapping it lands on Chat → Capture, where
    /// the row is.
    var selectionContextHintLine: some View {
        Button {
            model.retireSelectionContextHint()
            model.settingsSection = InlineSettingsView.Section.chat.rawValue
            withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
                model.openSettings()
            }
        } label: {
            HStack(spacing: 4) {
                Text(L("selection.context.hint.off"))
                Image(systemName: "arrow.up.right")
                    .font(.sf(9, weight: .semibold))
            }
            .font(.sf(12))
            .tracking(0.2)
            .foregroundStyle(hoveringSelectionHint ? Tokens.text2 : Tokens.text4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveringSelectionHint = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hoveringSelectionHint)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The ↑/↓ recall counter shown above the input while walking history: a small
    /// clock glyph + "pos / total" (newest = 1), so you can see
    /// how far back the current recalled question sits.
    func recallCounterLine(_ recall: (pos: Int, total: Int)) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.sf(10, weight: .semibold))
                .foregroundStyle(Tokens.text4)
                .baselineOffset(-1)
            Text("\(recall.pos) / \(recall.total)")
                .font(.sf(11, weight: .medium))
                .monospacedDigit()
                .tracking(0.3)
                .foregroundStyle(Tokens.text4)
                .lineLimit(1)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 8)
    }
}
