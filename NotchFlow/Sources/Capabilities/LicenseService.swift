import Combine
import CryptoKit
import Foundation
import IOKit

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

    /// The trial is the full app, Settings included: a trial user has to be
    /// able to add a key, grant permissions and set the app up to judge it. Only
    /// an expired trial or an invalid license narrows Settings to About, where
    /// the license card and updates live.
    public var shouldRestrictSettingsToAbout: Bool {
        if case .blocked = self { return true }
        return false
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

/// Who a license key belongs to, as the payment provider reports it when the
/// key is activated.
public struct LicenseIdentity: Equatable, Sendable {
    public let productID: String
    public let customerEmail: String

    public init(productID: String, customerEmail: String) {
        self.productID = productID
        self.customerEmail = customerEmail
    }
}

public enum LicenseActivationResult: Equatable, Sendable {
    case success(instanceID: String, identity: LicenseIdentity)
    case rejected(error: String)
}

public enum LicenseValidationResult: Equatable, Sendable {
    case valid
    case invalid(error: String)
}

public enum LicenseDeactivationResult: Equatable, Sendable {
    case success
    case rejected(error: String)
}

public protocol LicenseClient: Sendable {
    func activate(key: String, instanceName: String) async throws -> LicenseActivationResult
    func validate(key: String, instanceID: String) async throws -> LicenseValidationResult
    func deactivate(key: String, instanceID: String) async throws -> LicenseDeactivationResult
}

/// Thrown, rather than returned as a rejection, when Dodo could not give an
/// answer. Callers keep a previously valid license in that case instead of
/// locking a paying customer out over an outage or a rate limit.
public enum LicenseClientError: LocalizedError {
    case invalidResponse
    case serverUnavailable(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "Dodo Payments returned an unreadable response."
        case .serverUnavailable(let status): "Dodo Payments is temporarily unavailable (HTTP \(status))."
        }
    }
}

/// Dodo Payments' public license endpoints. They take no API key by design, so
/// the app ships no merchant credential: activation only needs the customer's
/// own key.
public struct DodoLicenseClient: LicenseClient, Sendable {
    private let session: URLSession
    private let baseURL: URL

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func activate(key: String, instanceName: String) async throws -> LicenseActivationResult {
        let (status, data) = try await post("licenses/activate", ["license_key": key, "name": instanceName])
        switch status {
        case 200...299:
            guard let response = try? JSONDecoder().decode(Activation.self, from: data) else {
                throw LicenseClientError.invalidResponse
            }
            return .success(
                instanceID: response.id,
                identity: LicenseIdentity(productID: response.product?.productID ?? "",
                                          customerEmail: response.customer.email)
            )
        case 403: return .rejected(error: "This license key is not active.")
        case 404: return .rejected(error: "That license key does not exist.")
        case 422: return .rejected(error: "This license is already in use on as many Macs as it allows. Deactivate it on one of them first.")
        default: return .rejected(error: Self.message(in: data) ?? "The license could not be activated.")
        }
    }

    public func validate(key: String, instanceID: String) async throws -> LicenseValidationResult {
        let (status, data) = try await post(
            "licenses/validate", ["license_key": key, "license_key_instance_id": instanceID])
        guard (200...299).contains(status) else {
            return .invalid(error: Self.message(in: data) ?? "The license is no longer valid.")
        }
        guard let response = try? JSONDecoder().decode(Validation.self, from: data) else {
            throw LicenseClientError.invalidResponse
        }
        return response.valid ? .valid : .invalid(error: "The license is no longer valid.")
    }

    public func deactivate(key: String, instanceID: String) async throws -> LicenseDeactivationResult {
        let (status, data) = try await post(
            "licenses/deactivate", ["license_key": key, "license_key_instance_id": instanceID])
        guard (200...299).contains(status) else {
            return .rejected(error: Self.message(in: data) ?? "This Mac could not be deactivated.")
        }
        return .success
    }

