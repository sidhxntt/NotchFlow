import SwiftUI
import AppKit
import Combine
import PDFKit
import ImageIO

// MARK: - Block-level markdown

/// One parsed block of an answer. We intentionally support only the block kinds
/// an in-notch assistant actually produces — headings, lists (nested via
/// `indent`, including GFM task items), block quotes, fenced code blocks,
/// GFM tables, and horizontal rules — plus plain paragraphs. Everything else
/// falls through to a paragraph, so unknown syntax still reads cleanly rather
/// than breaking. Inline `**bold**` / `*italic*` / `code` is handled per-line by
/// `InlineMarkdownText`; code blocks render verbatim without inline parsing.
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    /// `indent` is the nesting depth (0 = top level) of a list item, derived
    /// from the line's leading whitespace.
    case bullet(text: String, indent: Int)
    case ordered(number: Int, text: String, indent: Int)
    /// A GFM task item — `- [ ] text` / `- [x] text`.
    case task(done: Bool, text: String, indent: Int)
    /// A `>` block quote. Contiguous quoted lines collapse into one block;
    /// `text` keeps their newlines so the quote reads as a single island.
    case quote(text: String)
    case paragraph(text: String)
    case code(language: String?, text: String)
    /// A GitHub-flavoured pipe table. `header` is the first row; `rows` are the
    /// body rows below the `|---|` separator. Every row is normalised to
    /// `header.count` cells (short rows padded, long rows truncated) so the grid
    /// is always rectangular. Cell text keeps its inline markdown.
    case table(header: [String], rows: [[String]])
    /// A display-math island — `$$…$$` / `\[…\]` opening its own line, or a
    /// ```math fence. `text` is the raw LaTeX between the delimiters; rendering
    /// converts it to Unicode via `MathTypeset` (a glyph translation, not a
    /// math engine, in keeping with the no-library rule).
    case math(text: String)
    /// A `![alt](url)` reference lifted out of its line — rendered as an inline
    /// image island, downloaded on first sight (http/https only; see
    /// `AnswerMediaLoader`).
    case image(alt: String, url: String)
    /// A reference to a `.pdf` URL — either image syntax or a `[label](….pdf)`
    /// link standing alone on its line. Rendered as a first-page preview island
    /// via PDFKit; tapping opens the document.
    case pdf(title: String, url: String)
    case divider
}

/// A line-based markdown parser. Deliberately tiny: it walks the answer line by
/// line and classifies each non-empty line as a heading (`#`…`######`), an
/// unordered item (`-`, `*`, `+`, with `- [ ]`/`- [x]` task variants), an
/// ordered item (`1.`, `2)`), a block-quote line (`>`), a horizontal rule
/// (`---` / `***` / `___`), or a paragraph. List items keep a nesting depth
/// derived from their leading whitespace; contiguous `>` lines merge into one
/// quote block. Fenced code blocks (``` `…` ```) span multiple lines and capture
/// their content verbatim — including blank lines — until the closing fence.
/// No nesting beyond that, in keeping with the app's minimalism (no markdown
/// library).
enum MarkdownParser {
    /// Memoized `parse`. A streaming answer's growing source is rendered by
    /// several sibling copies of the same turn at once — the visible thread,
    /// NotchBody's hidden height probe, the progressive-blur overlay copies —
    /// and SwiftUI can re-evaluate each body more than once per update; every
    /// evaluation used to re-run the full line-by-line parse of the whole
    /// accumulated answer. One cache entry per distinct source collapses all
    /// of that to a single parse. NSCache is thread-safe and purges under
    /// memory pressure; the count limit bounds the streaming case, where each
    /// ~33ms flush is a new (one chunk longer) key that's never seen again.
    ///
    /// The limit has to clear a whole *record*, not just one answer: a reopened
    /// agent run stacks a separate source per narration entry per round, and at
    /// 32 a long transcript evicted its own earlier blocks before the sibling
    /// copies (blur overlay, a second body pass) could hit them — so every copy
    /// re-parsed from scratch. 256 covers the longest trail we cap at.
    private static let parseCache: NSCache<NSString, ParsedBlocks> = {
        let cache = NSCache<NSString, ParsedBlocks>()
        cache.countLimit = 256
        return cache
    }()

    /// NSCache values must be objects; a one-field box over the parsed blocks.
    private final class ParsedBlocks {
        let blocks: [MarkdownBlock]
        init(_ blocks: [MarkdownBlock]) { self.blocks = blocks }
    }

