import Combine
import Foundation

public enum LicenseBlockedReason: String, Equatable, Sendable {
    case trialExpired
    case licenseInvalid
    case configurationUnavailable
    case secureStorageUnavailable
    case activationRequired
}

public enum LicenseState: Equatable, Sendable {
    case checking
    case trial(remaining: Int)
    case licensed
    case blocked(reason: LicenseBlockedReason)

    public var allowsProductServices: Bool {
        switch self {
        case .trial, .licensed: true
        case .checking, .blocked: false
        }
    }

    /// Only a resolved denial should take focus and show the restricted Settings
    /// surface. Startup begins in `.checking`; presenting UI for that transient
    /// state caused the old license window to flash on every launch.
    public var shouldPresentRestrictedSettings: Bool {
        if case .blocked = self { return true }
        return false
    }

    /// During the free trial users can use NotchFlow, but Settings remains an
    /// intentional upgrade surface. An activated lifetime license unlocks its
    /// configuration categories; an expired trial remains on About to recover.
    public var shouldRestrictSettingsToAbout: Bool {
        switch self {
        case .trial, .blocked:
            true
        case .checking, .licensed:
            false
        }
    }

    /// The menu uses this to offer a quiet, non-interactive trial reminder
    /// without implying that checking, licensed, or blocked states still have
    /// usable trial time.
    public var trialDaysRemaining: Int? {
        if case .trial(let remaining) = self { return remaining }
        return nil
    }

    /// Async product work may start or commit an effect only while its task is
    /// still live and the entitlement still permits product use. Callers check
    /// this on both sides of suspension points so an expiry cannot race a write.
    public func allowsAsyncProductEffect(isCancelled: Bool) -> Bool {
        !isCancelled && allowsProductServices
    }
}

/// The complete teardown that must run whenever the entitlement stops allowing
/// product use. Keeping the required outcomes together prevents a lifecycle
/// caller from closing the visible panel while accidentally leaving detached
/// work or another entry point alive.
@MainActor
public struct ProductRuntimeSuspension {
    private let cancelModelWork: () -> Void
    private let cancelAgentWork: () -> Void
    private let closeProductWindows: () -> Void
    private let removeProductEntryPoints: () -> Void
    private let presentRestrictedSettings: () -> Void

    public init(
        cancelModelWork: @escaping () -> Void,
        cancelAgentWork: @escaping () -> Void,
        closeProductWindows: @escaping () -> Void,
        removeProductEntryPoints: @escaping () -> Void,
        presentRestrictedSettings: @escaping () -> Void
    ) {
        self.cancelModelWork = cancelModelWork
        self.cancelAgentWork = cancelAgentWork
        self.closeProductWindows = closeProductWindows
        self.removeProductEntryPoints = removeProductEntryPoints
        self.presentRestrictedSettings = presentRestrictedSettings
    }

    public func execute() {
        cancelModelWork()
        cancelAgentWork()
        closeProductWindows()
        removeProductEntryPoints()
        presentRestrictedSettings()
    }
}

public enum LicenseStorageKey: String, CaseIterable, Sendable {
    case trialStart = "license.trial-start"
    case trialLastSeen = "license.trial-last-seen"
    case trialExpired = "license.trial-expired"
    case licenseKey = "license.key"
    case instanceID = "license.instance-id"
    case installID = "license.install-id"
    case validationResult = "license.validation-result"
    case lastValidation = "license.last-validation"
}

public struct LemonLicense: Equatable, Sendable {
    public let status: String
    public let expiresAt: String?

    public init(status: String, expiresAt: String?) {
        self.status = status
        self.expiresAt = expiresAt
    }

    public var isActivePerpetual: Bool { status == "active" && expiresAt == nil }
}

public struct LemonLicenseIdentity: Equatable, Sendable {
    public let storeID: Int
    public let productID: Int
    public let variantID: Int
    public let customerEmail: String

    public init(storeID: Int, productID: Int, variantID: Int, customerEmail: String) {
        self.storeID = storeID
        self.productID = productID
        self.variantID = variantID
        self.customerEmail = customerEmail
    }
}

public enum LemonActivationResult: Equatable, Sendable {
    case success(instanceID: String, license: LemonLicense, identity: LemonLicenseIdentity)
    case rejected(error: String)
}

public enum LemonValidationResult: Equatable, Sendable {
    case valid(license: LemonLicense, identity: LemonLicenseIdentity)
    case invalid(error: String)
}

