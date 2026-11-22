import Foundation

/// One unit the Converter utility offers. Every unit is a straight line onto its
/// category's base unit (`base = value * factor + offset`), which covers the
/// affine temperature scales as well as the purely scaled ones without pulling
/// Foundation's non-`Sendable` `Dimension` objects into a value type.
public struct ConversionUnit: Identifiable, Hashable, Sendable {
    /// Stable key persisted in UserDefaults — never a localized name.
    public let id: String
    public let name: String
    public let symbol: String
    let factor: Double
    let offset: Double

    init(_ id: String, _ name: String, _ symbol: String, _ factor: Double, offset: Double = 0) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.factor = factor
        self.offset = offset
    }

    func toBase(_ value: Double) -> Double { value * factor + offset }
    func fromBase(_ value: Double) -> Double { (value - offset) / factor }
}

/// The families of units the Converter switches between. Currency comes first and
/// is the odd one out: its rates are a daily snapshot (`CurrencyRates`), so its
/// units carry no factor and convert through `CurrencyRates.convert` instead.
/// Every other family is fixed arithmetic and works offline.
public enum ConversionCategory: String, CaseIterable, Identifiable, Sendable {
    case currency, length, mass, temperature, volume, area, speed, data, time

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .currency: "Currency"
        case .length: "Length"
        case .mass: "Weight"
        case .temperature: "Temperature"
        case .volume: "Volume"
        case .area: "Area"
        case .speed: "Speed"
        case .data: "Data"
        case .time: "Time"
        }
    }

    public var symbolName: String {
        switch self {
        case .currency: "banknote"
        case .length: "ruler"
        case .mass: "scalemass"
        case .temperature: "thermometer.medium"
        case .volume: "drop"
        case .area: "square.dashed"
        case .speed: "speedometer"
        case .data: "internaldrive"
        case .time: "clock"
        }
    }

    /// True for the one family whose factors come from fetched rates.
    public var usesLiveRates: Bool { self == .currency }

    public var units: [ConversionUnit] {
        switch self {
        case .currency:
            // Every currency in the European Central Bank's daily reference set.
            // The id is the lowercased ISO code; the symbol is the ISO code, which
            // is unambiguous where "$" or "¥" would not be. Factors are unused.
            Self.currencies.map { ConversionUnit($0.code.lowercased(), $0.name, $0.code, 1) }
        case .length: [
            .init("mm", "Millimetres", "mm", 0.001),
            .init("cm", "Centimetres", "cm", 0.01),
            .init("m", "Metres", "m", 1),
            .init("km", "Kilometres", "km", 1000),
            .init("in", "Inches", "in", 0.0254),
            .init("ft", "Feet", "ft", 0.3048),
            .init("yd", "Yards", "yd", 0.9144),
            .init("mi", "Miles", "mi", 1609.344),
            .init("nmi", "Nautical miles", "nmi", 1852),
        ]
        case .mass: [
            .init("mg", "Milligrams", "mg", 0.000001),
            .init("g", "Grams", "g", 0.001),
            .init("kg", "Kilograms", "kg", 1),
            .init("t", "Tonnes", "t", 1000),
            .init("oz", "Ounces", "oz", 0.028349523125),
            .init("lb", "Pounds", "lb", 0.45359237),
            .init("st", "Stone", "st", 6.35029318),
        ]
        case .temperature: [
            .init("c", "Celsius", "°C", 1),
            .init("f", "Fahrenheit", "°F", 5.0 / 9.0, offset: -160.0 / 9.0),
            .init("k", "Kelvin", "K", 1, offset: -273.15),
        ]
        case .volume: [
            .init("ml", "Millilitres", "mL", 0.001),
            .init("l", "Litres", "L", 1),
            .init("m3", "Cubic metres", "m³", 1000),
            .init("tsp", "Teaspoons (US)", "tsp", 0.00492892159375),
            .init("tbsp", "Tablespoons (US)", "tbsp", 0.01478676478125),
            .init("floz", "Fluid ounces (US)", "fl oz", 0.0295735295625),
            .init("cup", "Cups (US)", "cup", 0.2365882365),
            .init("pt", "Pints (US)", "pt", 0.473176473),
            .init("qt", "Quarts (US)", "qt", 0.946352946),
            .init("gal", "Gallons (US)", "gal", 3.785411784),
            .init("impgal", "Gallons (UK)", "gal UK", 4.54609),
        ]
        case .area: [
            .init("cm2", "Square centimetres", "cm²", 0.0001),
            .init("m2", "Square metres", "m²", 1),
            .init("ha", "Hectares", "ha", 10_000),
            .init("km2", "Square kilometres", "km²", 1_000_000),
            .init("in2", "Square inches", "in²", 0.00064516),
            .init("ft2", "Square feet", "ft²", 0.09290304),
            .init("yd2", "Square yards", "yd²", 0.83612736),
            .init("ac", "Acres", "ac", 4046.8564224),
            .init("mi2", "Square miles", "mi²", 2_589_988.110336),
        ]
        case .speed: [
            .init("mps", "Metres per second", "m/s", 1),
            .init("kph", "Kilometres per hour", "km/h", 1 / 3.6),
            .init("mph", "Miles per hour", "mph", 0.44704),
            .init("fps", "Feet per second", "ft/s", 0.3048),
            .init("kn", "Knots", "kn", 1852.0 / 3600.0),
        ]
        case .data: [
            .init("bit", "Bits", "bit", 0.125),
            .init("b", "Bytes", "B", 1),
            .init("kb", "Kilobytes", "KB", 1e3),
            .init("mb", "Megabytes", "MB", 1e6),
            .init("gb", "Gigabytes", "GB", 1e9),
            .init("tb", "Terabytes", "TB", 1e12),
            .init("kib", "Kibibytes", "KiB", 1024),
            .init("mib", "Mebibytes", "MiB", 1_048_576),
            .init("gib", "Gibibytes", "GiB", 1_073_741_824),
        ]
        case .time: [
            .init("ms", "Milliseconds", "ms", 0.001),
            .init("s", "Seconds", "s", 1),
            .init("min", "Minutes", "min", 60),
            .init("h", "Hours", "h", 3600),
            .init("d", "Days", "d", 86_400),
            .init("wk", "Weeks", "wk", 604_800),
            .init("yr", "Years (365 d)", "yr", 31_536_000),
        ]
        }
    }

    static let currencies: [(code: String, name: String)] = [
        ("USD", "US dollar"), ("EUR", "Euro"), ("GBP", "British pound"), ("INR", "Indian rupee"),
        ("JPY", "Japanese yen"), ("CNY", "Chinese yuan"), ("CAD", "Canadian dollar"),
        ("AUD", "Australian dollar"), ("CHF", "Swiss franc"), ("SGD", "Singapore dollar"),
        ("HKD", "Hong Kong dollar"), ("KRW", "South Korean won"), ("NZD", "New Zealand dollar"),
        ("SEK", "Swedish krona"), ("NOK", "Norwegian krone"), ("DKK", "Danish krone"),
        ("PLN", "Polish złoty"), ("CZK", "Czech koruna"), ("HUF", "Hungarian forint"),
        ("RON", "Romanian leu"), ("ISK", "Icelandic króna"), ("TRY", "Turkish lira"),
        ("ILS", "Israeli shekel"), ("ZAR", "South African rand"), ("BRL", "Brazilian real"),
        ("MXN", "Mexican peso"), ("THB", "Thai baht"), ("IDR", "Indonesian rupiah"),
        ("MYR", "Malaysian ringgit"), ("PHP", "Philippine peso"),
    ]

    /// The pair a first-time user most likely wants when opening the category.
    /// Currency starts from US dollars into the Mac's own currency when that's
    /// one we have, otherwise into euros.
    public var defaultPair: (from: String, to: String) {
        switch self {
        case .currency:
            let local = Locale.current.currency?.identifier.lowercased()
            let known = local.flatMap { code in Self.currencies.contains { $0.code.lowercased() == code } ? code : nil }
            return ("usd", known.flatMap { $0 == "usd" ? nil : $0 } ?? "eur")
        case .length: return ("km", "mi")
        case .mass: return ("kg", "lb")
        case .temperature: return ("c", "f")
        case .volume: return ("l", "gal")
        case .area: return ("m2", "ft2")
        case .speed: return ("kph", "mph")
        case .data: return ("gb", "gib")
        case .time: return ("h", "min")
        }
    }

    public func unit(id: String) -> ConversionUnit? {
        units.first { $0.id == id }
    }
}

