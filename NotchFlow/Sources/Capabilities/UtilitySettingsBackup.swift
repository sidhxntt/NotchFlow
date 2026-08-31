import Foundation

public enum UtilitySettingValue: Equatable, Codable, Sendable {
    case bool(Bool), int(Int), string(String), double(Double)
}

/// Codable, portable subset of utility settings. Secrets and filesystem-bound
/// values are excluded by name before export rather than relying on callers.
public enum UtilitySettingsBackup {
    public struct Payload: Codable, Equatable, Sendable {
        public let version: Int
        public let settings: [String: UtilitySettingValue]
        public init(version: Int, settings: [String: UtilitySettingValue]) {
            self.version = version
            self.settings = settings
        }
    }

    public enum Error: Swift.Error, Equatable { case unsupportedVersion }

    private static let excludedFragments = ["key", "token", "secret", "password", "path", "folder", "directory"]

    public static func makePayload(version: Int, settings: [String: UtilitySettingValue]) -> Payload {
        Payload(version: version, settings: settings.filter { key, _ in
            !excludedFragments.contains { key.localizedCaseInsensitiveContains($0) }
        })
    }

    public static func encode(_ payload: Payload) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(payload)
    }

    public static func decode(_ data: Data, supportedVersion: Int) throws -> Payload {
        let payload = try PropertyListDecoder().decode(Payload.self, from: data)
        guard payload.version <= supportedVersion else { throw Error.unsupportedVersion }
        return Payload(version: payload.version, settings: makePayload(version: payload.version, settings: payload.settings).settings)
    }
}
