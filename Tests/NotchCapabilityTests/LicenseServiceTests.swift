import Foundation
import XCTest
import Combine
@testable import NotchCapabilities

@MainActor
final class LicenseServiceTests: XCTestCase {
    private let configuration = LicensingConfiguration(
        checkoutURL: URL(string: "https://notch.example.com/buy")!,
        storeID: 11,
        productID: 22,
        variantID: 33
    )
    private let installID = UUID(uuidString: "A9D46187-9EF9-4A72-9B35-F199A4D39BE0")!
    private let instanceID = "47596ad9-a811-4ebf-ac8a-03fc7b6d2a17"
    private let licenseKey = "38b1460a-5104-4067-a91d-77b872934d51"

    func testTrialAllowsExactlySevenTwentyFourHourPeriods() async {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let clock = MutableClock(start)
        let store = MemorySecureStore()
        let service = makeService(store: store, client: StubLemonClient(), clock: clock)

        await service.resolveInitialState()
        XCTAssertEqual(service.state, .trial(remaining: 7))

        clock.now = start.addingTimeInterval((7 * 86_400) - 1)
        await service.refreshIfPossible()
        XCTAssertEqual(service.state, .trial(remaining: 1))

        clock.now = start.addingTimeInterval(7 * 86_400)
        await service.refreshIfPossible()
        XCTAssertEqual(service.state, .blocked(reason: .trialExpired))
    }

    func testDevelopmentBuildHasALocalEntitlementWhileReleaseKeepsItsTrial() async {
        let store = MemorySecureStore()
        let service = makeService(
            store: store,
            client: StubLemonClient(),
            hasLocalDevelopmentEntitlement: LicenseService.hasLocalDevelopmentEntitlement
        )

        await service.resolveInitialState()

        #if DEBUG
        XCTAssertEqual(service.state, .licensed)
        #else
        XCTAssertEqual(service.state, .trial(remaining: 7))
        #endif
    }

    func testCommittedStatePublishesAfterTheAuthoritativeStateIsStored() async {
        let service = makeService(
            store: MemorySecureStore(),
            client: StubLemonClient(),
            hasLocalDevelopmentEntitlement: true
        )
        let committed = expectation(description: "committed entitlement")
        var observation: AnyCancellable?
        observation = service.$committedState
            .dropFirst()
            .sink { state in
                XCTAssertEqual(service.state, state)
                committed.fulfill()
            }

        await service.resolveInitialState()
        await fulfillment(of: [committed], timeout: 1)
        withExtendedLifetime(observation) {}
    }

    func testDevelopmentEntitlementSurvivesARefresh() async {
        let store = MemorySecureStore()
        let installID = installID
        let service = LicenseService(
            configuration: configuration,
            store: store,
            client: StubLemonClient(),
            makeInstallID: { installID }
        )

        await service.resolveInitialState()
        await service.refreshIfPossible()

        #if DEBUG
        XCTAssertEqual(service.state, .licensed)
        #else
        XCTAssertEqual(service.state, .trial(remaining: 7))
        #endif
    }

    func testExpiredTrialStartsBlockedAndCannotBeReopenedByClockRollback() async throws {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let clock = MutableClock(start.addingTimeInterval(8 * 86_400))
        let store = MemorySecureStore(values: [
            LicenseStorageKey.trialStart.rawValue: try JSONEncoder().encode(start)
        ])
        let service = makeService(store: store, client: StubLemonClient(), clock: clock)

        await service.resolveInitialState()
        XCTAssertEqual(service.state, .blocked(reason: .trialExpired))

        clock.now = start
        await service.refreshIfPossible()
        XCTAssertEqual(service.state, .blocked(reason: .trialExpired))
    }

    func testClockRollbackDuringTrialCannotRestoreSpentDays() async {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let clock = MutableClock(start)
        let store = MemorySecureStore()
        let service = makeService(store: store, client: StubLemonClient(), clock: clock)
        await service.resolveInitialState()

        clock.now = start.addingTimeInterval((6 * 86_400) + 1)
        await service.refreshIfPossible()
        XCTAssertEqual(service.state, .trial(remaining: 1))

        clock.now = start
        await service.refreshIfPossible()
        XCTAssertEqual(service.state, .trial(remaining: 1))
    }