public enum UnitConverter {
    /// Fixed-factor conversion. Currency units carry no factor — convert those
    /// with `CurrencyRates.convert` (this returns the value unchanged for them).
    public static func convert(_ value: Double, from: ConversionUnit, to: ConversionUnit) -> Double {
        to.fromBase(from.toBase(value))
    }

    /// Lenient number reading for a typed value: grouping commas, spaces, and the
    /// typographic minus are all accepted, so a pasted "1,250" or "−4" just works.
    public static func parse(_ text: String) -> Double? {
        let cleaned = text
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: " ", with: "")
        guard !cleaned.isEmpty, let value = Double(cleaned), value.isFinite else { return nil }
        return value
    }

    /// Money reads in cents; anything under one keeps four significant digits so
    /// a rate like 1 IDR = 0.00005678 EUR doesn't collapse to "0.00".
    public static func formatCurrency(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        let magnitude = abs(value)
        if magnitude == 0 { return "0.00" }
        if magnitude < 1 {
            var text = String(format: "%.4g", value)
            if text.contains("e") { text = String(format: "%.8f", value) }
            if text.contains(".") {
                while text.hasSuffix("0") { text.removeLast() }
                if text.hasSuffix(".") { text.removeLast() }
            }
            return text
        }
        return String(format: "%.2f", value)
    }

    /// Up to seven significant digits — enough for any everyday conversion while
    /// hiding floating-point noise (`1 km → mi` reads 0.6213712, not
    /// 0.621371192237334). Tiny and huge magnitudes switch to scientific notation.
    public static func format(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        if value == 0 { return "0" }
        let magnitude = abs(value)
        if magnitude >= 1e15 || magnitude < 1e-6 {
            return String(format: "%.4e", value)
        }
        var text = String(format: "%.7g", value)
        if text.contains("e") {
            // %g fell back to exponent form for a value in range; print it plainly.
            text = String(format: "%.6f", value)
        }
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text == "-0" ? "0" : text
    }
}

