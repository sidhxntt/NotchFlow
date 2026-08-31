import Foundation

/// Removes attribution identifiers locally while retaining every other part of
/// a URL, including its fragment and meaningful query parameters.
public enum URLCleaningService {
    public static let standardTrackingParameters: Set<String> = [
        "fbclid", "gclid", "dclid", "msclkid", "mc_cid", "mc_eid", "igshid",
        "ref", "ref_", "source", "campaign", "affiliate", "aff_id"
    ]

    public static func clean(_ value: String, customParameters: Set<String> = []) -> String {
        guard var components = URLComponents(string: value), components.scheme != nil,
              components.host != nil, let queryItems = components.queryItems else { return value }
        let custom = Set(customParameters.map { $0.lowercased() })
        let kept = queryItems.filter { item in
            let name = item.name.lowercased()
            return !name.hasPrefix("utm_") && !standardTrackingParameters.contains(name) && !custom.contains(name)
        }
        components.queryItems = kept.isEmpty ? nil : kept
        return components.string ?? value
    }
}