    func testValidPerpetualActivationLicensesThisMac() async throws {
        let store = MemorySecureStore()
        let client = StubLemonClient()
        client.activation = .success(
            instanceID: instanceID,
            license: activePerpetualLicense(),
            identity: expectedIdentity(email: "owner@example.com")
        )
        let service = makeService(store: store, client: client)
        await service.resolveInitialState()

        try await service.activate(key: "  \(licenseKey)  ", email: " OWNER@example.com ")

        XCTAssertEqual(service.state, .licensed)
        XCTAssertEqual(store.string(for: .licenseKey), licenseKey)
        XCTAssertEqual(store.string(for: .instanceID), instanceID)
        XCTAssertEqual(store.string(for: .installID), installID.uuidString)
        XCTAssertEqual(store.string(for: .validationResult), "valid")
    }

    func testActivationRejectsLicenseForAnotherLemonProduct() async {
        let store = MemorySecureStore()
        let client = StubLemonClient()
        client.activation = .success(
            instanceID: instanceID,
            license: activePerpetualLicense(),
            identity: .init(storeID: 11, productID: 999, variantID: 33,
                            customerEmail: "owner@example.com")
        )
        let service = makeService(store: store, client: client)
        await service.resolveInitialState()

        await XCTAssertThrowsErrorAsync {
            try await service.activate(key: self.licenseKey, email: "owner@example.com")
        }

        XCTAssertEqual(service.state, .trial(remaining: 7))
        XCTAssertNil(store.string(for: .licenseKey))
        XCTAssertEqual(client.deactivationRequests.count, 1,
                       "A rejected activation must free the Lemon device slot it consumed.")
    }

    func testInvalidStoredLicenseIsBlockedAfterAuthoritativeValidation() async throws {
        let store = try activatedStore(trialStart: Date(timeIntervalSince1970: 1_000_000_000))
        let client = StubLemonClient()
        client.validation = .invalid(error: "The license key has been disabled.")
        let service = makeService(store: store, client: client)

        await service.resolveInitialState()

        XCTAssertEqual(service.state, .blocked(reason: .licenseInvalid))
        XCTAssertEqual(store.string(for: .validationResult), "invalid")
    }

    func testOfflineValidationRetainsPreviouslyActivatedPerpetualLicense() async throws {
        let store = try activatedStore()
        let client = StubLemonClient()
        client.validationError = URLError(.notConnectedToInternet)
        let service = makeService(store: store, client: client)

        await service.resolveInitialState()

        XCTAssertEqual(service.state, .licensed)
        XCTAssertEqual(store.string(for: .validationResult), "valid")
    }

    func testDeactivatingCurrentMacClearsLicenseAndReturnsExpiredTrialToBlocked() async throws {
        let oldTrial = Date(timeIntervalSince1970: 1_000_000_000)
        let store = try activatedStore(trialStart: oldTrial)
        let client = StubLemonClient()
        client.validationError = URLError(.notConnectedToInternet)
        client.deactivation = .success(identity: expectedIdentity())
        let service = makeService(store: store, client: client)
        await service.resolveInitialState()
        XCTAssertEqual(service.state, .licensed)

        try await service.deactivateCurrentMac()

        XCTAssertEqual(service.state, .blocked(reason: .trialExpired))
        XCTAssertNil(store.string(for: .licenseKey))
        XCTAssertNil(store.string(for: .instanceID))
        XCTAssertEqual(client.deactivationRequests.first?.instanceID, instanceID)
    }

    func testLocalStartupGateNeverStartsCapabilitiesWhileCheckingOrBlocked() {
        XCTAssertFalse(LicenseState.checking.allowsProductServices)
        XCTAssertFalse(LicenseState.blocked(reason: .trialExpired).allowsProductServices)
        XCTAssertTrue(LicenseState.trial(remaining: 1).allowsProductServices)
        XCTAssertTrue(LicenseState.licensed.allowsProductServices)
    }

    func testOnlyABlockedLicenseStateRequestsRestrictedSettings() {
        XCTAssertFalse(LicenseState.checking.shouldPresentRestrictedSettings)
        XCTAssertFalse(LicenseState.trial(remaining: 1).shouldPresentRestrictedSettings)
        XCTAssertFalse(LicenseState.licensed.shouldPresentRestrictedSettings)
        XCTAssertTrue(LicenseState.blocked(reason: .trialExpired).shouldPresentRestrictedSettings)
    }