    /// The HTTP status and body. 5xx and 429 are thrown: they say nothing
    /// about the key itself.
    private func post(_ endpoint: String, _ body: [String: String]) async throws -> (Int, Data) {
        var request = URLRequest(url: baseURL.appending(path: endpoint))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, rawResponse) = try await session.data(for: request)
        guard let response = rawResponse as? HTTPURLResponse else {
            throw LicenseClientError.invalidResponse
        }
        if response.statusCode >= 500 || response.statusCode == 429 {
            throw LicenseClientError.serverUnavailable(response.statusCode)
        }
        return (response.statusCode, data)
    }

    private static func message(in data: Data) -> String? {
        (try? JSONDecoder().decode(ErrorBody.self, from: data))?.message
    }

    private struct Activation: Decodable {
        let id: String
        let product: Product?
        let customer: Customer

        struct Product: Decodable {
            let productID: String
            enum CodingKeys: String, CodingKey { case productID = "product_id" }
        }
        struct Customer: Decodable { let email: String }
    }

    private struct Validation: Decodable { let valid: Bool }
    private struct ErrorBody: Decodable { let message: String? }
}

public enum LicenseServiceError: LocalizedError, Equatable {
    case missingLicenseKey
    case missingEmail
    case activationRejected(String)
    case deactivationRejected(String)
    case wrongProduct
    case emailMismatch
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
        case .noActivatedLicense: "No license is active on this Mac."
        case .secureStorage: "NotchFlow could not securely save the license."
        }
    }
}

@MainActor
public final class LicenseService: ObservableObject {
    public nonisolated static let trialDuration: TimeInterval = 7 * 24 * 60 * 60

    /// Developer builds must remain usable before the live Dodo Payments
    /// product exists. This is a compile-time boundary: `DEBUG` is absent from
    /// Release builds, so a distributed app cannot receive this entitlement.
    public nonisolated static var hasLocalDevelopmentEntitlement: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// The developer's own Macs are licensed in every build, Release included,
    /// so the app they ship never locks them out. Each entry is the SHA-256 of
    /// `ownerSalt` plus the Mac's IOPlatformUUID; the hardware ID itself is not
    /// in the source. Add a Mac with:
    /// `printf 'NotchFlow.owner.v1:%s' "$(ioreg -rd1 -c IOPlatformExpertDevice | awk -F'"' '/IOPlatformUUID/{print toupper($4)}')" | shasum -a 256`
    public nonisolated static let ownerMachineDigests: Set<String> = [
        "7d7f0dc74b2df3b4213b31865b7cbb42946b97a1b55405e25495f3d03d551945",
    ]
    private nonisolated static let ownerSalt = "NotchFlow.owner.v1:"

