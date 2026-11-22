import Combine
import Foundation

/// One snapshot of reference exchange rates: how many units of each currency one
/// unit of `base` buys. The Converter's other families are fixed factors; this is
/// the one that has to come from somewhere, so it's fetched once, kept on this
/// Mac, and reused offline until a newer snapshot arrives.
public struct CurrencyRates: Codable, Equatable, Sendable {
    public let base: String
    /// The publication day of the rates (e.g. "2026-11-20"), not when we fetched.
    public let date: String
    public let rates: [String: Double]
    public let fetchedAt: Date

    public init(base: String, date: String, rates: [String: Double], fetchedAt: Date) {
        self.base = base.uppercased()
        self.date = date
        var rates = Dictionary(uniqueKeysWithValues: rates.map { ($0.key.uppercased(), $0.value) })
        rates[self.base] = 1
        self.rates = rates
        self.fetchedAt = fetchedAt
    }

    /// Units of `code` per one unit of the base, or nil if the snapshot lacks it.
    public func rate(_ code: String) -> Double? {
        guard let rate = rates[code.uppercased()], rate.isFinite, rate > 0 else { return nil }
        return rate
    }

    /// Cross-converts through the base, so any pair in the snapshot works.
    public func convert(_ amount: Double, from: String, to: String) -> Double? {
        guard let fromRate = rate(from), let toRate = rate(to) else { return nil }
        return amount / fromRate * toRate
    }

    /// Reference rates publish once per working day; checking a few times a day
    /// is plenty and keeps the request count trivial.
    public func isStale(now: Date = Date(), maxAge: TimeInterval = 6 * 3600) -> Bool {
        now.timeIntervalSince(fetchedAt) > maxAge
    }

    /// "21 Nov" for the footnote; falls back to the raw string if it isn't a date.
    public var publishedLabel: String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(identifier: "UTC")
        parser.dateFormat = "yyyy-MM-dd"
        guard let day = parser.date(from: date) else { return date }
        let out = DateFormatter()
        out.timeZone = TimeZone(identifier: "UTC")
        out.setLocalizedDateFormatFromTemplate("d MMM")
        return out.string(from: day)
    }

    // MARK: - Source

    /// Frankfurter publishes the European Central Bank's reference rates. No key,
    /// no account, and nothing about the user is sent: the request is the same
    /// for everyone.
    public static let sourceURL = URL(string: "https://api.frankfurter.dev/v1/latest?base=EUR")!
    public static let sourceName = "European Central Bank"

    private struct FrankfurterPayload: Decodable {
        let base: String
        let date: String
        let rates: [String: Double]
    }

    public static func decodeFrankfurter(_ data: Data, fetchedAt: Date = Date()) throws -> CurrencyRates {
        let payload = try JSONDecoder().decode(FrankfurterPayload.self, from: data)
        return CurrencyRates(base: payload.base, date: payload.date, rates: payload.rates, fetchedAt: fetchedAt)
    }

    // MARK: - Cache

    private static let defaultsKey = "notchflow.converter.currencyRates.v1"

    public static func load(from defaults: UserDefaults = .standard) -> CurrencyRates? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(CurrencyRates.self, from: data)
    }

    public func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

public enum CurrencyRateLoadState: Equatable, Sendable {
    case idle
    case loading
    case failed
}

/// Owns the cached snapshot and refreshes it when it has gone stale. A failed
/// refresh never discards the cached rates — yesterday's rate beats no rate.
@MainActor
public final class CurrencyRateStore: ObservableObject {
    public typealias Fetcher = @Sendable () async throws -> Data

    public static let shared = CurrencyRateStore()

    @Published public private(set) var rates: CurrencyRates?
    @Published public private(set) var state: CurrencyRateLoadState = .idle

    private let defaults: UserDefaults
    private let fetch: Fetcher
    private let now: @Sendable () -> Date

    public init(defaults: UserDefaults = .standard,
                now: @escaping @Sendable () -> Date = { Date() },
                fetch: @escaping Fetcher = CurrencyRateStore.liveFetch) {
        self.defaults = defaults
        self.now = now
        self.fetch = fetch
        rates = CurrencyRates.load(from: defaults)
    }

    public nonisolated static let liveFetch: Fetcher = {
        var request = URLRequest(url: CurrencyRates.sourceURL, timeoutInterval: 12)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    public func refreshIfNeeded() async {
        guard rates?.isStale(now: now()) ?? true else { return }
        await refresh()
    }

    public func refresh() async {
        guard state != .loading else { return }
        state = .loading
        do {
            let data = try await fetch()
            let fresh = try CurrencyRates.decodeFrankfurter(data, fetchedAt: now())
            guard !fresh.rates.isEmpty else { throw URLError(.cannotParseResponse) }
            rates = fresh
            fresh.save(to: defaults)
            state = .idle
        } catch {
            state = .failed
        }
    }
}
