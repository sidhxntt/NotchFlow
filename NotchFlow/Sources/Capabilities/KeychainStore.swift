import Foundation
import Security

/// The small storage boundary used by licensing and API-key migration. Tests use
/// an in-memory implementation; the application uses `KeychainStore`.
public protocol SecureValueStoring: Sendable {
    func data(forKey key: String) throws -> Data?
    func set(_ data: Data, forKey key: String) throws
    func removeValue(forKey key: String) throws
}

public enum KeychainStoreError: LocalizedError, Equatable {
    case unexpectedStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
            return "Keychain operation failed (\(status)): \(message)"
        }
    }
}

/// Generic-password storage scoped to NotchFlow's bundle. No access group or
/// merchant credential is used, so the values remain private to the signed app.
public struct KeychainStore: SecureValueStoring, Sendable {
    public static let shared = KeychainStore(service: "com.notchflow.app.secure")

    private let service: String

    public init(service: String) {
        self.service = service
    }

    public func data(forKey key: String) throws -> Data? {
        var query = baseQuery(forKey: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainStoreError.unexpectedStatus(status) }
        guard let data = result as? Data else {
            throw KeychainStoreError.unexpectedStatus(errSecInternalError)
        }
        return data
    }

    public func set(_ data: Data, forKey key: String) throws {
        let query = baseQuery(forKey: key)
        let update = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainStoreError.unexpectedStatus(addStatus)
            }
            return
        }

        guard updateStatus == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(updateStatus)
        }
    }

    public func removeValue(forKey key: String) throws {
        let status = SecItemDelete(baseQuery(forKey: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery(forKey key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecUseDataProtectionKeychain as String: true
        ]
    }
}

public protocol LegacyValueStoring: AnyObject {
    func string(forKey key: String) -> String?
    func removeValue(forKey key: String)
}

extension UserDefaults: LegacyValueStoring {
    public func removeValue(forKey key: String) {
        removeObject(forKey: key)
    }
}

/// Moves a legacy string only after the secure write succeeds. A failed write
/// deliberately leaves the old value untouched so an upgrade cannot lose a key.
public enum SecureValueMigration {
    public static func value(
        forKey key: String,
        legacy: LegacyValueStoring,
        secure: SecureValueStoring
    ) throws -> String? {
        if let data = try secure.data(forKey: key) {
            guard let value = String(data: data, encoding: .utf8) else {
                throw KeychainStoreError.unexpectedStatus(errSecDecode)
            }
            legacy.removeValue(forKey: key)
            return value
        }
        guard let legacyValue = legacy.string(forKey: key) else { return nil }
        try secure.set(Data(legacyValue.utf8), forKey: key)
        legacy.removeValue(forKey: key)
        return legacyValue
    }
}
