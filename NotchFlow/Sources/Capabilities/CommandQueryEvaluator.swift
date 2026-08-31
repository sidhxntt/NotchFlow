import Foundation

public enum CommandResultKind: Equatable, Sendable { case calculation, webURL }

public struct CommandQueryResult: Equatable, Sendable {
    public let kind: CommandResultKind
    public let title: String
    public let payload: String
}

public struct CommandCatalogEntry: Equatable, Sendable {
    public let title: String
    public let payload: String
    public init(title: String, payload: String) { self.title = title; self.payload = payload }
}

/// Local command-bar interpretation. It never invokes a shell or evaluates
/// arbitrary code; arithmetic is parsed by the small grammar below.
public enum CommandQueryEvaluator {
    public static func evaluate(_ query: String) -> CommandQueryResult? {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: value), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil {
            return CommandQueryResult(kind: .webURL, title: value, payload: value)
        }
        var parser = UtilityArithmeticParser(value)
        guard let number = parser.parse() else { return nil }
        let title = number.rounded() == number ? String(Int(number)) : String(number)
        return CommandQueryResult(kind: .calculation, title: title, payload: title)
    }

    public static func search(_ query: String, entries: [CommandCatalogEntry]) -> [CommandCatalogEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return entries }
        return entries.compactMap { entry -> (CommandCatalogEntry, Int)? in
            let title = entry.title.lowercased()
            let payload = entry.payload.lowercased()
            if title.hasPrefix(needle) || payload.hasPrefix(needle) { return (entry, 0) }
            if title.contains(needle) || payload.contains(needle) { return (entry, 1) }
            return nil
        }.sorted { $0.1 == $1.1 ? $0.0.title < $1.0.title : $0.1 < $1.1 }.map(\.0)
    }
}

private struct UtilityArithmeticParser {
    private let characters: [Character]
    private var index = 0
    init(_ source: String) { characters = Array(source.filter { !$0.isWhitespace }) }
    mutating func parse() -> Double? { guard let value = expression(), index == characters.count else { return nil }; return value }
    private mutating func expression() -> Double? {
        guard var value = term() else { return nil }
        while let op = peek(), op == "+" || op == "-" { index += 1; guard let rhs = term() else { return nil }; value = op == "+" ? value + rhs : value - rhs }
        return value
    }
    private mutating func term() -> Double? {
        guard var value = factor() else { return nil }
        while let op = peek(), op == "*" || op == "/" { index += 1; guard let rhs = factor(), (op != "/" || rhs != 0) else { return nil }; value = op == "*" ? value * rhs : value / rhs }
        return value
    }
    private mutating func factor() -> Double? {
        if peek() == "(" { index += 1; let value = expression(); guard peek() == ")" else { return nil }; index += 1; return value }
        let start = index
        if peek() == "-" { index += 1 }
        while let char = peek(), char.isNumber || char == "." { index += 1 }
        guard start != index else { return nil }
        return Double(String(characters[start..<index]))
    }
    private func peek() -> Character? { index < characters.count ? characters[index] : nil }
}
