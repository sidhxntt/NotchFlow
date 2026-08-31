import Foundation

public struct TextSnippet: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var trigger: String
    public var body: String
    public var folder: String?
    public var isEnabled: Bool

    public init(id: UUID = UUID(), trigger: String, body: String, folder: String? = nil, isEnabled: Bool = true) {
        self.id = id
        self.trigger = trigger
        self.body = body
        self.folder = folder
        self.isEnabled = isEnabled
    }
}

public struct TextSnippetExpansion: Equatable, Sendable {
    public let replacing: String
    public let text: String
}

/// Snippet matching and template expansion. The event-tap adapter only supplies
/// the current text and applies the returned replacement at the active caret.
public struct TextSnippetStore: Sendable {
    public var snippets: [TextSnippet]

    public init(snippets: [TextSnippet] = []) { self.snippets = snippets }

    public func snippets(in folder: String?) -> [TextSnippet] {
        snippets.filter { $0.folder == folder }
    }

    public func expansion(in text: String, clipboard: String, now: Date,
                          locale: Locale = .current, timeZone: TimeZone = .current) -> TextSnippetExpansion? {
        let match = snippets
            .filter { $0.isEnabled && !$0.trigger.isEmpty && text.hasSuffix($0.trigger) }
            .max { $0.trigger.count < $1.trigger.count }
        guard let match else { return nil }

        // A prefix of a longer token is not an invocation, e.g. `;sig` inside
        // `;signature`. The caller will revisit once typing stops on a trigger.
        let before = text.dropLast(match.trigger.count)
        if let last = before.last, last.isLetter || last.isNumber || last == "_" { return nil }
        return TextSnippetExpansion(replacing: match.trigger,
                                    text: expand(match.body, clipboard: clipboard, now: now,
                                                 locale: locale, timeZone: timeZone))
    }

    private func expand(_ template: String, clipboard: String, now: Date,
                        locale: Locale, timeZone: TimeZone) -> String {
        var value = template.replacingOccurrences(of: "[[clipboard]]", with: clipboard)
        let expression = try? NSRegularExpression(pattern: #"\[\[date:([^\]]+)\]\]"#)
        let range = NSRange(value.startIndex..., in: value)
        let matches = expression?.matches(in: value, range: range).reversed() ?? []
        for match in matches {
            guard let formatRange = Range(match.range(at: 1), in: value),
                  let wholeRange = Range(match.range(at: 0), in: value) else { continue }
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone
            formatter.dateFormat = String(value[formatRange])
            value.replaceSubrange(wholeRange, with: formatter.string(from: now))
        }
        return value
    }
}