public enum LemonDeactivationResult: Equatable, Sendable {
    case success(identity: LemonLicenseIdentity)
    case rejected(error: String)
}

public protocol LemonLicenseClient: Sendable {
    func activate(key: String, instanceName: String) async throws -> LemonActivationResult
    func validate(key: String, instanceID: String) async throws -> LemonValidationResult
    func deactivate(key: String, instanceID: String) async throws -> LemonDeactivationResult
}

public enum LemonLicenseClientError: LocalizedError {
    case invalidResponse
    case serverUnavailable(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "Lemon Squeezy returned an unreadable response."
        case .serverUnavailable(let status): "Lemon Squeezy is temporarily unavailable (HTTP \(status))."
        }
    }
}

/// Public License API client. It intentionally has no merchant API token: these
/// three form-encoded endpoints are designed for customer license keys.
public struct LemonSqueezyLicenseClient: LemonLicenseClient, Sendable {
    private let session: URLSession
    private let baseURL = URL(string: "https://api.lemonsqueezy.com/v1/licenses/")!

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func activate(key: String, instanceName: String) async throws -> LemonActivationResult {
        let response: Response = try await post(
            endpoint: "activate",
            fields: ["license_key": key, "instance_name": instanceName]
        )
        guard response.activated == true,
              let license = response.license,
              let instanceID = response.instance?.id,
              let identity = response.meta else {
            return .rejected(error: response.error ?? "The license could not be activated.")
        }
        return .success(instanceID: instanceID, license: license.value, identity: identity.value)
    }

    public func validate(key: String, instanceID: String) async throws -> LemonValidationResult {
        let response: Response = try await post(
            endpoint: "validate",
            fields: ["license_key": key, "instance_id": instanceID]
        )
        guard response.valid == true,
              let license = response.license,
              let identity = response.meta else {
            return .invalid(error: response.error ?? "The license is no longer valid.")
        }
        return .valid(license: license.value, identity: identity.value)
    }

    public func deactivate(key: String, instanceID: String) async throws -> LemonDeactivationResult {
        let response: Response = try await post(
            endpoint: "deactivate",
            fields: ["license_key": key, "instance_id": instanceID]
        )
        guard response.deactivated == true, let identity = response.meta else {
            return .rejected(error: response.error ?? "This Mac could not be deactivated.")
        }
        return .success(identity: identity.value)
    }

    private func post<Value: Decodable>(endpoint: String, fields: [String: String]) async throws -> Value {
        var request = URLRequest(url: baseURL.appending(path: endpoint))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = fields
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, rawResponse) = try await session.data(for: request)
        guard let response = rawResponse as? HTTPURLResponse else {
            throw LemonLicenseClientError.invalidResponse
        }
        if response.statusCode >= 500 {
            throw LemonLicenseClientError.serverUnavailable(response.statusCode)
        }
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw LemonLicenseClientError.invalidResponse
        }
    }

    private struct Response: Decodable {
        let activated: Bool?
        let valid: Bool?
        let deactivated: Bool?
        let error: String?
        let license: LicensePayload?
        let instance: Instance?
        let meta: Meta?

        enum CodingKeys: String, CodingKey {
            case activated, valid, deactivated, error, instance, meta
            case license = "license_key"
        }
    }

    private struct LicensePayload: Decodable {
        let status: String
        let expiresAt: String?
        enum CodingKeys: String, CodingKey { case status; case expiresAt = "expires_at" }
        var value: LemonLicense { LemonLicense(status: status, expiresAt: expiresAt) }
    }

    private struct Instance: Decodable { let id: String }

    private struct Meta: Decodable {
        let storeID: Int
        let productID: Int
        let variantID: Int
        let customerEmail: String
        enum CodingKeys: String, CodingKey {
            case storeID = "store_id"
            case productID = "product_id"
            case variantID = "variant_id"
            case customerEmail = "customer_email"
        }
        var value: LemonLicenseIdentity {
            LemonLicenseIdentity(
                storeID: storeID,
                productID: productID,
                variantID: variantID,
                customerEmail: customerEmail
            )
        }
    }
}

public enum LicenseServiceError: LocalizedError, Equatable {
    case missingLicenseKey
    case missingEmail
    case activationRejected(String)
    case deactivationRejected(String)
    case wrongProduct
    case emailMismatch
    case nonPerpetualLicense
    case noActivatedLicense
    case secureStorage

