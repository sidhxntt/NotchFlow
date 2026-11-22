import Foundation

/// A key on the Calculator utility's keypad. Typing into the expression field
/// stays free-form; the keypad goes through `CalculatorInput` so a tap can never
/// build an expression no one could have meant (two operators in a row, a second
/// decimal point in one number, a `)` with nothing open).
public enum CalculatorKey: Hashable, Sendable {
    case digit(Int)
    case decimal
    case add, subtract, multiply, divide
    case percent
    case parenthesis
    case backspace
    case clear

    public var label: String {
        switch self {
        case .digit(let d): String(d)
        case .decimal: "."
        case .add: "+"
        case .subtract: "−"
        case .multiply: "×"
        case .divide: "÷"
        case .percent: "%"
        case .parenthesis: "( )"
        case .backspace: "⌫"
        case .clear: "C"
        }
    }

    var operatorText: String? {
        switch self {
        case .add: "+"
        case .subtract: "−"
        case .multiply: "×"
        case .divide: "÷"
        default: nil
        }
    }
}

public enum CalculatorInput {
    static let operators: Set<Character> = ["+", "-", "*", "/", "^", "×", "÷", "−"]

    public static func apply(_ key: CalculatorKey, to expression: String) -> String {
        let last = expression.last
        switch key {
        case .clear:
            return ""
        case .backspace:
            return String(expression.dropLast())
        case .digit(let d):
            return expression + String(d)
        case .decimal:
            let number = trailingNumber(in: expression)
            if number.contains(".") { return expression }
            return expression + (number.isEmpty ? "0." : ".")
        case .percent:
            guard let last, last.isNumber || last == ")" else { return expression }
            return expression + "%"
        case .parenthesis:
            let open = expression.filter { $0 == "(" }.count - expression.filter { $0 == ")" }.count
            guard let last else { return "(" }
            let closesSomething = last.isNumber || last == ")" || last == "%"
            if open > 0 && closesSomething { return expression + ")" }
            // "3(" reads as 3 × (…), the way it would be written by hand.
            return expression + (closesSomething ? "×(" : "(")
        case .add, .subtract, .multiply, .divide:
            let op = key.operatorText!
            guard let last else {
                // Only a leading minus makes sense on an empty display.
                return key == .subtract ? "−" : ""
            }
            if last == "(" {
                return key == .subtract ? expression + "−" : expression
            }
            if operators.contains(last) {
                // Tapping a different operator corrects the previous one rather
                // than stacking up "5+×". A lone leading minus is just cleared.
                let trimmed = String(expression.dropLast())
                return trimmed.isEmpty ? (key == .subtract ? "−" : "") : trimmed + op
            }
            if last == "." { return String(expression.dropLast()) + op }
            return expression + op
        }
    }

    /// The digits and decimal point at the end of the expression — the number
    /// currently being typed.
    static func trailingNumber(in expression: String) -> String {
        String(expression.reversed().prefix { $0.isNumber || $0 == "." }.reversed())
    }
}

/// One committed calculation on the Calculator's tape.
public struct CalculationRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let expression: String
    public let result: String

    public init(id: UUID = UUID(), expression: String, result: String) {
        self.id = id
        self.expression = expression
        self.result = result
    }
}

/// The short tape of recent calculations, newest first, kept on this Mac only.
public struct CalculatorHistory: Equatable, Sendable {
    public static let limit = 12
    private static let defaultsKey = "notchflow.calculator.history.v1"

    public private(set) var records: [CalculationRecord]

    public init(records: [CalculationRecord] = []) {
        self.records = Array(records.prefix(Self.limit))
    }

    /// Pressing = twice on the same sum shouldn't fill the tape with duplicates.
    public mutating func record(expression: String, result: String) {
        let expression = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expression.isEmpty, !result.isEmpty else { return }
        if let latest = records.first, latest.expression == expression, latest.result == result { return }
        records.insert(CalculationRecord(expression: expression, result: result), at: 0)
        if records.count > Self.limit { records.removeLast(records.count - Self.limit) }
    }

    public mutating func clear() { records.removeAll() }

    public static func load(from defaults: UserDefaults = .standard) -> CalculatorHistory {
        guard let data = defaults.data(forKey: defaultsKey),
              let records = try? JSONDecoder().decode([CalculationRecord].self, from: data) else {
            return CalculatorHistory()
        }
        return CalculatorHistory(records: records)
    }

    public func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

/// The Calculator's settings. Keys are public so the overlay can bind them with
/// `@AppStorage` and update live while Settings changes them.
public enum CalculatorPreferences {
    public static let showsKeypadKey = "notchflow.calculator.showsKeypad.v1"
    public static let keepsTapeKey = "notchflow.calculator.keepsTape.v1"
    /// Decimal places to show, or `automaticPrecision` for "as many as needed".
    public static let precisionKey = "notchflow.calculator.precision.v1"
    public static let automaticPrecision = -1
    public static let precisionChoices = [automaticPrecision, 0, 2, 4, 6]

    public static func precisionLabel(_ places: Int) -> String {
        switch places {
        case automaticPrecision: "Automatic"
        case 0: "Whole numbers"
        case 1: "1 decimal place"
        default: "\(places) decimal places"
        }
    }

    /// Fixed decimals when the user picked a count; otherwise the automatic
    /// rendering passed in (which hides float noise and trailing zeros).
    public static func format(_ value: Double, places: Int, automatic: (Double) -> String) -> String {
        guard places >= 0, value.isFinite, abs(value) < 1e15 else { return automatic(value) }
        let text = String(format: "%.\(places)f", value)
        // "-0.00" is just zero.
        return Double(text) == 0 ? String(format: "%.\(places)f", 0.0) : text
    }
}
