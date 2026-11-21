import SwiftUI
import AppKit
import Combine
import PDFKit
import ImageIO

/// One block of an answer, extracted from `MarkdownBlocks.row(for:)` so both the
/// settled renderer and the streaming renderer share identical block styling. The
/// two callers differ only in animation/selection wrapping, never in how a given
/// block kind looks.
struct MarkdownBlockRow: View, Equatable {
    let block: MarkdownBlock
    var baseFont: CGFloat = 15
    var color: Color = Tokens.text1
    var onInAppCopy: (() -> Void)? = nil
    /// True only on the growing tail block of a streaming answer: its fresh
    /// glyphs fade in (macOS 15+). Must participate in `==` — when a new block
    /// appends, the previous tail's content is unchanged but this flag flips,
    /// and the row must re-evaluate to drop the fade renderer.
    var fadeTail: Bool = false
    /// Render this block's prose in the handwriting voice (Settings → Appearance).
    /// A stored property rather than an `@Environment` read because the row is
    /// wrapped in `.equatable()` — an environment change alone would not get past
    /// that gate, so the setting could flip with the answer still typeset. The
    /// containers above (`MarkdownBlocks` / `StreamingMarkdown`) do the environment
    /// read and hand the value down.
    var hand: Bool = false

    /// The row-level diff gate (used via `.equatable()` at every call site).
    /// `onInAppCopy` is a closure, and a closure field defeats SwiftUI's
    /// synthesized memberwise diff — without this, EVERY row of an answer
    /// re-evaluated its body (re-running `InlineMarkdownText`'s AttributedString
    /// parse) on every ~33ms streaming flush, so a flush's cost grew with the
    /// length of the already-settled text above the tail. Comparing the visual
    /// inputs only is safe: the closure is the same capture for the life of the
    /// thread, so a row whose block/font/colour are unchanged renders identically.
    static func == (lhs: MarkdownBlockRow, rhs: MarkdownBlockRow) -> Bool {
        lhs.block == rhs.block && lhs.baseFont == rhs.baseFont && lhs.color == rhs.color
            && lhs.fadeTail == rhs.fadeTail && lhs.hand == rhs.hand
    }

    /// This row's prose face at `size` — the printed one, or the hand.
    private func face(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        proseFont(size, weight: weight, hand: hand)
    }

    /// What `InlineMarkdownText` needs to re-face emphasis inside this row, or
    /// nil when the row is typeset and SwiftUI's trait promotion is correct.
    private func emphasis(_ size: CGFloat, opacity: Double = 1) -> InlineMarkdownText.HandEmphasis? {
        guard hand else { return nil }
        return .init(size: size)
    }

    /// Leading for a line of this row's prose. A hand needs a touch more air.
    private func leading(_ factor: CGFloat) -> CGFloat {
        baseFont * (factor + (hand ? Handwriting.extraLineSpacing : 0))
    }

    /// Only linear text rows fade; code and tables render whole (fading a code
    /// block per-glyph reads as flicker over syntax, and both were excluded by
    /// the industry implementations this follows), and a divider has no glyphs.
    private static func fadeable(_ block: MarkdownBlock) -> Bool {
        switch block {
        case .code, .table, .divider, .image, .pdf: return false
        default: return true
        }
    }

    /// The fade's growth signal: the row's rendered-text character count. Raw
    /// block text (markdown syntax included) slightly overshoots the laid-out
    /// glyph count when inline `**`/`` ` `` markers get stripped — the error only
    /// ever makes a glyph fade a beat early, never re-fade, so it's harmless.
    private static func fadeLength(_ block: MarkdownBlock) -> Int {
        switch block {
        case .heading(_, let t), .bullet(let t, _), .ordered(_, let t, _),
             .task(_, let t, _), .quote(let t), .paragraph(let t), .math(let t):
            return t.count
        case .code, .table, .divider, .image, .pdf:
            return 0
        }
    }

    var body: some View {
        rowContent
            .modifier(TailFadeIfAvailable(
                active: fadeTail && Self.fadeable(block),
                length: Self.fadeLength(block),
                hand: hand))
    }