    public var errorDescription: String? {
        switch self {
        case .missingLicenseKey: "Enter your license key."
        case .missingEmail: "Enter the email address used at checkout."
        case .activationRejected(let message): message
        case .deactivationRejected(let message): message
        case .wrongProduct: "That key is not a NotchFlow license."
        case .emailMismatch: "The email does not match the license purchase."
        case .nonPerpetualLicense: "This is not a valid perpetual NotchFlow license."
        case .noActivatedLicense: "No license is active on this Mac."
        case .secureStorage: "NotchFlow could not securely save the license."
        }
    }
}

@MainActor
public final class LicenseService: ObservableObject {
    public nonisolated static let trialDuration: TimeInterval = 7 * 24 * 60 * 60

    /// Developer builds must remain usable before the live Lemon Squeezy
    /// product exists. This is a compile-time boundary: `DEBUG` is absent from
    /// Release builds, so a distributed app cannot receive this entitlement.
    public nonisolated static var hasLocalDevelopmentEntitlement: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    public static let shared: LicenseService = {
        do {
            return LicenseService(configuration: try .bundled(), schedulesRefresh: true)
        } catch {
            return LicenseService(configurationError: error.localizedDescription)
        }
    }()

    @Published public private(set) var state: LicenseState = .checking
    /// Emits an entitlement only after `state` has been assigned. Runtime
    /// services that must re-read `state` (such as approval bridges) observe
    /// this publisher rather than `$state`, whose `@Published` notification
    /// arrives before its backing value changes.
    @Published public private(set) var committedState: LicenseState = .checking

    private let configuration: LicensingConfiguration?
    private let configurationError: String?
    private let store: SecureValueStoring
    private let client: LemonLicenseClient
    private let now: @Sendable () -> Date
    private let makeInstallID: @Sendable () -> UUID
    private let schedulesRefresh: Bool
    private let hasLocalDevelopmentEntitlement: Bool
    private var scheduledTask: Task<Void, Never>?

    public init(
        configuration: LicensingConfiguration,
        store: SecureValueStoring = KeychainStore.shared,
        client: LemonLicenseClient = LemonSqueezyLicenseClient(),
        now: @escaping @Sendable () -> Date = { .now },
        makeInstallID: @escaping @Sendable () -> UUID = { UUID() },
        schedulesRefresh: Bool = false,
        hasLocalDevelopmentEntitlement: Bool = LicenseService.hasLocalDevelopmentEntitlement
    ) {
        self.configuration = configuration
        self.configurationError = nil
        self.store = store
        self.client = client
        self.now = now
        self.makeInstallID = makeInstallID
        self.schedulesRefresh = schedulesRefresh
        self.hasLocalDevelopmentEntitlement = hasLocalDevelopmentEntitlement
    }

    private init(configurationError: String) {
        self.configuration = nil
        self.configurationError = configurationError
        self.store = KeychainStore.shared
        self.client = LemonSqueezyLicenseClient()
        self.now = { .now }
        self.makeInstallID = { UUID() }
        self.schedulesRefresh = true
        self.hasLocalDevelopmentEntitlement = Self.hasLocalDevelopmentEntitlement
    }

    deinit { scheduledTask?.cancel() }

    public func resolveInitialState() async {
        guard !hasLocalDevelopmentEntitlement else {
            setState(.licensed)
            return
        }
        guard configuration != nil else {
            setState(.blocked(reason: .configurationUnavailable))
            return
        }
        do {
            _ = try ensureInstallID()
            _ = try ensureTrialStart()
            await resolveStoredEntitlement()
        } catch {
            setState(.blocked(reason: .secureStorageUnavailable))
        }
    }

    public func activate(key: String, email: String) async throws {
        guard let configuration else {
            throw LicenseServiceError.activationRejected(
                configurationError ?? "Licensing is not configured.")
        }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw LicenseServiceError.missingLicenseKey }
        guard !email.isEmpty else { throw LicenseServiceError.missingEmail }

        let installID: String
        do {
            installID = try ensureInstallID()
            _ = try ensureTrialStart()
        } catch {
            throw LicenseServiceError.secureStorage
        }

