import Foundation

/// The identity and destinations shown in Settings → About, supplied by the
/// bundled `input.json` file. The installed version remains build-derived.
public struct AboutContentConfiguration: Codable, Equatable, Sendable {
    public let name: String
    public let tagline: String
    public let website: String
    public let aboutMeURL: String
    public let xURL: String
    public let privacyURL: String
    public let feedbackURL: String

    public static let `default` = AboutContentConfiguration(
        name: "NotchFlow",
        tagline: "Your menu-bar AI workspace",
        website: "https://notchflow.netlify.app/",
        aboutMeURL: "https://sidhxntt.dev/",
        xURL: "https://x.com/sidhxntt",
        privacyURL: "https://sidhxntt.github.io/NotchFlow/privacy/",
        feedbackURL: "mailto:siddhantg2002@gmail.com"
    )

    public init(name: String, tagline: String, website: String, aboutMeURL: String,
                xURL: String, privacyURL: String, feedbackURL: String) {
        self.name = name
        self.tagline = tagline
        self.website = website
        self.aboutMeURL = aboutMeURL
        self.xURL = xURL
        self.privacyURL = privacyURL
        self.feedbackURL = feedbackURL
    }

    public init(json: String) throws {
        let decoded = try JSONDecoder().decode(Self.self, from: Data(json.utf8))
        try decoded.validate()
        self = decoded
    }

    public static func load(from data: Data) throws -> Self {
        try Self(json: String(decoding: data, as: UTF8.self))
    }

    /// A malformed or absent resource must never prevent Settings from opening.
    /// The default is only a safe fallback; project edits belong in input.json.
    public static func bundled(in bundle: Bundle = .main) -> Self {
        guard let url = bundle.url(forResource: "input", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let configuration = try? load(from: data) else {
            return .default
        }
        return configuration
    }

    private func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AboutContentConfigurationError.emptyName
        }
        guard !tagline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AboutContentConfigurationError.emptyTagline
        }
        try validateURL(website, field: "website", required: true)
        try validateURL(aboutMeURL, field: "aboutMeURL", required: false)
        try validateURL(xURL, field: "xURL", required: false)
        try validateURL(privacyURL, field: "privacyURL", required: false)
        try validateURL(feedbackURL, field: "feedbackURL", required: false, allowsMail: true)
    }

    /// Web links only, except where `allowsMail` lets a field be a `mailto:`
    /// address instead (Feedback can open a new email).
    private func validateURL(_ string: String, field: String, required: Bool, allowsMail: Bool = false) throws {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if required { throw AboutContentConfigurationError.missingURL(field) }
            return
        }
        if allowsMail, let url = URL(string: trimmed), url.scheme?.lowercased() == "mailto" {
            guard url.absoluteString.dropFirst("mailto:".count).contains("@") else {
                throw AboutContentConfigurationError.invalidURL(field)
            }
            return
        }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else {
            throw AboutContentConfigurationError.invalidURL(field)
        }
    }
}

public enum AboutContentConfigurationError: LocalizedError, Equatable {
    case emptyName
    case emptyTagline
    case missingURL(String)
    case invalidURL(String)

    public var errorDescription: String? {
        switch self {
        case .emptyName: return "name cannot be empty."
        case .emptyTagline: return "tagline cannot be empty."
        case .missingURL(let field): return "\(field) is required."
        case .invalidURL(let field): return "\(field) must be an http or https URL."
        }
    }
}
