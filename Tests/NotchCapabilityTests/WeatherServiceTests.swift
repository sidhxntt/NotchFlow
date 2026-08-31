import XCTest
@testable import NotchCapabilities

final class WeatherServiceTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func snapshot(temperatureC: Double = 20, code: Int = 0, isDay: Bool = true) -> WeatherSnapshot {
        WeatherSnapshot(temperatureC: temperatureC, code: code, isDay: isDay, fetchedAt: t0)
    }

    // MARK: - Privacy

    func testCoordinatesAreRoundedBeforeLeavingTheMac() {
        // Two decimals ≈ 1 km. A full-precision coordinate would pin a building.
        XCTAssertEqual(WeatherService.rounded(12.97161234), 12.97)
        XCTAssertEqual(WeatherService.rounded(77.59461234), 77.59)
        XCTAssertEqual(WeatherService.rounded(-0.126236), -0.13)
    }

    func testTheRequestURLCarriesOnlyRoundedCoordinates() {
        let url = WeatherService.requestURL(latitude: 12.97161234, longitude: 77.59461234)
        let string = url?.absoluteString ?? ""
        XCTAssertTrue(string.contains("latitude=12.97"), string)
        XCTAssertTrue(string.contains("longitude=77.59"), string)
        XCTAssertFalse(string.contains("12.9716"), "full precision must never be sent")
    }

    // MARK: - Decoding

    func testDecodesOpenMeteoCurrentBlock() {
        let json = Data("""
        {"current":{"time":"2026-08-28T00:00","temperature_2m":20.9,"weather_code":3,"is_day":0}}
        """.utf8)
        guard let snapshot = WeatherService.decode(json, now: t0) else {
            return XCTFail("failed to decode a well-formed response")
        }
        XCTAssertEqual(snapshot.temperatureC, 20.9)
        XCTAssertEqual(snapshot.code, 3)
        XCTAssertFalse(snapshot.isDay)
        XCTAssertEqual(snapshot.fetchedAt, t0)
    }

    func testGarbageDecodesToNothingRatherThanZeroDegrees() {
        XCTAssertNil(WeatherService.decode(Data("not json".utf8), now: t0))
        XCTAssertNil(WeatherService.decode(Data("{}".utf8), now: t0))
    }

    // MARK: - Display

    func testTemperatureRoundsToWholeDegrees() {
        XCTAssertEqual(snapshot(temperatureC: 20.9).shortTemperature.hasSuffix("°"), true)
        XCTAssertFalse(snapshot(temperatureC: 20.9).shortTemperature.contains("."),
                       "a decimal at 9.5pt beside a clock is noise")
    }

    func testSymbolFollowsTheWMOCodeAndTimeOfDay() {
        XCTAssertEqual(snapshot(code: 0, isDay: true).symbolName, "sun.max.fill")
        XCTAssertEqual(snapshot(code: 0, isDay: false).symbolName, "moon.stars.fill")
        XCTAssertEqual(snapshot(code: 2, isDay: true).symbolName, "cloud.sun.fill")
        XCTAssertEqual(snapshot(code: 3).symbolName, "cloud.fill")
        XCTAssertEqual(snapshot(code: 63).symbolName, "cloud.rain.fill")
        XCTAssertEqual(snapshot(code: 75).symbolName, "cloud.snow.fill")
        XCTAssertEqual(snapshot(code: 96).symbolName, "cloud.bolt.rain.fill")
    }

    func testAnUnknownCodeStillRendersSomething() {
        XCTAssertEqual(snapshot(code: 4242).symbolName, "thermometer.medium")
    }

    // MARK: - Freshness

    func testStaleReadingsAreNotFresh() {
        let reading = snapshot()
        XCTAssertTrue(reading.isFresh(at: t0.addingTimeInterval(600)))
        XCTAssertFalse(reading.isFresh(at: t0.addingTimeInterval(3601)))
        XCTAssertFalse(reading.isFresh(at: t0.addingTimeInterval(1000), lifetime: 900),
                       "the caller's own lifetime wins")
    }

    func testASnapshotSurvivesTheRoundTripThroughItsCache() throws {
        let original = snapshot(temperatureC: 20.9, code: 61, isDay: false)
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(WeatherSnapshot.self, from: data)
        XCTAssertEqual(restored, original)
    }
}