    func testTrialAndBlockedStatesRestrictSettingsToAbout() {
        XCTAssertFalse(LicenseState.checking.shouldRestrictSettingsToAbout)
        XCTAssertTrue(LicenseState.trial(remaining: 1).shouldRestrictSettingsToAbout)
        XCTAssertFalse(LicenseState.licensed.shouldRestrictSettingsToAbout)
        XCTAssertTrue(LicenseState.blocked(reason: .trialExpired).shouldRestrictSettingsToAbout)
    }

    func testOnlyAnActiveTrialExposesItsRemainingDaysToTheMenu() {
        XCTAssertEqual(LicenseState.trial(remaining: 7).trialDaysRemaining, 7)
        XCTAssertNil(LicenseState.checking.trialDaysRemaining)
        XCTAssertNil(LicenseState.licensed.trialDaysRemaining)
        XCTAssertNil(LicenseState.blocked(reason: .trialExpired).trialDaysRemaining)
    }

    func testAsyncProductEffectsRequireLiveEntitlementAndUncancelledTask() {
        XCTAssertTrue(LicenseState.trial(remaining: 1)
            .allowsAsyncProductEffect(isCancelled: false))
        XCTAssertTrue(LicenseState.licensed
            .allowsAsyncProductEffect(isCancelled: false))
        XCTAssertFalse(LicenseState.licensed
            .allowsAsyncProductEffect(isCancelled: true))
        XCTAssertFalse(LicenseState.checking
            .allowsAsyncProductEffect(isCancelled: false))
        XCTAssertFalse(LicenseState.blocked(reason: .trialExpired)
            .allowsAsyncProductEffect(isCancelled: false))
    }

    func testBlockedRuntimeSuspensionExecutesEveryRequiredOutcome() {
        var outcomes: [String] = []
        let suspension = ProductRuntimeSuspension(
            cancelModelWork: { outcomes.append("model") },
            cancelAgentWork: { outcomes.append("agent") },
            closeProductWindows: { outcomes.append("windows") },
            removeProductEntryPoints: { outcomes.append("entry-points") },
            presentRestrictedSettings: { outcomes.append("restricted-settings") }
        )

        suspension.execute()

        XCTAssertEqual(outcomes, [
            "model", "agent", "windows", "entry-points", "restricted-settings"
        ], "Restricted Settings must be presented last so the window teardown cannot close it.")
    }

    func testHeadlessSnapshotPersistsExpiryBeforeRefusingProductService() throws {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let store = MemorySecureStore(values: [
            LicenseStorageKey.trialStart.rawValue: try JSONEncoder().encode(start)
        ])

        let state = LicenseService.localEntitlementSnapshot(
            configuration: configuration,
            store: store,
            now: start.addingTimeInterval(7 * 86_400),
            hasLocalDevelopmentEntitlement: false
        )

        XCTAssertEqual(state, .blocked(reason: .trialExpired))
        XCTAssertEqual(store.string(for: .trialExpired), "true",
                       "Clock rollback must not reopen an expired headless entitlement.")
    }

    func testLegacySecretIsDeletedOnlyAfterSuccessfulKeychainWrite() throws {
        let legacy = MemoryLegacyStore(values: ["api_key.openrouter": "sk-old"])
        let secure = MemorySecureStore()

        let migrated = try SecureValueMigration.value(
            forKey: "api_key.openrouter", legacy: legacy, secure: secure)

        XCTAssertEqual(migrated, "sk-old")
        XCTAssertEqual(secure.rawString(forKey: "api_key.openrouter"), "sk-old")
        XCTAssertNil(legacy.string(forKey: "api_key.openrouter"))
    }

    func testFailedKeychainWriteLeavesLegacySecretIntact() {
        let legacy = MemoryLegacyStore(values: ["aux_key.exa": "exa-old"])
        let secure = MemorySecureStore()
        secure.writeError = TestError.writeFailed

        XCTAssertThrowsError(try SecureValueMigration.value(
            forKey: "aux_key.exa", legacy: legacy, secure: secure))
        XCTAssertEqual(legacy.string(forKey: "aux_key.exa"), "exa-old")
    }

