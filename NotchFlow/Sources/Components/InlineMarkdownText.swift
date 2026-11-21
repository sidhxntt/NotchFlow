import SwiftUI
import AppKit
import Combine
import PDFKit
import ImageIO

/// Renders inline `**bold**` markdown into styled text — the same lightweight
/// transform the prototype applied to AI answers.
struct InlineMarkdownText: View {
    let raw: String
    /// Colour for surviving links. Defaults to primary ink so links read in the
    /// same white family as the body text — on our dark glass the stock system
    /// blue is both illegible and off-palette, so links are styled as ink +
    /// underline (the underline, not a colour shift, is what marks them tappable).
    var linkColor: Color = Tokens.text1
    /// Set only in handwriting mode, to the enclosing block's type size.
    ///
    /// Emphasis normally needs no help: SwiftUI reads `**bold**`/`*italic*`/
    /// `code` off the parsed intents and promotes the environment font by trait.
    /// That promotion silently fails on the handwriting face — it is pinned to
    /// explicit variation coordinates, so asking it for a bold trait hands back
    /// the same regular instance and every emphasis in the answer flattens into
    /// body text. So in that mode each emphasised run gets an explicit font
    /// instead (see `Handwriting`), which is what this carries the size for.
    var hand: HandEmphasis? = nil

    /// What a handwritten line needs to resolve its own emphasis faces.
    struct HandEmphasis: Equatable {
        /// Nominal prose size, for picking emphasis faces.
        let size: CGFloat
    }

    init(_ raw: String, linkColor: Color = Tokens.text1, hand: HandEmphasis? = nil) {
        self.raw = raw
        self.linkColor = linkColor
        self.hand = hand
    }

    var body: some View {
        Text(attributed)
    }

    /// The emphasis kinds worth re-facing by hand. Ordinary body text is `.plain`
    /// — in the printed voice it inherits the block's `.font` modifier as it
    /// always has, and in the hand it still needs a face of its own.
    private enum Emphasis: Equatable {
        case plain, bold, italic, boldItalic, code
    }

    /// One stretch of a line that wants a single handwriting emphasis face.
    private struct Face: Equatable {
        let emphasis: Emphasis
    }

    /// One line's parsed text, minus the caller's colour — the cacheable half.
    /// `spans` are the surviving links as (character offset, length) pairs rather
    /// than `AttributedString.Index` ranges, so they stay valid when re-applied to
    /// a copy that's being mutated. `faces` records the font runs the same way,
    /// for the same reason.
    private final class Parsed {
        let text: AttributedString
        let spans: [(offset: Int, length: Int)]
        let faces: [(offset: Int, length: Int, face: Face)]
        init(text: AttributedString,
             spans: [(offset: Int, length: Int)],
             faces: [(offset: Int, length: Int, face: Face)]) {
            self.text = text
            self.spans = spans
            self.faces = faces
        }
    }

