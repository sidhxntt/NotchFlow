import CoreLocation
import Foundation

/// What the notch shows for weather: a temperature, a glyph, and nothing else.
///
/// Deliberately small. The panel has room for one line under the clock, so this
/// carries exactly what fits — a full forecast would be a different feature with
/// a different surface.
/// Which unit the temperature under the notch's clock is read in.
///
/// `system` follows `Locale.measurementSystem`, which is what this always did and
/// is right for most people. The override exists because the locale answer is
/// wrong for a sizeable minority — anyone working in a region whose formatting
/// they keep but whose temperature scale they don't think in.
public enum WeatherUnitPreference: String, CaseIterable, Sendable {
    case system, celsius, fahrenheit

    private static let defaultsKey = "utilityTemperatureUnit"

    public static var current: WeatherUnitPreference {
        get {
            UserDefaults.standard.string(forKey: defaultsKey)
                .flatMap(WeatherUnitPreference.init) ?? .system
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    public var usesFahrenheit: Bool {
        switch self {
        case .system:     return Locale.current.measurementSystem == .us
        case .celsius:    return false
        case .fahrenheit: return true
        }
    }

    public func temperature(fromCelsius celsius: Double) -> Double {
        usesFahrenheit ? celsius * 9 / 5 + 32 : celsius
    }

    public var label: String {
        switch self {
        case .system:     return "System"
        case .celsius:    return "Celsius"
        case .fahrenheit: return "Fahrenheit"
        }
    }
}

public struct WeatherSnapshot: Equatable, Codable, Sendable {
    /// Always stored in Celsius; the display converts. Storing the unit alongside
    /// the number is how caches end up showing 22°F on a warm day after someone
    /// changes their region.
    public let temperatureC: Double
    /// WMO weather interpretation code, as Open-Meteo reports it.
    public let code: Int
    public let isDay: Bool
    public let fetchedAt: Date

    public init(temperatureC: Double, code: Int, isDay: Bool, fetchedAt: Date) {
        self.temperatureC = temperatureC
        self.code = code
        self.isDay = isDay
        self.fetchedAt = fetchedAt
    }

    /// Rounded to whole degrees in the chosen unit — "27°", never "26.8°C". At a
    /// 10.5pt glyph beside a clock, the decimal is noise and the unit letter is
    /// clutter; the number is the information.
    public var shortTemperature: String {
        let value = WeatherUnitPreference.current.temperature(fromCelsius: temperatureC)
        return "\(Int(value.rounded()))°"
    }

    /// SF Symbol for the WMO code, day and night variants where one exists.
    ///
    /// Grouped by the code ranges Open-Meteo documents rather than enumerated
    /// one by one: the ranges are the contract, individual codes come and go.
    public var symbolName: String {
        switch code {
        case 0:          return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2:       return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3:          return "cloud.fill"
        case 45, 48:     return "cloud.fog.fill"
        case 51...57:    return "cloud.drizzle.fill"
        case 61...67:    return "cloud.rain.fill"
        case 71...77:    return "cloud.snow.fill"
        case 80...82:    return "cloud.heavyrain.fill"
        case 85, 86:     return "cloud.snow.fill"
        case 95...99:    return "cloud.bolt.rain.fill"
        default:         return "thermometer.medium"
        }
    }

    /// Anything older than this is not worth showing as "now".
    public func isFresh(at now: Date, lifetime: TimeInterval = 3600) -> Bool {
        now.timeIntervalSince(fetchedAt) < lifetime
    }
}

/// Fetches the current conditions from Open-Meteo.
///
/// Open-Meteo needs no API key and no account, which is the whole reason it is
/// here: a key would have to ship inside the app, where it is not a secret.
///
/// **This is the app's only unsolicited outbound request.** Everything else goes
/// to a provider the user configured. Two things follow from that: coordinates
/// are rounded to two decimals (~1 km) before they leave the Mac, which is far
/// more than weather needs and far less than a location, and the call happens
/// only when the panel is actually showing the weather.
public enum WeatherService {
    /// Two decimals ≈ 1 km. Enough for the right city, not enough for the right
    /// street.
    static func rounded(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    static func requestURL(latitude: Double, longitude: Double) -> URL? {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(rounded(latitude))),
            URLQueryItem(name: "longitude", value: String(rounded(longitude))),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
        ]
        return components?.url
    }

    /// Open-Meteo's `current` block, named exactly as the API spells it.
    private struct Response: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double
            let weather_code: Int
            let is_day: Int
        }
        let current: Current
    }

    static func decode(_ data: Data, now: Date) -> WeatherSnapshot? {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        return WeatherSnapshot(temperatureC: response.current.temperature_2m,
                               code: response.current.weather_code,
                               isDay: response.current.is_day == 1,
                               fetchedAt: now)
    }

    static func fetch(latitude: Double, longitude: Double, now: Date) async -> WeatherSnapshot? {
        guard let url = requestURL(latitude: latitude, longitude: longitude) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return nil }
        return decode(data, now: now)
    }
}

/// Where the weather is. Wraps CoreLocation so the rest of the app never has to
/// think about delegates or authorization states.
///
/// Asks for *reduced* accuracy: the notch wants the right city, and requesting
/// precise location for a temperature reading would be taking more than the
/// feature needs.
@MainActor
final class WeatherLocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = WeatherLocationProvider()

    @Published private(set) var coordinate: CLLocationCoordinate2D?
    @Published private(set) var authorization: CLAuthorizationStatus

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocationCoordinate2D?, Never>?

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyReduced
    }

    /// Ask macOS for permission. Called from the user pressing the weather row in
    /// Settings — never on its own, same rule the Accessibility watcher follows.
    func requestAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    /// The device's rough position, or nil when we have no permission. Requests a
    /// single fix rather than continuous updates: weather does not need to know
    /// when you cross the street.
    func currentCoordinate() async -> CLLocationCoordinate2D? {
        guard authorization == .authorizedAlways || authorization == .authorized else { return nil }
        if let coordinate { return coordinate }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            manager.requestLocation()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        let coordinate = locations.last?.coordinate
        MainActor.assumeIsolated {
            if let coordinate { self.coordinate = coordinate }
            continuation?.resume(returning: coordinate)
            continuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            continuation?.resume(returning: nil)
            continuation = nil
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated { authorization = status }
    }
}