    public nonisolated static func ownerDigest(forPlatformUUID uuid: String) -> String {
        SHA256.hash(data: Data((ownerSalt + uuid.uppercased()).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    public nonisolated static func isOwnerMachine(platformUUID: String?,
                                                  ownerDigests: Set<String> = ownerMachineDigests) -> Bool {
        guard let platformUUID, !platformUUID.isEmpty else { return false }
        return ownerDigests.contains(ownerDigest(forPlatformUUID: platformUUID))
    }

    /// Whether this Mac is one of the developer's. Read once: the hardware ID
    /// can't change while the app runs.
    public nonisolated static let isOwnerMachine: Bool = isOwnerMachine(platformUUID: platformUUID())

    private nonisolated static func platformUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }

    public static let shared: LicenseService = {
        do {
            #if NOTCHFLOW_CUSTOMER_SIMULATION
            return CustomerSimulation.service(configuration: try .bundled())
            #else
            return LicenseService(configuration: try .bundled(), schedulesRefresh: true)
            #endif
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
    private let client: LicenseClient
    private let now: @Sendable () -> Date
    private let makeInstallID: @Sendable () -> UUID
    private let schedulesRefresh: Bool
    private let hasLocalDevelopmentEntitlement: Bool
    private var scheduledTask: Task<Void, Never>?

    public init(
        configuration: LicensingConfiguration,
        store: SecureValueStoring = KeychainStore.shared,
        client: LicenseClient? = nil,
        now: @escaping @Sendable () -> Date = { .now },
        makeInstallID: @escaping @Sendable () -> UUID = { UUID() },
        schedulesRefresh: Bool = false,
        hasLocalDevelopmentEntitlement: Bool = LicenseService.hasLocalDevelopmentEntitlement
            || LicenseService.isOwnerMachine
    ) {
        self.configuration = configuration
        self.configurationError = nil
        self.store = store
        self.client = client ?? DodoLicenseClient(baseURL: configuration.environment.apiBaseURL)
        self.now = now
        self.makeInstallID = makeInstallID
        self.schedulesRefresh = schedulesRefresh
        self.hasLocalDevelopmentEntitlement = hasLocalDevelopmentEntitlement
    }

    private init(configurationError: String) {
        self.configuration = nil
        self.configurationError = configurationError
        self.store = KeychainStore.shared
        self.client = DodoLicenseClient(baseURL: LicensingConfiguration.Environment.live.apiBaseURL)
        self.now = { .now }
        self.makeInstallID = { UUID() }
        self.schedulesRefresh = true
        self.hasLocalDevelopmentEntitlement = Self.hasLocalDevelopmentEntitlement || Self.isOwnerMachine
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
        case .success(let instanceID, let identity):
            guard configuration.accepts(identity) else {
                _ = try? await client.deactivate(key: key, instanceID: instanceID)
                throw LicenseServiceError.wrongProduct
            }
            guard identity.customerEmail.compare(email, options: [.caseInsensitive]) == .orderedSame else {
                _ = try? await client.deactivate(key: key, instanceID: instanceID)
                throw LicenseServiceError.emailMismatch
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

    /// Whether this Mac holds an activated license key, as opposed to being
    /// licensed by the developer or owner entitlement, which has nothing to
    /// deactivate.
    public var hasActivatedLicense: Bool {
        guard let key = try? storedString(for: .licenseKey),
              let instance = try? storedString(for: .instanceID) else { return false }
        return !key.isEmpty && !instance.isEmpty
    }

    public func deactivateCurrentMac() async throws {
        guard configuration != nil else {
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
        case .success:
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
            case .valid:
                // Dodo validates the key and this Mac's activation together;
                // the product and email were checked when it was activated.
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

#if NOTCHFLOW_CUSTOMER_SIMULATION
/// `make install-release-customer`: the Release app as a customer would run it,
/// on the developer's own Mac. Only that target sets this compile flag, so no
/// shipped build contains any of it.
///
/// - The owner unlock is off.
/// - Trial records live under their own Keychain service, so the real ones are
///   never touched and the simulation can be reset by deleting that service.
/// - `defaults write com.notchflow.app simulation.trialDaysElapsed -float 8`
///   moves the license clock forward to test the end of the trial.
/// - Every state it reaches is appended to `license-simulation.log` in
///   NotchFlow's Application Support folder, so a run can be checked without
///   reading the UI.
@MainActor
enum CustomerSimulation {
    private static var stateLog: AnyCancellable?

    static func service(configuration: LicensingConfiguration) -> LicenseService {
        let days = UserDefaults.standard.double(forKey: "simulation.trialDaysElapsed")
        let service = LicenseService(
            configuration: configuration,
            store: KeychainStore(service: "com.notchflow.app.secure.simulation"),
            now: { Date().addingTimeInterval(days * 86_400) },
            schedulesRefresh: true,
            hasLocalDevelopmentEntitlement: false
        )
        stateLog = service.$committedState.sink { state in
            guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("NotchFlow", isDirectory: true) else { return }
            let url = dir.appendingPathComponent("license-simulation.log")
            let line = "\(Date()) days+\(days) \(state)\n"
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
        return service
    }
}
#endif