    @ViewBuilder
    private var rowContent: some View {
        switch block {
        case .heading(let level, let text):
            let size = max(baseFont, baseFont + CGFloat(7 - min(level, 5)) * 1.5)
            InlineMarkdownText(text, linkColor: color, hand: emphasis(size))
                .font(face(size, weight: .semibold))
                // Negative tracking tightens SF; the hand is already loosely
                // spaced by design and pulling it in reads as cramped.
                .tracking(hand ? 0 : -0.1)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

        case .bullet(let text, let indent):
            listRow(text: text, indent: indent) {
                if hand {
                    // A pen leaves a blob, not a disc. Sized off the type so it
                    // tracks the answer's scale like the glyph it replaces.
                    Ink.Dot(seed: seed &+ indent)
                        .fill(color.opacity(0.7))
                        .frame(width: baseFont * 0.3, height: baseFont * 0.3)
                        // Nudged to sit on the text's x-height rather than its
                        // baseline, where a round mark reads as having dropped.
                        .offset(y: -baseFont * 0.18)
                } else {
                    markerText(bulletGlyph(for: indent))
                }
            }

        case .ordered(let number, let text, let indent):
            // The numeral follows the answer's voice — a hand-written list numbers
            // itself in the same hand. Shantell's bounce puts each numeral at its
            // own height in the gutter, which is the point.
            listRow(text: text, indent: indent) { markerText("\(number).") }

        case .task(let done, let text, let indent):
            // A checked-off item dims: the checkbox already says "done", the
            // fade just keeps open items visually in front.
            listRow(text: text, indent: indent, textOpacity: done ? 0.55 : 1) {
                if hand {
                    drawnCheckbox(done: done)
                } else {
                    markerText(Image(systemName: done ? "checkmark.square" : "square"))
                }
            }

        case .quote(let text):
            InlineMarkdownText(text, linkColor: color.opacity(0.8), hand: emphasis(baseFont, opacity: 0.8))
                .font(face(baseFont))
                .tracking(hand ? 0 : -0.05)
                .lineSpacing(leading(0.45))
                .foregroundStyle(color.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.leading, 13)
                .overlay(alignment: .leading) {
                    // The accent bar that marks the island as quoted speech —
                    // ruled, or drawn down the margin in the same 3pt footprint.
                    Group {
                        if hand {
                            Ink.Stroke(seed: seed)
                                .stroke(color.opacity(0.28),
                                        style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                        } else {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(color.opacity(0.25))
                        }
                    }
                    .frame(width: 3)
                }
                .padding(.vertical, 2)

        case .paragraph(let text):
            InlineMarkdownText(text, linkColor: color, hand: emphasis(baseFont))
                .font(face(baseFont))
                .tracking(hand ? 0 : -0.05)
                .lineSpacing(leading(0.6))
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

        case .code(_, let text):
            CodeBlockView(text: text, baseFont: baseFont, color: color, onInAppCopy: onInAppCopy)

        case .table(let header, let rows):
            MarkdownTableView(header: header, rows: rows, baseFont: baseFont, color: color, hand: hand)

        case .math(let text):
            // Display math: the Unicode rendering, centred like a typeset
            // formula, a shade larger than body so it reads as an island.
            //
            // Stays typeset in handwriting mode, deliberately. `MathTypeset`
            // builds its formulas out of superscripts, radicals and Greek —
            // glyphs the handwriting faces mostly don't carry, so a "handwritten"
            // formula would in fact be a formula in three different faces at
            // three different weights. Notation is machine text, like code.
            Text(MathTypeset.unicode(text))
                .font(.sf(baseFont + 1))
                .tracking(0.1)
                .lineSpacing(baseFont * 0.5)
                .foregroundStyle(color)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 2)

        case .image(let alt, let url):
            AnswerImageView(alt: alt, urlString: url, baseFont: baseFont, color: color)

        case .pdf(let title, let url):
            AnswerPDFView(title: title, urlString: url, baseFont: baseFont, color: color)

        case .divider:
            Group {
                if hand {
                    // Drawn at 1pt rather than the ruled 0.5: a wobbling
                    // half-point line lands between pixels and stipples instead
                    // of reading as a stroke. The extra weight is spread by the
                    // wobble, so it still reads as the same quiet hairline.
                    Ink.Rule(seed: seed)
                        .stroke(Tokens.hairline,
                                style: StrokeStyle(lineWidth: 1, lineCap: .round))
                        .frame(height: 3)
                } else {
                    Rectangle()
                        .fill(Tokens.hairline)
                        .frame(height: 0.5)
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// A list item: a fixed-width gutter holds the marker so wrapped lines hang
    /// neatly under the text, not under the bullet. `indent` steps the whole row
    /// right for nested items; `textOpacity` lets done tasks read as settled.
    ///
    /// The marker is a view rather than a `Text` because in the hand two of the
    /// three kinds aren't type at all — the bullet and the checkbox are drawn.
    private func listRow<Marker: View>(text: String,
                                       indent: Int = 0,
                                       textOpacity: Double = 1,
                                       @ViewBuilder marker: () -> Marker) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            marker()
                .frame(minWidth: 16, alignment: .trailing)
            InlineMarkdownText(text, linkColor: color.opacity(textOpacity), hand: emphasis(baseFont, opacity: textOpacity))
                .font(face(baseFont))
                .tracking(hand ? 0 : -0.05)
                .lineSpacing(leading(0.5))
                .foregroundStyle(color.opacity(textOpacity))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(indent) * 16)
    }

    /// A typeset marker in the gutter — the printed bullet, every ordered
    /// numeral, the printed checkbox.
    private func markerText(_ content: some StringProtocol) -> some View {
        Text(String(content))
            .font(face(baseFont, weight: .medium).monospacedDigit())
            .foregroundStyle(color.opacity(0.7))
    }

    private func markerText(_ image: Image) -> some View {
        Text(image)
            .font(.sf(baseFont, weight: .medium))
            .foregroundStyle(color.opacity(0.7))
    }

    /// A task's box, drawn: four not-quite-meeting strokes, plus a tick that
    /// breaks out past the corner when it's done.
    private func drawnCheckbox(done: Bool) -> some View {
        let side = baseFont * 0.82
        return ZStack {
            Ink.Box(seed: seed)
                .stroke(color.opacity(done ? 0.45 : 0.7),
                        style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
            if done {
                Ink.Tick(seed: seed &+ 1)
                    .stroke(color.opacity(0.75),
                            style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                    .padding(-1.5)
            }
        }
        .frame(width: side, height: side)
        .offset(y: -baseFont * 0.06)
    }

    /// A stable jitter seed for this row's drawn marks. Derived from the block's
    /// own text so two rules in one answer wobble differently and the same rule
    /// wobbles identically on every redraw — `hashValue` would do neither, being
    /// re-salted per process.
    private var seed: Int {
        switch block {
        case .heading(_, let text), .bullet(let text, _), .ordered(_, let text, _),
             .task(_, let text, _), .quote(let text), .paragraph(let text), .math(let text):
            return text.utf8.reduce(17) { $0 &* 31 &+ Int($1) }
        case .code(_, let text):
            return text.utf8.prefix(64).reduce(17) { $0 &* 31 &+ Int($1) }
        case .table, .divider, .image, .pdf:
            return 11
        }
    }

    /// Bullet glyph by nesting depth — the standard •/◦/▪ ladder, so levels read
    /// apart even when the indent step is subtle on the narrow panel.
    private func bulletGlyph(for indent: Int) -> String {
        switch indent {
        case 0: return "•"
        case 1: return "◦"
        default: return "▪"
        }
    }
}

/// A GFM pipe table rendered as a `Grid`: the header row reads slightly bolder
/// and dimmer (a column label), a hairline rules off the header, and body rows
/// align in shared columns so cells line up no matter how the text wraps. Each
/// cell keeps its inline markdown (`**bold**`, `code`, …) via `InlineMarkdownText`.
/// The whole island is boxed by a faint hairline so it reads as one unit on the
/// glass rather than four loose columns of text.
private struct MarkdownTableView: View {
    let header: [String]
    let rows: [[String]]
    let baseFont: CGFloat
    let color: Color
    /// Cells follow the answer's voice — a table is still prose, just ruled.
    var hand: Bool = false

    private var columnCount: Int { header.count }

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                    cellText(cell, weight: .semibold, opacity: 0.85)
                }
            }
            .padding(.vertical, 6)

            Divider().overlay(Tokens.hairline).gridCellColumns(max(columnCount, 1))

            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        cellText(cell, weight: .regular, opacity: 1)
                    }
                }
                .padding(.vertical, 6)

                if index < rows.count - 1 {
                    Divider().overlay(Tokens.hairline.opacity(0.6))
                        .gridCellColumns(max(columnCount, 1))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Tokens.hairline, lineWidth: 0.5)
        )
    }

    private func cellText(_ raw: String, weight: Font.Weight, opacity: Double) -> some View {
        InlineMarkdownText(raw, linkColor: color.opacity(opacity),
                           hand: hand ? .init(size: baseFont - 1) : nil)
            .font(proseFont(baseFont - 1, weight: weight, hand: hand))
            .tracking(hand ? 0 : -0.05)
            .foregroundStyle(color.opacity(opacity))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }
}
