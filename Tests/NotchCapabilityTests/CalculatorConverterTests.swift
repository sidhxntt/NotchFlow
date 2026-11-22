import XCTest
@testable import NotchCapabilities

final class CalculatorConverterTests: XCTestCase {
    // MARK: - Converter

    private func unit(_ category: ConversionCategory, _ id: String) -> ConversionUnit {
        guard let unit = category.unit(id: id) else {
            XCTFail("\(category) has no unit \(id)")
            return category.units[0]
        }
        return unit
    }

    func testEveryCategoryHasUniqueUnitIdsAndAValidDefaultPair() {
        for category in ConversionCategory.allCases {
            let ids = category.units.map(\.id)
            XCTAssertEqual(ids.count, Set(ids).count, "\(category) repeats a unit id")
            XCTAssertNotNil(category.unit(id: category.defaultPair.from))
            XCTAssertNotNil(category.unit(id: category.defaultPair.to))
            XCTAssertNotEqual(category.defaultPair.from, category.defaultPair.to)
        }
    }

    func testLinearConversions() {
        XCTAssertEqual(UnitConverter.convert(1, from: unit(.length, "mi"), to: unit(.length, "km")), 1.609344, accuracy: 1e-12)
        XCTAssertEqual(UnitConverter.convert(12, from: unit(.length, "in"), to: unit(.length, "ft")), 1, accuracy: 1e-12)
        XCTAssertEqual(UnitConverter.convert(1, from: unit(.mass, "kg"), to: unit(.mass, "lb")), 2.2046226218, accuracy: 1e-9)
        XCTAssertEqual(UnitConverter.convert(1, from: unit(.data, "gib"), to: unit(.data, "mb")), 1073.741824, accuracy: 1e-9)
        XCTAssertEqual(UnitConverter.convert(100, from: unit(.speed, "kph"), to: unit(.speed, "mps")), 27.7777777778, accuracy: 1e-9)
        XCTAssertEqual(UnitConverter.convert(1, from: unit(.area, "ac"), to: unit(.area, "m2")), 4046.8564224, accuracy: 1e-9)
        XCTAssertEqual(UnitConverter.convert(90, from: unit(.time, "min"), to: unit(.time, "h")), 1.5, accuracy: 1e-12)
        XCTAssertEqual(UnitConverter.convert(1, from: unit(.volume, "gal"), to: unit(.volume, "l")), 3.785411784, accuracy: 1e-12)
    }

    func testTemperatureUsesOffsetsNotJustFactors() {
        let c = unit(.temperature, "c"), f = unit(.temperature, "f"), k = unit(.temperature, "k")
        XCTAssertEqual(UnitConverter.convert(100, from: c, to: f), 212, accuracy: 1e-9)
        XCTAssertEqual(UnitConverter.convert(32, from: f, to: c), 0, accuracy: 1e-9)
        XCTAssertEqual(UnitConverter.convert(-40, from: f, to: c), -40, accuracy: 1e-9)
        XCTAssertEqual(UnitConverter.convert(0, from: k, to: c), -273.15, accuracy: 1e-9)
        XCTAssertEqual(UnitConverter.convert(98.6, from: f, to: k), 310.15, accuracy: 1e-9)
    }

    func testConversionRoundTrips() {
        for category in ConversionCategory.allCases {
            for from in category.units {
                for to in category.units {
                    let there = UnitConverter.convert(42.5, from: from, to: to)
                    let back = UnitConverter.convert(there, from: to, to: from)
                    XCTAssertEqual(back, 42.5, accuracy: 1e-7, "\(from.id) ↔ \(to.id)")
                }
            }
        }
    }

    func testParseIsLenientAboutTypedNumbers() {
        XCTAssertEqual(UnitConverter.parse("1,250"), 1250)
        XCTAssertEqual(UnitConverter.parse(" 3.5 "), 3.5)
        XCTAssertEqual(UnitConverter.parse("−4"), -4)
        XCTAssertNil(UnitConverter.parse(""))
        XCTAssertNil(UnitConverter.parse("abc"))
        XCTAssertNil(UnitConverter.parse("inf"))
    }