    static func parseCached(_ source: String) -> [MarkdownBlock] {
        let key = source as NSString
        if let hit = parseCache.object(forKey: key) { return hit.blocks }
        let blocks = parse(source)
        parseCache.setObject(ParsedBlocks(blocks), forKey: key)
        return blocks
    }

    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = source.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let rawLine = lines[i]
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // Fenced code block — capture everything (including blank lines)
            // until the matching closing fence. The opening fence may carry a
            // language hint (e.g. ```swift); we keep it but don't syntax-color.
            if let lang = codeFence(line) {
                var body: [String] = []
                i += 1
                while i < lines.count {
                    let inner = lines[i]
                    if codeFence(inner.trimmingCharacters(in: .whitespaces)) != nil { break }
                    body.append(inner)
                    i += 1
                }
                // A ```math fence (GitHub's display-math fence) is math, not
                // code — everything else stays a verbatim code island (```latex
                // included: that's usually code the user wants to copy).
                if lang.lowercased() == "math" {
                    blocks.append(.math(text: body.joined(separator: "\n")))
                } else {
                    blocks.append(.code(language: lang.isEmpty ? nil : lang, text: body.joined(separator: "\n")))
                }
                i += 1
                continue
            }

            if line.isEmpty {
                i += 1
                continue
            }

