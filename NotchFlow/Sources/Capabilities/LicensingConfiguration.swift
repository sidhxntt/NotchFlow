import Foundation

public struct LicensingConfiguration: Equatable, Sendable {
    /// Which Dodo Payments mode the product lives in. Test and live have their
    /// own hosts, products and keys; nothing crosses between them.
    public enum Environment: String, Decodable, Equatable, Sendable {
        case test
        case live

        public var apiBaseURL: URL {
            switch self {
            case .test: URL(string: "https://test.dodopayments.com/")!
            case .live: URL(string: "https://live.dodopayments.com/")!
            }
        }
    }

    public let checkoutURL: URL
    public let productID: String
    public let environment: Environment

    public init(checkoutURL: URL, productID: String, environment: Environment) {
        self.checkoutURL = checkoutURL
        self.productID = productID
        self.environment = environment
    }

    public static func load(from data: Data) throws -> Self {
        let input = try JSONDecoder().decode(Input.self, from: data)
        guard let url = URL(string: input.licensing.checkoutURL),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false else {
            throw LicensingConfigurationError.invalidCheckoutURL
        }
        let productID = input.licensing.productID.trimmingCharacters(in: .whitespaces)
        guard productID.hasPrefix("pdt_"), productID.count > 4 else {
            throw LicensingConfigurationError.invalidProductID
        }
        return Self(checkoutURL: url, productID: productID, environment: input.licensing.environment)
    }

    public static func bundled(in bundle: Bundle = .main) throws -> Self {
        guard let url = bundle.url(forResource: "input", withExtension: "json") else {
            throw LicensingConfigurationError.missingResource
        }
        return try load(from: Data(contentsOf: url))
    }

    public func accepts(_ identity: LicenseIdentity) -> Bool {
        identity.productID == productID
    }

    private struct Input: Decodable {
        let licensing: Licensing

        struct Licensing: Decodable {
            let checkoutURL: String
            let productID: String
            let environment: Environment
        }
    }
}

public enum LicensingConfigurationError: LocalizedError, Equatable {
    case missingResource
    case invalidCheckoutURL
    case invalidProductID

    public var errorDescription: String? {
        switch self {
        case .missingResource:
            return "The bundled licensing configuration is missing."
        case .invalidCheckoutURL:
            return "The Dodo Payments checkout URL must be a valid HTTPS URL."
        case .invalidProductID:
            return "The Dodo Payments product ID must start with pdt_."
        }
    }
}