    func testLicensingConfigurationRejectsMissingIdentityAndNonHTTPSCheckout() throws {
        let valid = Data("""
        {"licensing":{"checkoutURL":"https://notch.example.com/buy","storeID":11,"productID":22,"variantID":33}}
        """.utf8)
        XCTAssertEqual(try LicensingConfiguration.load(from: valid), configuration)

        XCTAssertThrowsError(try LicensingConfiguration.load(from: Data("""
        {"licensing":{"checkoutURL":"http://notch.example.com/buy","storeID":11,"productID":22,"variantID":33}}
        """.utf8)))
        XCTAssertThrowsError(try LicensingConfiguration.load(from: Data("""
        {"licensing":{"checkoutURL":"https://notch.example.com/buy","storeID":0,"productID":22,"variantID":33}}
        """.utf8)))
    }

    private func makeService(
        store: MemorySecureStore,
        client: StubLemonClient,
        clock: MutableClock = MutableClock(Date(timeIntervalSince1970: 2_000_000_000)),
        hasLocalDevelopmentEntitlement: Bool = false
    ) -> LicenseService {
        let installID = installID
        return LicenseService(
            configuration: configuration,
            store: store,
            client: client,
            now: { clock.now },
            makeInstallID: { installID },
            hasLocalDevelopmentEntitlement: hasLocalDevelopmentEntitlement
        )
    }

    private func activatedStore(trialStart: Date = Date(timeIntervalSince1970: 1_999_999_000)) throws -> MemorySecureStore {
        MemorySecureStore(values: [
            LicenseStorageKey.trialStart.rawValue: try JSONEncoder().encode(trialStart),
            LicenseStorageKey.licenseKey.rawValue: Data(licenseKey.utf8),
            LicenseStorageKey.instanceID.rawValue: Data(instanceID.utf8),
            LicenseStorageKey.installID.rawValue: Data(installID.uuidString.utf8),
            LicenseStorageKey.validationResult.rawValue: Data("valid".utf8)
        ])
    }

    private func activePerpetualLicense() -> LemonLicense {
        LemonLicense(status: "active", expiresAt: nil)
    }

    private func expectedIdentity(email: String = "owner@example.com") -> LemonLicenseIdentity {
        LemonLicenseIdentity(storeID: 11, productID: 22, variantID: 33, customerEmail: email)
    }
}

private final class MutableClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

private enum TestError: Error { case writeFailed }

private final class MemorySecureStore: SecureValueStoring, @unchecked Sendable {
    private var values: [String: Data]
    var writeError: Error?

    init(values: [String: Data] = [:]) { self.values = values }

    func data(forKey key: String) throws -> Data? { values[key] }

    func set(_ data: Data, forKey key: String) throws {
        if let writeError { throw writeError }
        values[key] = data
    }

    func removeValue(forKey key: String) throws { values.removeValue(forKey: key) }

    func rawString(forKey key: String) -> String? {
        values[key].map { String(decoding: $0, as: UTF8.self) }
    }

    func string(for key: LicenseStorageKey) -> String? { rawString(forKey: key.rawValue) }
}

private final class MemoryLegacyStore: LegacyValueStoring {
    private var values: [String: String]
    init(values: [String: String]) { self.values = values }
    func string(forKey key: String) -> String? { values[key] }
    func removeValue(forKey key: String) { values.removeValue(forKey: key) }
}

private final class StubLemonClient: LemonLicenseClient, @unchecked Sendable {
    struct DeactivationRequest: Equatable { let key: String; let instanceID: String }

    var activation: LemonActivationResult = .rejected(error: "Not configured")
    var validation: LemonValidationResult = .invalid(error: "Not configured")
    var deactivation: LemonDeactivationResult = .rejected(error: "Not configured")
    var validationError: Error?
    var deactivationRequests: [DeactivationRequest] = []

    func activate(key: String, instanceName: String) async throws -> LemonActivationResult {
        activation
    }

    func validate(key: String, instanceID: String) async throws -> LemonValidationResult {
        if let validationError { throw validationError }
        return validation
    }

    func deactivate(key: String, instanceID: String) async throws -> LemonDeactivationResult {
        deactivationRequests.append(.init(key: key, instanceID: instanceID))
        return deactivation
    }
}

@MainActor
private func XCTAssertThrowsErrorAsync(
    _ expression: @MainActor () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch { }
}
