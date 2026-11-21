import SwiftUI
import AppKit

/// The user's question, shown in a quiet chat bubble. The bubble's corner radius
/// adapts to how tall the text is: a single line stays a full pill (radius = half
/// the height, exactly like the old `Capsule`), but once the text wraps to two or
/// more lines the radius drops to a fixed, smaller value. A capsule at multi-line
/// height rounds its corners by half the *tall* box — a bloated, over-round blob;
/// the smaller radius keeps a multi-line quote reading as a tidy card.
/// `style: .continuous` matches the panel's other rounded shapes.
struct UserQuestionBubble: View {
    let text: String

    /// Prompt shortcuts keep the captured text inside an explicit wire envelope so
    /// the model cannot mistake it for the instruction. That envelope is transport
    /// syntax, not user-facing copy: when it reaches a visible question bubble,
    /// present the captured body as a real quote instead of exposing the tags.
    private var selectedTextQuote: (instruction: String, selection: String)? {
        let opening = "<selected_text>"
        let closing = "</selected_text>"
        guard let openRange = text.range(of: opening),
              let closeRange = text.range(of: closing,
                                          range: openRange.upperBound..<text.endIndex),
              text[closeRange.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        let selection = text[openRange.upperBound..<closeRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selection.isEmpty else { return nil }
        return (
            instruction: text[..<openRange.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines),
            selection: selection
        )
    }

    /// What the bubble visibly lays out (the transport tags do not consume lines or
    /// influence the corner shape once they have become a quote).
    private var visibleText: String {
        guard let quote = selectedTextQuote else { return text }
        return quote.instruction.isEmpty
            ? quote.selection
            : quote.instruction + "\n" + quote.selection
    }

    /// Whether the user tapped to expand a truncated question. Starts collapsed so a
    /// pasted wall of text never dominates the thread on first render.
    @State private var expanded = false

    /// Collapsed cap: a long pasted question folds to this many lines, keeping the
    /// bubble a tidy card instead of a scroll-eating slab. Tapping expands to full.
    private let collapsedLineLimit = 6

    /// Ceiling for the EXPANDED bubble. A very long question doesn't grow without
    /// bound — past this the text scrolls INSIDE the bubble. This is the fix for the
    /// freeze: an unbounded expanded height fed back into the result view's
    /// `AnswerHeightKey` measurement (which flips the clip/scroll layout at 300pt),
    /// and the two height feedbacks drove an endless relayout. Capping the bubble
    /// keeps its contribution bounded, so that loop can't form.
    private let expandedMaxHeight: CGFloat = 240

    /// Corner radius — a fixed modest card once the bubble is clearly multi-line, a
    /// pill when it's a short single/double line. Derived purely from the text (no
    /// geometry read), so there's no measurement feeding back into layout.
    private let multiLineRadius: CGFloat = 16
    private let pillRadius: CGFloat = 16.5   // ~half a single-line bubble height

    /// Cheap, allocation-light estimate of whether the collapsed text is truncated —
    /// purely from the string, NO GeometryReader (a height probe here is exactly what
    /// caused the relayout freeze). Counts hard newlines, plus an approximate wrap
    /// count for long unbroken lines (~48 chars/line at this width/font). If that
    /// exceeds the collapsed cap, the question is being clipped, so show the toggle.
    private var isTruncated: Bool { estimatedLines(exceed: collapsedLineLimit) }

    /// Whether the EXPANDED text outgrows `expandedMaxHeight` and actually scrolls
    /// inside the bubble — the gate for the scroll-edge fade below. Same string-only
    /// estimate as `isTruncated` (no geometry read): ~19pt per line at this font, so
    /// 240pt ≈ 12 lines.
    private var expandedOverflows: Bool { estimatedLines(exceed: 12) }

    private func estimatedLines(exceed cap: Int) -> Bool {
        estimatedLineCount(for: visibleText) > cap
    }

    private func estimatedLineCount(for value: String) -> Int {
        value.split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { $0 + 1 + $1.count / 48 }
    }

    /// Pill only for a genuinely short question; anything that could wrap past a line
    /// or two reads better as a rounded card.
    private var radius: CGFloat {
        isTruncated || visibleText.count > 44 ? multiLineRadius : pillRadius
    }

    @ViewBuilder
    private var questionText: some View {
        if let quote = selectedTextQuote {
            VStack(alignment: .leading, spacing: 8) {
                if !quote.instruction.isEmpty {
                    Text(quote.instruction)
                        .font(.sf(14.5, weight: .medium))
                        .tracking(-0.1)
                        .foregroundStyle(Tokens.text2)
                        // Reserve at least one collapsed line for the quote itself.
                        .lineLimit(expanded ? nil : collapsedLineLimit - 1)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(quote.selection)
                    .font(.sf(14.5, weight: .medium))
                    .tracking(-0.1)
                    .foregroundStyle(Tokens.text3)
                    .lineLimit(expanded ? nil : max(
                        1,
                        collapsedLineLimit - min(
                            collapsedLineLimit - 1,
                            estimatedLineCount(for: quote.instruction)
                        )
                    ))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 11)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Tokens.text4.opacity(0.8))
                            .frame(width: 2)
                            .padding(.vertical, 2)
                    }
            }
            // The question itself is selectable too — drag to highlight and copy
            // both the instruction and its quote, without the transport tags.
            .textSelection(.enabled)
        } else {
            Text(text)
                .font(.sf(14.5, weight: .medium))
                .tracking(-0.1)
                .foregroundStyle(Tokens.text2)
                // Collapsed to a fixed cap until the user expands; nil = unlimited.
                .lineLimit(expanded ? nil : collapsedLineLimit)
                .fixedSize(horizontal: false, vertical: true)
                // The question itself is selectable too — drag to highlight and
                // copy it, same as the answer below. (It's a settled user turn,
                // never streaming, so there's no tail-follow scroll to fight.)
                .textSelection(.enabled)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Expanded: the full text can be tall, so it scrolls WITHIN a capped
            // frame instead of pushing the bubble (and the whole result view) past
            // any height. Collapsed: the plain clamped text, no scroll container.
            if expanded {
                ScrollView(.vertical, showsIndicators: false) {
                    questionText
                        // Breathing room each fade falls across, so the first / last
                        // line can rest outside its taper at full strength at either
                        // end (the shared fade discipline — never dim resting text).
                        .padding(.top, expandedOverflows ? 16 : 0)
                        .padding(.bottom, expandedOverflows ? 28 : 0)
                }
                .frame(maxHeight: expandedMaxHeight)
                // The shared dissolve instead of a hard cut where the text scrolls
                // past either of the bubble's edges. Gated on actual overflow — a
                // bubble whose full text fits sizes to content, and fading it would
                // dim real lines. A thin feather up top: one line leaving is all it
                // has to swallow.
                .scrollEdgeFade(top: expandedOverflows, bottom: expandedOverflows, topFade: 16, bottomFade: 28)
            } else {
                questionText
            }

            // Only shown when the collapsed text is actually cut off. A quiet grey
            // toggle in the same `text4` as the timestamps — never shouts.
            if isTruncated {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() }
                } label: {
                    Text(expanded ? L("bubble.showLess") : L("bubble.showMore"))
                        .font(.sf(11, weight: .medium))
                        .tracking(0.2)
                        .foregroundStyle(Tokens.text4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Tokens.hairline, lineWidth: 1)
                )
        )
    }
}
