import SwiftUI
import AppKit
import Combine
import PDFKit
import ImageIO

/// Renders a parsed answer as stacked block-level markdown — headings and lists
/// laid out vertically, each line's inline markdown handled by
/// `InlineMarkdownText`. Caller controls the base font/colour; this only adds the
/// per-block structure (sizing for headings, the bullet/number gutter for lists).
struct MarkdownBlocks: View {
    let source: String
    var baseFont: CGFloat = 15
    var color: Color = Tokens.text1
    /// Called when a code block's copy button writes its text to the pasteboard,
    /// so the owner (NotchBody) can re-baseline the clipboard and stop that in-app
    /// copy from poisoning the next Ask's clipboard-context injection. `nil` in the
    /// (non-result) contexts that don't care.
    var onInAppCopy: (() -> Void)? = nil
    /// While the answer streams, the LAST block is the growing tail: its
    /// newly-revealed glyphs fade in (macOS 15+, see `StreamTailRenderer`).
    /// False everywhere else — settled answers and non-answer contexts render
    /// plain.
    var streamingTail: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Injected by the surfaces that carry the assistant's own voice (the panel
    /// thread, a detached thread). Everywhere else this stays false, so notes,
    /// previews and settings copy are never re-faced.
    @Environment(\.handwritten) private var handwritten

    // `parseCached`, not `parse`: this computed property re-runs on every body
    // evaluation, which during streaming happens for every ~33ms flush times
    // every mounted copy of the turn (visible thread, height probe, blur
    // overlays). The cache makes all but the first evaluation of a given
    // source free.
    private var blocks: [MarkdownBlock] { MarkdownParser.parseCached(source) }

    var body: some View {
        let parsed = blocks
        // Consecutive images fold into one `ImageExpandStack` (see
        // `markdownRenderItems`); every other block keeps its own row.
        let items = markdownRenderItems(parsed)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items) { item in
                switch item {
                case .gallery(_, let images):
                    ImageExpandStack(images: images)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .block(let i, let block):
                    // Per-block styling lives in `MarkdownBlockRow`, shared with the
                    // streaming renderer (`StreamingMarkdown`) so a settled answer and a
                    // live one are laid out identically — they differ only in the tail
                    // fade/selection wrapping, never in how a block kind looks.
                    // `.equatable()` — see the row's `Equatable` conformance for why.
                    MarkdownBlockRow(block: block, baseFont: baseFont, color: color,
                                     onInAppCopy: onInAppCopy,
                                     fadeTail: streamingTail && !reduceMotion && i == parsed.count - 1,
                                     hand: handwritten)
                        .equatable()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// The streaming face of `MarkdownBlocks`: same layout, but the live tail
/// **fades in** as chunks land instead of snapping. The result is a typewriter
/// feel — text appears to dissolve into
/// place rather than blink on in jumps.
///
/// Why only the tail: re-parsing the whole `source` every chunk and re-fading all
/// of it would make the entire (already-read) answer flicker on each token. So we
/// split the parsed blocks into the *settled head* (every block but the last) and
/// the *growing tail* (the final block). The head renders through the plain
/// `MarkdownBlocks` with no animation; the tail is keyed on its own text so that
/// each time it grows, SwiftUI re-runs an 80ms opacity ramp from `tailFloor` → 1
/// over just that block — the freshly-arrived words shimmer in, the rest holds.
///
/// Settles to nothing once streaming ends: the caller swaps back to a plain
/// `MarkdownBlocks` for the finished, fully-selectable answer (see `turnView`),
/// so none of this fade machinery touches a settled turn.
struct StreamingMarkdown: View {
    let source: String
    var baseFont: CGFloat = 15
    var color: Color = Tokens.text1
    var onInAppCopy: (() -> Void)? = nil

    @Environment(\.handwritten) private var handwritten

    private var blocks: [MarkdownBlock] { MarkdownParser.parseCached(source) }

    var body: some View {
        let parsed = blocks
        // Split on the grouped ITEMS, not the raw blocks: a growing run of images
        // is one gallery, and the tail has to be that whole gallery — splitting on
        // blocks would leave the newest image outside the pile it belongs to and
        // re-lay the answer out every time one landed.
        let items = markdownRenderItems(parsed)
        // The tail is the item currently growing; the head is everything already
        // settled above it. An empty source yields no blocks — the caller shows
        // ThinkingDots in that case, so we just render nothing here.
        let headCount = max(0, items.count - 1)
        return VStack(alignment: .leading, spacing: 8) {
            if headCount > 0 {
                // Settled blocks: render verbatim through the plain renderer so they
                // never re-fade as later chunks arrive. Rebuilt from the same
                // `source` prefix; cheap, and keeps inline/code handling identical.
                ForEach(items.prefix(headCount)) { item in
                    switch item {
                    case .gallery(_, let images):
                        ImageExpandStack(images: images)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    case .block(_, let block):
                        MarkdownBlockRow(block: block, baseFont: baseFont, color: color,
                                         onInAppCopy: onInAppCopy, hand: handwritten)
                            .equatable()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            if let tail = items.last {
                switch tail {
                case .gallery(_, let images):
                    ImageExpandStack(images: images)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .block(_, let block):
                    MarkdownBlockRow(block: block, baseFont: baseFont, color: color,
                                     onInAppCopy: onInAppCopy, hand: handwritten)
                        .equatable()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .modifier(TailFadeIn(token: tailToken(for: block)))
                }
            }
        }
    }

    /// A change-key for the tail's fade: re-ramps opacity whenever the tail's text
    /// grows. We key on the rendered character count (per block kind) rather than
    /// the whole `source` so head edits never re-trigger the tail's fade.
    private func tailToken(for block: MarkdownBlock) -> Int {
        switch block {
        case .heading(_, let t), .bullet(let t, _), .ordered(_, let t, _),
             .task(_, let t, _), .quote(let t), .paragraph(let t), .math(let t):
            return t.count
        case .code(_, let t):
            return t.count
        case .table(let header, let rows):
            // Grow as cells stream in: keys on total rendered character count so a
            // table still building its last row re-fades only as it changes.
            return header.reduce(0) { $0 + $1.count }
                + rows.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } }
        case .image(_, let url), .pdf(_, let url):
            return url.count
        case .divider:
            return -1
        }
    }
}

/// No-op. The tail block used to dim to a `floor` opacity and ease back to 1 on
/// every chunk (a typewriter-style fade), but with a long single-paragraph answer
/// the *whole* tail is one block, so the entire body below the first line dimmed
/// and re-lit on each token — read as the text going pale mid-answer and only
/// settling once the stream ended. Tail text now renders at full opacity like the
/// settled head; streaming just reflows line by line, no fade. Kept as a modifier
/// (rather than deleting the call site) so `StreamingMarkdown`'s head/tail split is
/// untouched and the fade can be reintroduced here if it's ever made
/// per-new-character instead of per-block.
private struct TailFadeIn: ViewModifier {
    let token: Int
    func body(content: Content) -> some View { content }
}