    /// Split a parsed line into runs that each want one font: walk it character by
    /// character, tag every character with (emphasis, script), then coalesce.
    ///
    /// Done once per distinct line and cached with the parse — the per-render path
    /// only ever reads the result. A line with no CJK and no emphasis coalesces to
    /// a single `.plain` run, which the renderer then skips entirely.
    private static func faceRuns(of text: AttributedString)
        -> [(offset: Int, length: Int, face: Face)] {
        var out: [(offset: Int, length: Int, face: Face)] = []
        var offset = 0
        for run in text.runs {
            let emphasis: Emphasis
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    emphasis = .code
                } else {
                    switch (intent.contains(.stronglyEmphasized), intent.contains(.emphasized)) {
                    case (true, true):  emphasis = .boldItalic
                    case (true, false): emphasis = .bold
                    case (false, true): emphasis = .italic
                    default:            emphasis = .plain
                    }
                }
            } else {
                emphasis = .plain
            }
            for character in text[run.range].characters {
                let face = Face(emphasis: emphasis)
                if var last = out.last, last.face == face {
                    last.length += 1
                    out[out.count - 1] = last
                } else {
                    out.append((offset: offset, length: 1, face: face))
                }
                offset += 1
            }
        }
        return out
    }

    /// Memoized inline parse, keyed on the raw line. Every line of an answer runs
    /// `AttributedString(markdown:)` (a full cmark parse) plus an `NSDataDetector`
    /// sweep for bare URLs — and the same line is parsed by every mounted copy of
    /// the turn: the visible thread, the progressive-blur overlay copy, and again
    /// on every reopen of the same record from Recent. On a long agent transcript
    /// that was hundreds of parses on the main thread per open. One entry per
    /// distinct line collapses all of them to the first. Colour is applied after
    /// the lookup, so the same cached line serves every call site's `linkColor`.
    private static let parseCache: NSCache<NSString, Parsed> = {
        let cache = NSCache<NSString, Parsed>()
        cache.countLimit = 512
        return cache
    }()

    private static func parsed(_ raw: String) -> Parsed {
        let key = raw as NSString
        if let hit = parseCache.object(forKey: key) { return hit }

        // Inline `$…$` / `\(…\)` math converts to Unicode glyphs BEFORE the
        // markdown parse — by the time SwiftUI reads the line, `x^2` is already
        // `x²` and any character surviving conversion that markdown would
        // reinterpret (`*`, `_`, …) is escaped.
        let source = MarkdownParser.escapingLoneTildes(MathTypeset.inline(raw))
        var text: AttributedString
        // SwiftUI's built-in inline-markdown parsing covers **bold**, *italic*,
        // and `code` — exactly the subset we need.
        if var parsed = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            // The markdown parser also turns `[label](url)` into a tappable link.
            // The answer text comes from an LLM endpoint we don't fully trust, so a
            // rogue/compromised backend could embed `[ok](file:///…)` or a custom
            // scheme that fires on click. Allow only http/https — real web links the
            // user can open — and strip every other `.link` run (keep its styling,
            // drop the clickable URL), so file:// and custom schemes stay inert.
            let links = parsed.runs.compactMap { $0.link == nil ? nil : $0.range }
            for range in links {
                let scheme = parsed[range].link?.scheme?.lowercased()
                if scheme != "http" && scheme != "https" {
                    parsed[range].link = nil
                }
            }
            autolink(&parsed)
            text = parsed
        } else {
            var plain = AttributedString(source)
            autolink(&plain)
            text = plain
        }

        // Surviving links, as offsets — the caller paints them (see `attributed`).
        let chars = text.characters
        let spans = text.runs.compactMap { run -> (offset: Int, length: Int)? in
            guard run.link != nil else { return nil }
            return (offset: chars.distance(from: text.startIndex, to: run.range.lowerBound),
                    length: chars.distance(from: run.range.lowerBound, to: run.range.upperBound))
        }

        let result = Parsed(text: text, spans: spans, faces: Self.faceRuns(of: text))
        parseCache.setObject(result, forKey: key)
        return result
    }

    private var attributed: AttributedString {
        // In the hand, the line arrives already faced — one cached pass, not one
        // per frame (see `handFaced`). In the printed voice it's the raw parse.
        let hit = Self.parsed(raw)
        let base = hand.map { Self.handFaced(raw, size: $0.size) } ?? hit.text
        let links = hit.spans
        // The overwhelmingly common case: no links, so the cached line is already
        // finished and nothing is copied or mutated.
        guard !links.isEmpty else { return base }
        // Links get our ink colour + an underline instead of the stock blue, which
        // is illegible on the dark glass. Offsets are recomputed against the copy
        // each time: setting attributes never changes the character count, so they
        // stay exact across the loop's own mutations.
        var out = base
        for span in links {
            let start = out.index(out.startIndex, offsetByCharacters: span.offset)
            let end = out.index(start, offsetByCharacters: span.length)
            out[start..<end].foregroundColor = linkColor
            out[start..<end].underlineStyle = .single
        }
        return out
    }

    /// A line with every run's handwriting face already applied, memoized per
    /// (line, size).
    ///
    /// This has to be cached, not computed per render. Walking the runs costs an
    /// `offsetByCharacters` seek per run, so facing a line is O(runs × length) —
    /// and a streaming answer re-renders every ~33ms across several mounted copies
    /// of the same turn. Doing it live would put that whole product on the main
    /// thread at flush rate, for text that never changes once written. The set of
    /// sizes in play is a handful (body plus the heading ladder), so keys stay
    /// bounded the same way `parseCache`'s do.
    private static let handCache: NSCache<NSString, HandFaced> = {
        let cache = NSCache<NSString, HandFaced>()
        cache.countLimit = 512
        return cache
    }()

    private final class HandFaced {
        let text: AttributedString
        init(_ text: AttributedString) { self.text = text }
    }

    private static func handFaced(_ raw: String, size: CGFloat) -> AttributedString {
        // Tenths of a point is finer than any size the answer renderer asks for,
        // and keeps the key a short string rather than a float's full precision.
        let key = "\(Int((size * 10).rounded()))|\(raw)" as NSString
        if let hit = handCache.object(forKey: key) { return hit.text }

        let parsed = Self.parsed(raw)
        var out = parsed.text
        for run in parsed.faces {
            let start = out.index(out.startIndex, offsetByCharacters: run.offset)
            let end = out.index(start, offsetByCharacters: run.length)
            out[start..<end].font = handFont(run.face, size: size)
        }
        handCache.setObject(HandFaced(out), forKey: key)
        return out
    }

    /// The concrete face for one run of a handwritten line.
    ///
    /// Inline code stays monospaced — a backticked identifier is machine text even
    /// when the sentence around it is a hand — and so keeps the base size, since
    /// SF Mono needs no correction.
    private static func handFont(_ face: Face, size: CGFloat) -> Font {
        guard face.emphasis != .code else { return Handwriting.codeFont(size) }
        let hand = Handwriting.font
        switch face.emphasis {
        case .bold:       return hand(size, .bold, false)
        case .italic:     return hand(size, .regular, true)
        case .boldItalic: return hand(size, .bold, true)
        default:          return hand(size, .regular, false)
        }
    }

    private static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Link the bare URLs the model writes as plain prose — a translated line
    /// ending in `meta.com/thefutureisfor` carries no markdown, so without this
    /// it renders as dead text. Same scheme gate as `[label](url)`: only
    /// http/https survive, so `mailto:` and friends stay inert.
    ///
    /// Marks the `.link` only — colour and underline are painted by `attributed`
    /// after the cache lookup, so one cached parse serves every `linkColor`.
    private static func autolink(_ attributed: inout AttributedString) {
        guard let detector = Self.linkDetector else { return }
        let plain = String(attributed.characters)
        guard !plain.isEmpty else { return }
        let full = NSRange(plain.startIndex..<plain.endIndex, in: plain)
        for match in detector.matches(in: plain, options: [], range: full) {
            guard let url = match.url,
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let found = Range(match.range, in: plain)
            else { continue }
            let offset = plain.distance(from: plain.startIndex, to: found.lowerBound)
            let length = plain.distance(from: found.lowerBound, to: found.upperBound)
            let start = attributed.index(attributed.startIndex, offsetByCharacters: offset)
            let end = attributed.index(start, offsetByCharacters: length)
            let range = start..<end
            // Leave alone anything the markdown pass already claimed — an
            // explicit `[label](url)` link, or a `code` span (a URL inside
            // backticks is being shown, not offered).
            let claimed = attributed[range].runs.contains {
                $0.link != nil || $0.inlinePresentationIntent?.contains(.code) == true
            }
            guard !claimed else { continue }
            attributed[range].link = url
        }
    }
}