/// The category and unit pair the Converter reopens with. Stored by stable ids
/// so a renamed or reordered unit list never maps someone's choice onto the
/// wrong unit; anything unrecognized falls back to the category's default pair.
public struct ConverterSelection: Equatable, Sendable {
    public var category: ConversionCategory
    public var from: ConversionUnit
    public var to: ConversionUnit

    public init(category: ConversionCategory, fromID: String? = nil, toID: String? = nil) {
        self.category = category
        let pair = category.defaultPair
        let fallbackFrom = category.unit(id: pair.from) ?? category.units[0]
        let fallbackTo = category.unit(id: pair.to) ?? category.units[min(1, category.units.count - 1)]
        from = fromID.flatMap(category.unit(id:)) ?? fallbackFrom
        to = toID.flatMap(category.unit(id:)) ?? fallbackTo
    }

    public mutating func swapUnits() {
        let previous = from
        from = to
        to = previous
    }

    /// Switching category resets to that category's defaults: units never carry
    /// across families (there is no "kilometres" of temperature).
    public mutating func select(_ category: ConversionCategory) {
        guard category != self.category else { return }
        self = ConverterSelection(category: category)
    }

    private static let categoryKey = "notchflow.converter.category.v1"
    private static let fromKey = "notchflow.converter.from.v1"
    private static let toKey = "notchflow.converter.to.v1"

    public static func load(from defaults: UserDefaults = .standard) -> ConverterSelection {
        let category = defaults.string(forKey: categoryKey).flatMap(ConversionCategory.init(rawValue:)) ?? .currency
        return ConverterSelection(category: category,
                                  fromID: defaults.string(forKey: fromKey),
                                  toID: defaults.string(forKey: toKey))
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(category.rawValue, forKey: Self.categoryKey)
        defaults.set(from.id, forKey: Self.fromKey)
        defaults.set(to.id, forKey: Self.toKey)
    }
}

/// Which unit families the Converter's strip offers. Stored as one comma-joined
/// string of raw values so the overlay can observe it with `@AppStorage`; stored
/// by raw value, never index, so adding a family doesn't remap anyone's choice.
public enum ConverterCategoryVisibility {
    public static let hiddenKey = "notchflow.converter.hiddenCategories.v1"

    public static func hidden(from raw: String) -> Set<String> {
        Set(raw.split(separator: ",").map(String.init))
    }

    public static func encode(_ hidden: Set<String>) -> String {
        hidden.sorted().joined(separator: ",")
    }

    /// Never empty: hiding everything would leave a Converter with nothing to
    /// convert, so that state falls back to showing all of them.
    public static func visible(hiddenRaw raw: String) -> [ConversionCategory] {
        let hidden = hidden(from: raw)
        let visible = ConversionCategory.allCases.filter { !hidden.contains($0.rawValue) }
        return visible.isEmpty ? ConversionCategory.allCases : visible
    }

    public static func visible(in defaults: UserDefaults = .standard) -> [ConversionCategory] {
        visible(hiddenRaw: defaults.string(forKey: hiddenKey) ?? "")
    }

    /// Returns the new raw value, or nil when the change would hide the last
    /// visible family — the settings chip must not claim a change that was refused.
    public static func setting(_ category: ConversionCategory, visible: Bool, in raw: String) -> String? {
        var hidden = hidden(from: raw)
        if visible {
            hidden.remove(category.rawValue)
        } else {
            guard self.visible(hiddenRaw: raw).filter({ $0 != category }).count >= 1 else { return nil }
            hidden.insert(category.rawValue)
        }
        return encode(hidden)
    }
}

extension ConverterSelection {
    /// The saved selection, moved to the first visible family if the saved one
    /// has since been hidden in Settings.
    public static func load(from defaults: UserDefaults = .standard,
                            visible: [ConversionCategory]) -> ConverterSelection {
        let saved = load(from: defaults)
        guard !visible.contains(saved.category), let first = visible.first else { return saved }
        return ConverterSelection(category: first)
    }
}