    func testFormatHidesFloatingPointNoise() {
        XCTAssertEqual(UnitConverter.format(0.621371192237334), "0.6213712")
        XCTAssertEqual(UnitConverter.format(212), "212")
        XCTAssertEqual(UnitConverter.format(1_073_741_824), "1073741824")
        XCTAssertEqual(UnitConverter.format(0.000012), "0.000012")
        XCTAssertEqual(UnitConverter.format(-273.15), "-273.15")
        XCTAssertEqual(UnitConverter.format(0), "0")
        XCTAssertEqual(UnitConverter.format(.nan), "—")
    }

    func testSelectionFallsBackToDefaultsForUnknownIds() {
        let selection = ConverterSelection(category: .temperature, fromID: "km", toID: nil)
        XCTAssertEqual(selection.from.id, "c")
        XCTAssertEqual(selection.to.id, "f")
    }

    func testSwitchingCategoryResetsThePairAndSwapFlipsIt() {
        var selection = ConverterSelection(category: .length, fromID: "ft", toID: "m")
        selection.swapUnits()
        XCTAssertEqual(selection.from.id, "m")
        XCTAssertEqual(selection.to.id, "ft")
        selection.select(.mass)
        XCTAssertEqual(selection.category, .mass)
        XCTAssertEqual(selection.from.id, "kg")
        XCTAssertEqual(selection.to.id, "lb")
    }

    func testSelectionPersistsByStableIds() throws {
        let suite = "CalculatorConverterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(ConverterSelection.load(from: defaults).category, .currency)
        ConverterSelection(category: .data, fromID: "mb", toID: "kib").save(to: defaults)
        let restored = ConverterSelection.load(from: defaults)
        XCTAssertEqual(restored.category, .data)
        XCTAssertEqual(restored.from.id, "mb")
        XCTAssertEqual(restored.to.id, "kib")
    }

    // MARK: - Currency

    func testCurrencyComesFirstAndUsesLiveRates() {
        XCTAssertEqual(ConversionCategory.allCases.first, .currency)
        XCTAssertTrue(ConversionCategory.currency.usesLiveRates)
        XCTAssertFalse(ConversionCategory.length.usesLiveRates)
        XCTAssertEqual(ConversionCategory.currency.unit(id: "inr")?.symbol, "INR")
    }

    private let sample = Data("""
    {"amount":1.0,"base":"EUR","date":"2026-11-20","rates":{"USD":1.05,"INR":90.3,"JPY":160.5,"GBP":0.84}}
    """.utf8)