        let result = try await client.activate(key: key, instanceName: installID)
        switch result {
        case .rejected(let error):
            throw LicenseServiceError.activationRejected(error)
        case .success(let instanceID, let license, let identity):
            guard configuration.accepts(identity) else {
                _ = try? await client.deactivate(key: key, instanceID: instanceID)
                throw LicenseServiceError.wrongProduct
            }
            guard identity.customerEmail.compare(email, options: [.caseInsensitive]) == .orderedSame else {
                _ = try? await client.deactivate(key: key, instanceID: instanceID)
                throw LicenseServiceError.emailMismatch
            }
            guard license.isActivePerpetual else {
                _ = try? await client.deactivate(key: key, instanceID: instanceID)
                throw LicenseServiceError.nonPerpetualLicense
            }
            do {
                try storeString(instanceID, for: .instanceID)
                try storeString(installID, for: .installID)
                try storeString("valid", for: .validationResult)
                try storeDate(now(), for: .lastValidation)
                try storeString(key, for: .licenseKey)
            } catch {
                _ = try? await client.deactivate(key: key, instanceID: instanceID)
                throw LicenseServiceError.secureStorage
            }
            setState(.licensed)
        }
    }

    public func deactivateCurrentMac() async throws {
        guard let configuration else {
            throw LicenseServiceError.deactivationRejected(
                configurationError ?? "Licensing is not configured.")
        }
        guard let key = try? storedString(for: .licenseKey),
              let instanceID = try? storedString(for: .instanceID) else {
            throw LicenseServiceError.noActivatedLicense
        }

        let result = try await client.deactivate(key: key, instanceID: instanceID)
        switch result {
        case .rejected(let error):
            throw LicenseServiceError.deactivationRejected(error)
        case .success(let identity):
            guard configuration.accepts(identity) else { throw LicenseServiceError.wrongProduct }
            do {
                try store.removeValue(forKey: LicenseStorageKey.licenseKey.rawValue)
                try store.removeValue(forKey: LicenseStorageKey.instanceID.rawValue)
                try store.removeValue(forKey: LicenseStorageKey.validationResult.rawValue)
                try store.removeValue(forKey: LicenseStorageKey.lastValidation.rawValue)
            } catch {
                throw LicenseServiceError.secureStorage
            }
            setState(trialState())
        }
    }

    public func beginCheckout() -> URL? { configuration?.checkoutURL }

    public func refreshIfPossible() async {
        guard !hasLocalDevelopmentEntitlement else {
            setState(.licensed)
            return
        }
        guard configuration != nil else {
            setState(.blocked(reason: .configurationUnavailable))
            return
        }
        await resolveStoredEntitlement()
    }

    /// Used before AppKit starts the headless Grok MCP path. It never performs a
    /// network request and only trusts a locally stored, previously valid result.
    public nonisolated static func localEntitlementSnapshot(
        configuration: LicensingConfiguration?,
        store: SecureValueStoring = KeychainStore.shared,
        now: Date = .now,
        hasLocalDevelopmentEntitlement: Bool = LicenseService.hasLocalDevelopmentEntitlement
    ) -> LicenseState {
        if hasLocalDevelopmentEntitlement { return .licensed }
        guard configuration != nil else { return .blocked(reason: .configurationUnavailable) }
        do {
            let expired = try string(.trialExpired, store: store) == "true"
            let key = try string(.licenseKey, store: store)
            let instance = try string(.instanceID, store: store)
            let validation = try string(.validationResult, store: store)
            if key?.isEmpty == false, instance?.isEmpty == false {
                return validation == "valid"
                    ? .licensed
                    : .blocked(reason: .licenseInvalid)
            }
            if expired { return .blocked(reason: .trialExpired) }
            guard let start = try date(.trialStart, store: store) else {
                return .blocked(reason: .activationRequired)
            }
            let lastSeen = try date(.trialLastSeen, store: store) ?? start
            let effectiveNow = max(now, lastSeen)
            try store.set(
                JSONEncoder().encode(effectiveNow),
                forKey: LicenseStorageKey.trialLastSeen.rawValue
            )
            let state = trialState(start: start, now: effectiveNow)
            if state == .blocked(reason: .trialExpired) {
                try store.set(
                    Data("true".utf8),
                    forKey: LicenseStorageKey.trialExpired.rawValue
                )
            }
            return state
        } catch {
            return .blocked(reason: .secureStorageUnavailable)
        }
    }

    private func resolveStoredEntitlement() async {
        let key: String?
        let instanceID: String?
        let previousValidation: String?
        do {
            key = try storedString(for: .licenseKey)
            instanceID = try storedString(for: .instanceID)
            previousValidation = try storedString(for: .validationResult)
        } catch {
            setState(.blocked(reason: .secureStorageUnavailable))
            return
        }

        guard let key, let instanceID, !key.isEmpty, !instanceID.isEmpty else {
            setState(trialState())
            return
        }

        do {
            let result = try await client.validate(key: key, instanceID: instanceID)
            switch result {
            case .invalid:
                try? storeString("invalid", for: .validationResult)
                try? storeDate(now(), for: .lastValidation)
                setState(.blocked(reason: .licenseInvalid))
            case .valid(let license, let identity):
                guard configuration?.accepts(identity) == true, license.isActivePerpetual else {
                    try? storeString("invalid", for: .validationResult)
                    try? storeDate(now(), for: .lastValidation)
                    setState(.blocked(reason: .licenseInvalid))
                    return
                }
                try? storeString("valid", for: .validationResult)
                try? storeDate(now(), for: .lastValidation)
                setState(.licensed)
            }
        } catch {
            if previousValidation == "valid" {
                setState(.licensed)
            } else {
                setState(.blocked(reason: .licenseInvalid))
            }
        }
    }

    private func trialState() -> LicenseState {
        do {
            if try storedString(for: .trialExpired) == "true" {
                return .blocked(reason: .trialExpired)
            }
            guard let start = try storedDate(for: .trialStart) else {
                return .blocked(reason: .secureStorageUnavailable)
            }
            let lastSeen = try storedDate(for: .trialLastSeen) ?? start
            let effectiveNow = max(now(), lastSeen)
            try storeDate(effectiveNow, for: .trialLastSeen)
            let result = Self.trialState(start: start, now: effectiveNow)
            if result == .blocked(reason: .trialExpired) {
                try? storeString("true", for: .trialExpired)
            }
            return result
        } catch {
            return .blocked(reason: .secureStorageUnavailable)
        }
    }

    private nonisolated static func trialState(start: Date, now: Date) -> LicenseState {
        let remaining = trialDuration - max(0, now.timeIntervalSince(start))
        guard remaining > 0 else { return .blocked(reason: .trialExpired) }
        return .trial(remaining: max(1, Int(ceil(remaining / 86_400))))
    }

    private func ensureInstallID() throws -> String {
        if let existing = try storedString(for: .installID), !existing.isEmpty { return existing }
        let value = makeInstallID().uuidString
        try storeString(value, for: .installID)
        return value
    }

    private func ensureTrialStart() throws -> Date {
        if let existing = try storedDate(for: .trialStart) {
            if try storedDate(for: .trialLastSeen) == nil {
                try storeDate(existing, for: .trialLastSeen)
            }
            return existing
        }
        let value = now()
        try storeDate(value, for: .trialStart)
        try storeDate(value, for: .trialLastSeen)
        return value
    }

    private func setState(_ newState: LicenseState) {
        state = newState
        committedState = newState
        scheduledTask?.cancel()
        guard schedulesRefresh else { return }
        let delay: TimeInterval
        switch newState {
        case .trial:
            guard let start = try? storedDate(for: .trialStart) else { return }
            let lastSeen = (try? storedDate(for: .trialLastSeen)) ?? start
            delay = max(
                0,
                start.addingTimeInterval(Self.trialDuration)
                    .timeIntervalSince(max(now(), lastSeen))
            )
        case .licensed:
            delay = 24 * 60 * 60
        case .checking, .blocked:
            return
        }
        scheduledTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.refreshIfPossible()
        }
    }

    private func storedString(for key: LicenseStorageKey) throws -> String? {
        try Self.string(key, store: store)
    }

    private nonisolated static func string(
        _ key: LicenseStorageKey,
        store: SecureValueStoring
    ) throws -> String? {
        guard let data = try store.data(forKey: key.rawValue) else { return nil }
        guard let value = String(data: data, encoding: .utf8) else {
            throw LicenseServiceError.secureStorage
        }
        return value
    }

    private func storeString(_ value: String, for key: LicenseStorageKey) throws {
        try store.set(Data(value.utf8), forKey: key.rawValue)
    }

    private func storedDate(for key: LicenseStorageKey) throws -> Date? {
        try Self.date(key, store: store)
    }

    private nonisolated static func date(
        _ key: LicenseStorageKey,
        store: SecureValueStoring
    ) throws -> Date? {
        guard let data = try store.data(forKey: key.rawValue) else { return nil }
        return try JSONDecoder().decode(Date.self, from: data)
    }

    private func storeDate(_ value: Date, for key: LicenseStorageKey) throws {
        try store.set(JSONEncoder().encode(value), forKey: key.rawValue)
    }
}