            // Display math — `$$ … $$` or `\[ … \]` opening its own line. The
            // block may close on the same line or span several; an unclosed one
            // swallows the rest (mirroring code fences), so a streaming answer
            // renders its partial formula instead of raw TeX.
            if line.hasPrefix("$$") || line.hasPrefix("\\[") {
                let close = line.hasPrefix("$$") ? "$$" : "\\]"
                let rest = String(line.dropFirst(2))
                if let r = rest.range(of: close) {
                    blocks.append(.math(text: String(rest[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)))
                    // Trailing prose after the closer keeps its own paragraph.
                    let after = String(rest[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if !after.isEmpty { blocks.append(.paragraph(text: after)) }
                    i += 1
                    continue
                }
                var body: [String] = rest.trimmingCharacters(in: .whitespaces).isEmpty ? [] : [rest]
                i += 1
                while i < lines.count {
                    let inner = lines[i]
                    if let r = inner.range(of: close) {
                        let before = String(inner[..<r.lowerBound])
                        if !before.trimmingCharacters(in: .whitespaces).isEmpty { body.append(before) }
                        i += 1
                        break
                    }
                    body.append(inner)
                    i += 1
                }
                blocks.append(.math(text: body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
                continue
            }

            // Block quote — merge every contiguous `>` line into one block so a
            // multi-line quote renders as a single island (a bare `>` spacer
            // becomes a blank line inside it). Checked before table detection so
            // a quoted `|` line can't be mistaken for a table header.
            if line.hasPrefix(">") {
                var quoteLines: [String] = []
                while i < lines.count {
                    let inner = lines[i].trimmingCharacters(in: .whitespaces)
                    guard inner.hasPrefix(">") else { break }
                    quoteLines.append(quoteContent(inner))
                    i += 1
                }
                while quoteLines.first?.isEmpty == true { quoteLines.removeFirst() }
                while quoteLines.last?.isEmpty == true { quoteLines.removeLast() }
                if !quoteLines.isEmpty {
                    blocks.append(.quote(text: quoteLines.joined(separator: "\n")))
                }
                continue
            }

            // GFM pipe table: the current line plus a following `|---|:--:|`
            // separator. Detect it before the divider/heading checks so a header
            // row isn't mistaken for a paragraph and the `---` separator isn't
            // mistaken for a horizontal rule. Consumes the header, the separator,
            // and every contiguous body row.
            if i + 1 < lines.count,
               isTableSeparator(lines[i + 1].trimmingCharacters(in: .whitespaces)),
               line.contains("|") {
                let header = tableCells(line)
                var rows: [[String]] = []
                i += 2   // skip the header (handled) and the separator line
                while i < lines.count {
                    let bodyRaw = lines[i].trimmingCharacters(in: .whitespaces)
                    guard !bodyRaw.isEmpty, bodyRaw.contains("|") else { break }
                    // Normalise each body row to the header's column count.
                    var cells = tableCells(bodyRaw)
                    if cells.count < header.count {
                        cells.append(contentsOf: Array(repeating: "", count: header.count - cells.count))
                    } else if cells.count > header.count {
                        cells = Array(cells.prefix(header.count))
                    }
                    rows.append(cells)
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            if isDivider(line) {
                blocks.append(.divider)
            } else if let (level, text) = heading(line) {
                blocks.append(.heading(level: level, text: text))
            } else if let text = bullet(line) {
                let indent = listIndent(of: rawLine)
                if let (done, rest) = taskItem(text) {
                    blocks.append(.task(done: done, text: rest, indent: indent))
                } else {
                    blocks.append(.bullet(text: text, indent: indent))
                }
            } else if let (number, text) = ordered(line) {
                blocks.append(.ordered(number: number, text: text, indent: listIndent(of: rawLine)))
            } else {
                blocks.append(contentsOf: paragraphOrMedia(line))
            }
            i += 1
        }
        return blocks
    }

    /// `` ``` `` or `` ```swift `` → optional language tag (empty string if bare).
    /// Returns `nil` for any line that isn't a fence opener/closer, so the caller
    /// can use it for both opening and closing detection.
    private static func codeFence(_ line: String) -> String? {
        guard line.hasPrefix("```") else { return nil }
        let after = line.dropFirst(3)
        // Disallow extra backticks on the same line — that's an inline `code`
        // span gone weird, not a fence.
        if after.contains("`") { return nil }
        return String(after).trimmingCharacters(in: .whitespaces)
    }

    /// `---` / `***` / `___` (3+ of the same char, optional internal spaces).
    /// Conservative: requires the line to be made up of only that marker (after
    /// stripping spaces) so a real `***bold***` paragraph isn't swallowed.
    private static func isDivider(_ line: String) -> Bool {
        let stripped = line.filter { $0 != " " }
        guard stripped.count >= 3, let first = stripped.first else { return false }
        guard first == "-" || first == "*" || first == "_" else { return false }
        return stripped.allSatisfy { $0 == first }
    }

    /// `# Title` … `###### Title` → (level, text). Requires a space after the
    /// hashes so a bare `#tag` stays a paragraph.
    private static func heading(_ line: String) -> (Int, String)? {
        var level = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == "#", level < 6 {
            level += 1
            idx = line.index(after: idx)
        }
        guard level > 0, idx < line.endIndex, line[idx] == " " else { return nil }
        let text = String(line[idx...]).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (level, text)
    }

    /// `- item` / `* item` / `+ item` → text. The marker must be followed by a
    /// space, so a stray `*emphasis*` at line start isn't mistaken for a bullet.
    private static func bullet(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// `[ ] buy milk` / `[x] done thing` (the text of an already-matched bullet)
    /// → (done, rest). The space after the bracket is required, so `[link]`-style
    /// text at the start of a bullet isn't mistaken for a checkbox.
    private static func taskItem(_ text: String) -> (Bool, String)? {
        for (marker, done) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where text.hasPrefix(marker) {
            let rest = String(text.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { return (done, rest) }
        }
        return nil
    }

    /// Nesting depth of a list line from its leading whitespace (tab = 4 cols).
    /// Both common LLM conventions land on the same depth: 2 *or* 4 columns →
    /// level 1, 6 or 8 → level 2, … Capped so runaway indentation can't push
    /// text off the narrow panel.
    private static func listIndent(of rawLine: String) -> Int {
        var width = 0
        for ch in rawLine {
            if ch == " " { width += 1 }
            else if ch == "\t" { width += 4 }
            else { break }
        }
        return width < 2 ? 0 : min(1 + (width - 2) / 4, 4)
    }

    /// Strip the `>` marker(s) — plus the conventional space after each — from a
    /// quoted line. Nested `> >` quotes flatten into the same block.
    private static func quoteContent(_ line: String) -> String {
        var content = Substring(line)
        while content.hasPrefix(">") {
            content = content.dropFirst()
            if content.hasPrefix(" ") { content = content.dropFirst() }
        }
        return String(content)
    }

    /// A GFM table separator row: `|---|---|`, `| :--- | ---: |`, `--- | ---`,
    /// etc. Every cell must be made of only `-`, `:`, and spaces, with at least
    /// one `-`, and there must be at least one cell. Used to confirm the line
    /// *above* is a table header before we commit to table parsing.
    private static func isTableSeparator(_ line: String) -> Bool {
        guard line.contains("-") else { return false }
        let cells = tableCells(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" } && cell.contains("-")
        }
    }

    /// Split a pipe-table row into trimmed cell strings. Tolerates an optional
    /// leading/trailing `|` (so both `| a | b |` and `a | b` work) and ignores a
    /// pipe escaped as `\|` inside a cell.
    private static func tableCells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }

        var cells: [String] = []
        var current = ""
        var escaped = false
        for ch in trimmed {
            if escaped {
                current.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    // MARK: - Media references

    /// `![alt](url)` — the alt text, then the URL (an optional `"title"` after
    /// the URL is tolerated and dropped).
    private static let imageRef = #/!\[([^\]]*)\]\(\s*(\S+?)(?:\s+"[^"]*")?\s*\)/#
    /// A `[label](url)` link standing alone on its line.
    private static let soloLink = #/^\[([^\]]+)\]\(\s*(\S+?)(?:\s+"[^"]*")?\s*\)$/#

    /// A bare http(s) URL standing alone on its line.
    private static let soloURL = #/^<?(https?://\S+?)>?$/#

    /// Turn one paragraph-shaped line into blocks, lifting media out of it:
    /// every `![alt](url)` becomes its own `.image` (or `.pdf` when the URL is
    /// a PDF) below the line's remaining text, and a lone `[label](url)` link —
    /// or a lone bare URL — pointing at an image or a PDF becomes that island
    /// too. Anything else stays one paragraph. Lifting is per-line only — images
    /// inside lists/quotes/tables keep their textual form.
    ///
    /// The link/bare-URL cases exist because models reach for a link far more
    /// readily than for `![]()` syntax: a line whose whole content is an image
    /// URL *is* the image, and showing it as a clickable string instead of the
    /// picture is never what the user wanted.
    private static func paragraphOrMedia(_ line: String) -> [MarkdownBlock] {
        // A line that is nothing but an image/PDF URL renders as the thing itself.
        if let m = line.wholeMatch(of: soloURL) {
            let url = String(m.1)
            if isPDFURL(url) { return [.pdf(title: "", url: url)] }
            if isImageURL(url) { return [.image(alt: "", url: url)] }
        }

        // The cheap gate: no `](` means no reference of either kind.
        guard line.contains("](") else { return [.paragraph(text: line)] }

        if let m = line.wholeMatch(of: soloLink) {
            let url = String(m.2)
            if isPDFURL(url) { return [.pdf(title: String(m.1), url: url)] }
            // A link whose target is an image file: render the image, keeping the
            // label as its alt text so the fallback chip still reads sensibly.
            if isImageURL(url) { return [.image(alt: String(m.1), url: url)] }
        }

        var text = line
        var media: [MarkdownBlock] = []
        while let m = text.firstMatch(of: imageRef) {
            let alt = String(m.1), url = String(m.2)
            media.append(isPDFURL(url) ? .pdf(title: alt, url: url) : .image(alt: alt, url: url))
            text.removeSubrange(m.range)
        }
        guard !media.isEmpty else { return [.paragraph(text: line)] }
        let rest = text.trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? media : [.paragraph(text: rest)] + media
    }

    /// Does the URL's path (query/fragment ignored) end in `.pdf`?
    private static func isPDFURL(_ urlString: String) -> Bool {
        let path = urlString.split(separator: "?", maxSplits: 1)[0]
            .split(separator: "#", maxSplits: 1)[0]
        return path.lowercased().hasSuffix(".pdf")
    }

    /// Image file types `AnswerMediaLoader` can actually decode through ImageIO.
    /// Deliberately extension-based and conservative: SVG is absent because
    /// ImageIO can't decode it, and an extension-less URL stays a link rather
    /// than becoming a loading island that may never resolve to a picture.
    private static let imageExtensions = ["png", "jpg", "jpeg", "gif", "webp",
                                          "heic", "heif", "bmp", "tif", "tiff", "avif"]

    /// Does the URL's path (query/fragment ignored) end in an image extension?
    private static func isImageURL(_ urlString: String) -> Bool {
        let path = urlString.split(separator: "?", maxSplits: 1)[0]
            .split(separator: "#", maxSplits: 1)[0]
            .lowercased()
        return imageExtensions.contains { path.hasSuffix("." + $0) }
    }

    /// `1. item` / `2) item` → (number, text).
    private static func ordered(_ line: String) -> (Int, String)? {
        var digits = ""
        var idx = line.startIndex
        while idx < line.endIndex, line[idx].isNumber {
            digits.append(line[idx])
            idx = line.index(after: idx)
        }
        guard !digits.isEmpty, let number = Int(digits), idx < line.endIndex else { return nil }
        let sep = line[idx]
        guard sep == "." || sep == ")" else { return nil }
        let afterSep = line.index(after: idx)
        guard afterSep < line.endIndex, line[afterSep] == " " else { return nil }
        let text = String(line[afterSep...]).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (number, text)
    }

    // MARK: - Plain-text flattening

    /// Flatten an answer's markdown into clean plain text — the "copy without
    /// formatting" path. Reuses `parse` so every block kind we render is handled,
    /// then drops the structural syntax: heading hashes, list markers, block-quote
    /// `>`, code fences, table pipes. Inline `**bold**` / `*italic*` / `` `code` ``
    /// / `[label](url)` is stripped per line via `stripInline`. Blocks are joined
    /// with blank lines so paragraphs still read as paragraphs.
    static func plainText(_ source: String) -> String {
        var out: [String] = []
        for block in parse(source) {
            switch block {
            case let .heading(_, text):
                out.append(stripInline(text))
            case let .bullet(text, indent):
                out.append(indentPad(indent) + "• " + stripInline(text))
            case let .ordered(number, text, indent):
                out.append(indentPad(indent) + "\(number). " + stripInline(text))
            case let .task(done, text, indent):
                out.append(indentPad(indent) + (done ? "[x] " : "[ ] ") + stripInline(text))
            case let .quote(text):
                // Keep the quote's own line breaks; strip inline markup per line.
                let lines = text.components(separatedBy: "\n").map { stripInline($0) }
                out.append(lines.joined(separator: "\n"))
            case let .paragraph(text):
                out.append(stripInline(text))
            case let .code(_, text):
                // Code is verbatim — no inline stripping (a `*` in code is a `*`).
                out.append(text)
            case let .table(header, rows):
                // Render as tab-separated rows so columns survive a paste into a
                // plain-text field or spreadsheet.
                var lines = [header.map { stripInline($0) }.joined(separator: "\t")]
                for row in rows {
                    lines.append(row.map { stripInline($0) }.joined(separator: "\t"))
                }
                out.append(lines.joined(separator: "\n"))
            case let .math(text):
                // Copy the formula the way it renders — Unicode, not raw TeX.
                out.append(MathTypeset.unicode(text))
            case let .image(alt, url):
                out.append(alt.isEmpty ? url : "\(alt): \(url)")
            case let .pdf(title, url):
                out.append(title.isEmpty ? url : "\(title): \(url)")
            case .divider:
                // A rule carries no text; drop it (the blank-line join keeps the
                // visual break between the blocks it separated).
                break
            }
        }
        return out.joined(separator: "\n\n")
    }

    private static func indentPad(_ indent: Int) -> String {
        String(repeating: "  ", count: max(0, indent))
    }

    /// Escape lone `~` so cmark can't read a pair of them as strikethrough.
    ///
    /// GFM treats `~text~` as a strike, so an answer like `8~12°C / -2~2°C`
    /// loses both tildes and comes back struck through. Runs of two or more tildes are left alone (real
    /// `~~strikethrough~~` still works), as is anything inside a code span, where
    /// a backslash would print literally rather than escape.
    static func escapingLoneTildes(_ line: String) -> String {
        guard line.contains("~") else { return line }
        let chars = Array(line)
        var out = ""
        var i = 0
        while i < chars.count {
            switch chars[i] {
            case "\\":
                // An existing escape covers the next character; copy both.
                out.append(chars[i])
                if i + 1 < chars.count { out.append(chars[i + 1]) }
                i += 2
            case "`":
                // A backtick run opens a code span closed by a run of the same
                // length. Copy the whole span verbatim; an unclosed run is just text.
                let open = i
                while i < chars.count, chars[i] == "`" { i += 1 }
                let fence = i - open
                out.append(contentsOf: chars[open..<i])
                var j = i
                while j < chars.count {
                    guard chars[j] == "`" else { j += 1; continue }
                    let start = j
                    while j < chars.count, chars[j] == "`" { j += 1 }
                    if j - start == fence {
                        out.append(contentsOf: chars[i..<j])
                        i = j
                        break
                    }
                }
            case "~":
                let start = i
                while i < chars.count, chars[i] == "~" { i += 1 }
                if i - start == 1 { out.append("\\") }
                out.append(contentsOf: chars[start..<i])
            default:
                out.append(chars[i])
                i += 1
            }
        }
        return out
    }

    /// Strip inline markdown (`**bold**`, `*italic*`, `` `code` ``, `[label](url)`)
    /// from one line, leaving the visible text. Uses the same SwiftUI markdown
    /// parser as `InlineMarkdownText` so the two stay consistent; falls back to the
    /// raw line if parsing fails.
    private static func stripInline(_ line: String) -> String {
        // Inline math first, same as the visible renderer, so a copied line
        // reads `x²`, not `$x^2$`.
        let source = escapingLoneTildes(MathTypeset.inline(line))
        if let parsed = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return String(parsed.characters)
        }
        return source
    }
}