    func testDecodesFrankfurterAndCrossConvertsThroughTheBase() throws {
        let rates = try CurrencyRates.decodeFrankfurter(sample, fetchedAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(rates.base, "EUR")
        XCTAssertEqual(rates.rate("eur"), 1)
        XCTAssertEqual(try XCTUnwrap(rates.convert(10, from: "EUR", to: "USD")), 10.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(rates.convert(1.05, from: "usd", to: "inr")), 90.3, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(rates.convert(160.5, from: "JPY", to: "GBP")), 0.84, accuracy: 1e-9)
        XCTAssertNil(rates.convert(1, from: "USD", to: "XYZ"))
    }

    func testRatesGoStaleAfterSixHours() throws {
        let fetched = Date(timeIntervalSince1970: 1_000_000)
        let rates = try CurrencyRates.decodeFrankfurter(sample, fetchedAt: fetched)
        XCTAssertFalse(rates.isStale(now: fetched.addingTimeInterval(5 * 3600)))
        XCTAssertTrue(rates.isStale(now: fetched.addingTimeInterval(7 * 3600)))
    }

    func testCurrencyFormatting() {
        XCTAssertEqual(UnitConverter.formatCurrency(1234.5), "1234.50")
        XCTAssertEqual(UnitConverter.formatCurrency(0.0123456), "0.01235")
        XCTAssertEqual(UnitConverter.formatCurrency(0.00005678), "0.00005678")
        XCTAssertEqual(UnitConverter.formatCurrency(0), "0.00")
    }

    @MainActor
    func testStoreCachesRatesAndKeepsThemWhenARefreshFails() async throws {
        let suite = "CurrencyRateStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let payload = sample

        let store = CurrencyRateStore(defaults: defaults, fetch: { payload })
        XCTAssertNil(store.rates)
        await store.refreshIfNeeded()
        XCTAssertEqual(store.rates?.rate("INR"), 90.3)
        XCTAssertEqual(store.state, .idle)

        // A new store reads the cache; a failing fetch leaves it in place.
        let offline = CurrencyRateStore(defaults: defaults, fetch: { throw URLError(.notConnectedToInternet) })
        XCTAssertEqual(offline.rates?.rate("INR"), 90.3)
        await offline.refresh()
        XCTAssertEqual(offline.state, .failed)
        XCTAssertEqual(offline.rates?.rate("INR"), 90.3)
    }

    // MARK: - Calculator keypad

    private func type(_ keys: [CalculatorKey], from start: String = "") -> String {
        keys.reduce(start) { CalculatorInput.apply($1, to: $0) }
    }

    func testDigitsAndOperatorsBuildAnExpression() {
        XCTAssertEqual(type([.digit(1), .digit(2), .add, .digit(3)]), "12+3")
        XCTAssertEqual(type([.digit(6), .multiply, .digit(7), .percent]), "6×7%")
    }

    func testASecondOperatorReplacesTheFirst() {
        XCTAssertEqual(type([.digit(5), .add, .multiply]), "5×")
        XCTAssertEqual(type([.add]), "")
        XCTAssertEqual(type([.subtract, .digit(4)]), "−4")
        XCTAssertEqual(type([.subtract, .add]), "")
    }

    func testOneDecimalPointPerNumber() {
        XCTAssertEqual(type([.decimal, .digit(5)]), "0.5")
        XCTAssertEqual(type([.digit(1), .decimal, .digit(2), .decimal]), "1.2")
        XCTAssertEqual(type([.digit(1), .decimal, .digit(2), .add, .decimal]), "1.2+0.")
    }

    func testParenthesisKeyOpensAndClosesSensibly() {
        XCTAssertEqual(type([.parenthesis]), "(")
        XCTAssertEqual(type([.parenthesis, .digit(2), .add, .digit(3), .parenthesis]), "(2+3)")
        XCTAssertEqual(type([.digit(3), .parenthesis]), "3×(")
        XCTAssertEqual(type([.digit(2), .add, .parenthesis]), "2+(")
    }

    func testPercentNeedsSomethingToApplyTo() {
        XCTAssertEqual(type([.percent]), "")
        XCTAssertEqual(type([.digit(5), .add, .percent]), "5+")
    }

    func testBackspaceAndClear() {
        XCTAssertEqual(type([.backspace], from: "12+3"), "12+")
        XCTAssertEqual(type([.clear], from: "12+3"), "")
        XCTAssertEqual(type([.backspace]), "")
    }

    // MARK: - Calculator tape

    func testTapeKeepsNewestFirstWithoutDuplicatesAndCapsItsLength() {
        var history = CalculatorHistory()
        history.record(expression: "1+1", result: "2")
        history.record(expression: "1+1", result: "2")
        XCTAssertEqual(history.records.count, 1)
        history.record(expression: "  ", result: "0")
        XCTAssertEqual(history.records.count, 1)

        for n in 0..<(CalculatorHistory.limit + 5) {
            history.record(expression: "\(n)×2", result: "\(n * 2)")
        }
        XCTAssertEqual(history.records.count, CalculatorHistory.limit)
        XCTAssertEqual(history.records.first?.expression, "\(CalculatorHistory.limit + 4)×2")
    }

    func testTapePersists() throws {
        let suite = "CalculatorTapeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        var history = CalculatorHistory()
        history.record(expression: "240×18%", result: "43.2")
        history.save(to: defaults)
        XCTAssertEqual(CalculatorHistory.load(from: defaults).records.map(\.result), ["43.2"])

        history.clear()
        history.save(to: defaults)
        XCTAssertTrue(CalculatorHistory.load(from: defaults).records.isEmpty)
    }
}
