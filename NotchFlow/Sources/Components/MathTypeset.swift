import SwiftUI
import AppKit
import Combine
import PDFKit
import ImageIO

// MARK: - LaTeX math → Unicode

/// Turns the LaTeX math LLM answers embed — inline `$…$` / `\(…\)` spans and
/// display `$$…$$` / `\[…\]` blocks — into plain Unicode: `x^2` → `x²`,
/// `\alpha` → `α`, `\frac{a}{b}` → `a/b`, `\sqrt{2}` → `√2`. A glyph
/// translation, not a math engine: no library, no webview, in keeping with the
/// app's minimalism. The long tail of TeX (matrices, over-braces, …) degrades
/// to readable text — an unknown `\command` renders as its bare name — instead
/// of showing raw markup.
enum MathTypeset {
    // MARK: Inline span scanning

    /// Replace every inline math span in one line of markdown with its Unicode
    /// rendering, leaving the rest untouched. `\(…\)` and `$$…$$` are
    /// unambiguous and always convert; `$…$` needs a math "tell" (see `isMath`)
    /// so money — "$5 and $10" — is never eaten. The replacement has its
    /// markdown specials escaped, so a `*` that survives conversion can't turn
    /// the rest of the line italic when SwiftUI parses it.
    static func inline(_ line: String) -> String {
        guard line.contains("$") || line.contains("\\(") else { return line }
        let chars = Array(line)
        var out = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                if chars[i + 1] == "(", let close = find(chars, "\\)", from: i + 2) {
                    out += escaped(unicode(String(chars[(i + 2)..<close])))
                    i = close + 2
                    continue
                }
                // Any other escape (incl. `\$`) passes through untouched, so
                // the dollar scan below can't take an escaped `$` as a delimiter.
                out.append(c)
                out.append(chars[i + 1])
                i += 2
                continue
            }
            if c == "$" {
                if i + 1 < chars.count, chars[i + 1] == "$",
                   let close = find(chars, "$$", from: i + 2) {
                    out += escaped(unicode(String(chars[(i + 2)..<close])))
                    i = close + 2
                    continue
                }
                if let close = chars[(i + 1)...].firstIndex(of: "$"),
                   isMath(String(chars[(i + 1)..<close])) {
                    out += escaped(unicode(String(chars[(i + 1)..<close])))
                    i = close + 1
                    continue
                }
            }
            out.append(c)
            i += 1
        }
        return out
    }

    /// The `$…$` ambiguity gate: convert only when the span reads as math, not
    /// money or prose. A command / script / equals sign is a sure tell; failing
    /// that, a single space-free non-digit-led token (`$x$`, `$a+b$`) passes,
    /// while "5 and $10" (edge whitespace) and "100-" (digit-led, the span
    /// between two prices) stay literal text.
    private static func isMath(_ body: String) -> Bool {
        guard let first = body.first, let last = body.last,
              !first.isWhitespace, !last.isWhitespace, !body.contains("\n")
        else { return false }
        if body.contains(where: { "\\^_=".contains($0) }) { return true }
        return !body.contains(" ") && !first.isNumber
    }

    /// Index of the first occurrence of a two-character delimiter at/after
    /// `from`, or nil.
    private static func find(_ chars: [Character], _ delim: String, from: Int) -> Int? {
        let d = Array(delim)
        var i = from
        while i + d.count <= chars.count {
            if chars[i] == d[0], chars[i + 1] == d[1] { return i }
            i += 1
        }
        return nil
    }

    /// Escape the markdown-special characters a converted span may still carry
    /// so the math text survives `AttributedString(markdown:)` verbatim.
    private static func escaped(_ s: String) -> String {
        var out = ""
        for ch in s {
            if "\\*_`[]".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    // MARK: Expression conversion

    /// Convert one LaTeX math expression to a Unicode string.
    static func unicode(_ latex: String) -> String {
        let chars = Array(latex)
        var i = 0
        return squeeze(convert(chars, &i, until: nil))
    }

    /// The recursive walk. `until` is the group-closing brace this level stops
    /// (and consumes) at — nil at top level. Nested `{…}` groups recurse, so an
    /// inner brace never terminates an outer level early.
    private static func convert(_ chars: [Character], _ i: inout Int, until stop: Character?) -> String {
        var out = ""
        while i < chars.count {
            let c = chars[i]
            if let stop, c == stop {
                i += 1
                return out
            }
            switch c {
            case "\\":
                i += 1
                out += command(chars, &i)
            case "^":
                i += 1
                out += scripted(argument(chars, &i), with: Self.superscripts, marker: "^")
            case "_":
                i += 1
                out += scripted(argument(chars, &i), with: Self.subscripts, marker: "_")
            case "{":
                i += 1
                out += convert(chars, &i, until: "}")
            case "}":
                i += 1   // unbalanced closer — drop it
            case "&", "~":
                out += " "   // alignment tab / non-breaking tie → plain space
                i += 1
            default:
                out.append(c)
                i += 1
            }
        }
        return out
    }

    /// One `\…` command, cursor just past the backslash. Structural commands
    /// (fractions, roots, wrappers) recurse; everything else looks up the
    /// symbol table and — the graceful-degradation rule — falls back to its
    /// own name.
    private static func command(_ chars: [Character], _ i: inout Int) -> String {
        guard i < chars.count else { return "" }
        let first = chars[i]
        guard first.isLetter else {
            // Single-character escape: `\\` is a TeX row break; the thin-space
            // family collapses to a space or nothing; anything else (`\{`,
            // `\%`, `\$`, …) means the literal character.
            i += 1
            switch first {
            case "\\": return "\n"
            case ",", ";", ":", " ": return " "
            case "!": return ""
            default: return String(first)
            }
        }
        var name = ""
        while i < chars.count, chars[i].isLetter {
            name.append(chars[i])
            i += 1
        }
        if i < chars.count, chars[i] == "*" { i += 1 }   // \operatorname* etc.

        switch name {
        case "frac", "dfrac", "tfrac", "cfrac":
            return fraction(argument(chars, &i), argument(chars, &i))
        case "sqrt":
            var degree: String?
            if i < chars.count, chars[i] == "[" {
                i += 1
                var d = ""
                while i < chars.count, chars[i] != "]" {
                    d.append(chars[i])
                    i += 1
                }
                if i < chars.count { i += 1 }
                degree = unicode(d)
            }
            let body = argument(chars, &i)
            let prefix = degree.map { scripted($0, with: superscripts, marker: "") } ?? ""
            return body.count <= 2 ? prefix + "√" + body : prefix + "√(" + body + ")"
        case "text", "textrm", "textit", "textbf", "textsf", "texttt", "textnormal",
             "mathrm", "mathit", "mathbf", "mathsf", "mathtt", "mathfrak",
             "operatorname", "mbox", "hbox", "boldsymbol", "bm", "pmb":
            return argument(chars, &i)
        case "mathbb":
            return remapped(argument(chars, &i), via: blackboard)
        case "mathcal", "mathscr":
            return remapped(argument(chars, &i), via: calligraphic)
        case "vec", "hat", "widehat", "bar", "overline", "underline",
             "tilde", "widetilde", "dot", "ddot":
            // Single-character accents ride as combining marks (`\vec{v}` →
            // v⃗); longer bodies drop the decoration and keep the text.
            let body = argument(chars, &i)
            if body.count == 1, let mark = combining[name] { return body + mark }
            return body
        case "left", "right":
            // Delimiter sizing — the delimiter itself follows and the main
            // loop keeps it; `\left.` / `\right.` is an invisible wall.
            if i < chars.count, chars[i] == "." { i += 1 }
            return ""
        case "big", "Big", "bigg", "Bigg", "bigl", "bigr", "bigm",
             "Bigl", "Bigr", "biggl", "biggr", "Biggl", "Biggr",
             "displaystyle", "textstyle", "scriptstyle", "limits", "nolimits":
            return ""
        case "phantom", "vphantom", "hphantom":
            _ = argument(chars, &i)
            return ""
        case "hspace", "vspace":
            _ = argument(chars, &i)
            return " "
        case "begin", "end":
            _ = argument(chars, &i)   // the environment name — rows/tabs are
            return ""                 // handled by the global `\\` / `&` rules
        case "pmod":
            return " (mod " + argument(chars, &i) + ")"
        case "not":
            let rel = argument(chars, &i)
            return negated[rel] ?? ("¬" + rel)
        default:
            return symbols[name] ?? name
        }
    }

    /// One command argument: a `{…}` group, a nested `\command`, or a single
    /// character. Leading spaces are TeX-insignificant and skipped.
    private static func argument(_ chars: [Character], _ i: inout Int) -> String {
        while i < chars.count, chars[i] == " " { i += 1 }
        guard i < chars.count else { return "" }
        let c = chars[i]
        if c == "{" {
            i += 1
            return convert(chars, &i, until: "}")
        }
        if c == "\\" {
            i += 1
            return command(chars, &i)
        }
        i += 1
        return String(c)
    }

    /// Render a super/subscript: whole-span Unicode when every character has a
    /// script form (`x^2` → `x²`, `a_n` → `aₙ`), else fall back to the marker
    /// (`x^(n+1)`), parenthesised only when the script is more than one glyph.
    private static func scripted(_ body: String, with map: [Character: Character], marker: String) -> String {
        if body.isEmpty { return "" }
        if body == "∘" { return "°" }   // `x^\circ` is the degree sign
        let mapped = body.compactMap { map[$0] }
        if mapped.count == body.count { return String(mapped) }
        return body.count == 1 ? marker + body : marker + "(" + body + ")"
    }

    /// `\frac{a}{b}` → `a/b`, parenthesising a side only when it carries an
    /// operator or space (`\frac{a+b}{2}` → `(a+b)/2`, `\frac{dy}{dx}` →
    /// `dy/dx`). The handful of fractions with real glyphs use them.
    private static func fraction(_ num: String, _ den: String) -> String {
        if let glyph = vulgar[num + "/" + den] { return glyph }
        return side(num) + "/" + side(den)
    }

    private static func side(_ s: String) -> String {
        s.contains(where: { "+-−±∓=<>≤≥*·×÷/, ".contains($0) }) ? "(" + s + ")" : s
    }

    private static func remapped(_ s: String, via table: [Character: Character]) -> String {
        String(s.map { table[$0] ?? $0 })
    }

    /// Collapse runs of spaces (TeX treats them as one) and trim each line's
    /// edges, leaving row breaks from `\\` intact.
    private static func squeeze(_ s: String) -> String {
        s.components(separatedBy: "\n").map { line in
            var out = ""
            var lastWasSpace = false
            for ch in line.trimmingCharacters(in: .whitespaces) {
                if ch == " " {
                    if !lastWasSpace { out.append(ch) }
                    lastWasSpace = true
                } else {
                    out.append(ch)
                    lastWasSpace = false
                }
            }
            return out
        }.joined(separator: "\n")
    }

    // MARK: Glyph tables

    /// `\command` → symbol, kept to what LLM answers actually emit.
    private static let symbols: [String: String] = [
        // Greek
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ",
        "epsilon": "ε", "varepsilon": "ε", "zeta": "ζ", "eta": "η",
        "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ",
        "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π",
        "varpi": "ϖ", "rho": "ρ", "varrho": "ϱ", "sigma": "σ",
        "varsigma": "ς", "tau": "τ", "upsilon": "υ", "phi": "φ",
        "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ",
        "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ",
        "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        // Operators & relations
        "times": "×", "div": "÷", "pm": "±", "mp": "∓", "cdot": "·",
        "ast": "∗", "star": "⋆", "circ": "∘", "bullet": "•",
        "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "neq": "≠",
        "ne": "≠", "equiv": "≡", "approx": "≈", "sim": "∼",
        "simeq": "≃", "cong": "≅", "propto": "∝", "ll": "≪", "gg": "≫",
        "prec": "≺", "succ": "≻", "asymp": "≍", "doteq": "≐",
        // Calculus & big operators
        "infty": "∞", "partial": "∂", "nabla": "∇", "sum": "∑",
        "prod": "∏", "coprod": "∐", "int": "∫", "iint": "∬",
        "iiint": "∭", "oint": "∮", "prime": "′",
        // Sets & logic
        "in": "∈", "notin": "∉", "ni": "∋", "subset": "⊂",
        "supset": "⊃", "subseteq": "⊆", "supseteq": "⊇",
        "subsetneq": "⊊", "supsetneq": "⊋", "cup": "∪", "cap": "∩",
        "setminus": "∖", "emptyset": "∅", "varnothing": "∅",
        "forall": "∀", "exists": "∃", "nexists": "∄", "neg": "¬",
        "lnot": "¬", "land": "∧", "wedge": "∧", "lor": "∨", "vee": "∨",
        "oplus": "⊕", "ominus": "⊖", "otimes": "⊗", "oslash": "⊘",
        "odot": "⊙", "models": "⊨", "vdash": "⊢", "dashv": "⊣",
        "top": "⊤", "bot": "⊥", "therefore": "∴", "because": "∵",
        "implies": "⟹", "iff": "⟺",
        // Arrows
        "to": "→", "rightarrow": "→", "gets": "←", "leftarrow": "←",
        "Rightarrow": "⇒", "Leftarrow": "⇐", "leftrightarrow": "↔",
        "Leftrightarrow": "⇔", "mapsto": "↦", "uparrow": "↑",
        "downarrow": "↓", "longrightarrow": "⟶", "longleftarrow": "⟵",
        "hookrightarrow": "↪", "rightharpoonup": "⇀",
        // Delimiters & dots
        "langle": "⟨", "rangle": "⟩", "lfloor": "⌊", "rfloor": "⌋",
        "lceil": "⌈", "rceil": "⌉", "ldots": "…", "cdots": "⋯",
        "vdots": "⋮", "ddots": "⋱", "dots": "…", "dotsc": "…", "dotsb": "⋯",
        // Misc
        "angle": "∠", "perp": "⊥", "parallel": "∥", "nparallel": "∦",
        "mid": "∣", "nmid": "∤", "degree": "°", "hbar": "ℏ", "ell": "ℓ",
        "Re": "ℜ", "Im": "ℑ", "aleph": "ℵ", "wp": "℘", "dagger": "†",
        "ddagger": "‡", "checkmark": "✓", "triangle": "△", "square": "□",
        "Box": "□", "diamond": "◇", "colon": ":", "quad": " ",
        "qquad": " ", "space": " ",
    ]

    /// `\not` + relation → the precomposed negated glyph where one exists.
    private static let negated: [String: String] = [
        "=": "≠", "∈": "∉", "<": "≮", ">": "≯", "≤": "≰", "≥": "≱",
        "≡": "≢", "∼": "≁", "≈": "≉", "⊂": "⊄", "⊃": "⊅", "⊆": "⊈",
        "⊇": "⊉", "∣": "∤", "∥": "∦",
    ]

    /// Single-character accent decorations → combining marks.
    private static let combining: [String: String] = [
        "vec": "\u{20D7}", "hat": "\u{0302}", "widehat": "\u{0302}",
        "bar": "\u{0304}", "overline": "\u{0305}", "underline": "\u{0332}",
        "tilde": "\u{0303}", "widetilde": "\u{0303}",
        "dot": "\u{0307}", "ddot": "\u{0308}",
    ]

    private static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵",
        "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹", "+": "⁺", "-": "⁻",
        "−": "⁻", "=": "⁼", "(": "⁽", ")": "⁾",
        "a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ", "f": "ᶠ",
        "g": "ᵍ", "h": "ʰ", "i": "ⁱ", "j": "ʲ", "k": "ᵏ", "l": "ˡ",
        "m": "ᵐ", "n": "ⁿ", "o": "ᵒ", "p": "ᵖ", "r": "ʳ", "s": "ˢ",
        "t": "ᵗ", "u": "ᵘ", "v": "ᵛ", "w": "ʷ", "x": "ˣ", "y": "ʸ",
        "z": "ᶻ", "T": "ᵀ",
    ]

    private static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅",
        "6": "₆", "7": "₇", "8": "₈", "9": "₉", "+": "₊", "-": "₋",
        "−": "₋", "=": "₌", "(": "₍", ")": "₎",
        "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ",
        "l": "ₗ", "m": "ₘ", "n": "ₙ", "o": "ₒ", "p": "ₚ", "r": "ᵣ",
        "s": "ₛ", "t": "ₜ", "u": "ᵤ", "v": "ᵥ", "x": "ₓ",
    ]

    private static let blackboard: [Character: Character] = [
        "A": "𝔸", "B": "𝔹", "C": "ℂ", "D": "𝔻", "E": "𝔼", "F": "𝔽",
        "G": "𝔾", "H": "ℍ", "I": "𝕀", "J": "𝕁", "K": "𝕂", "L": "𝕃",
        "M": "𝕄", "N": "ℕ", "O": "𝕆", "P": "ℙ", "Q": "ℚ", "R": "ℝ",
        "S": "𝕊", "T": "𝕋", "U": "𝕌", "V": "𝕍", "W": "𝕎", "X": "𝕏",
        "Y": "𝕐", "Z": "ℤ", "1": "𝟙",
    ]

    private static let calligraphic: [Character: Character] = [
        "A": "𝒜", "B": "ℬ", "C": "𝒞", "D": "𝒟", "E": "ℰ", "F": "ℱ",
        "G": "𝒢", "H": "ℋ", "I": "ℐ", "J": "𝒥", "K": "𝒦", "L": "ℒ",
        "M": "ℳ", "N": "𝒩", "O": "𝒪", "P": "𝒫", "Q": "𝒬", "R": "ℛ",
        "S": "𝒮", "T": "𝒯", "U": "𝒰", "V": "𝒱", "W": "𝒲", "X": "𝒳",
        "Y": "𝒴", "Z": "𝒵",
    ]

    private static let vulgar: [String: String] = [
        "1/2": "½", "1/3": "⅓", "2/3": "⅔", "1/4": "¼", "3/4": "¾",
        "1/5": "⅕", "2/5": "⅖", "3/5": "⅗", "4/5": "⅘", "1/6": "⅙",
        "5/6": "⅚", "1/8": "⅛", "3/8": "⅜", "5/8": "⅝", "7/8": "⅞",
    ]
}
