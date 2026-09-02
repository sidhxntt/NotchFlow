import Foundation

public struct LicensingConfiguration: Equatable, Sendable {
    public let checkoutURL: URL
    public let storeID: Int
    public let productID: Int
    public let variantID: Int

    public init(checkoutURL: URL, storeID: Int, productID: Int, variantID: Int) {
        self.checkoutURL = checkoutURL
        self.storeID = storeID
        self.productID = productID
        self.variantID = variantID
    }

    public static func load(from data: Data) throws -> Self {
        let input = try JSONDecoder().decode(Input.self, from: data)
        guard let url = URL(string: input.licensing.checkoutURL),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false else {
            throw LicensingConfigurationError.invalidCheckoutURL
        }
        guard input.licensing.storeID > 0 else {
            throw LicensingConfigurationError.missingIdentifier("storeID")
        }
        guard input.licensing.productID > 0 else {
            throw LicensingConfigurationError.missingIdentifier("productID")
        }
        guard input.licensing.variantID > 0 else {
            throw LicensingConfigurationError.missingIdentifier("variantID")
        }
        return Self(
            checkoutURL: url,
            storeID: input.licensing.storeID,
            productID: input.licensing.productID,
            variantID: input.licensing.variantID
        )
    }

    public static func bundled(in bundle: Bundle = .main) throws -> Self {
        guard let url = bundle.url(forResource: "input", withExtension: "json") else {
            throw LicensingConfigurationError.missingResource
        }
        return try load(from: Data(contentsOf: url))
    }

    public func accepts(_ identity: LemonLicenseIdentity) -> Bool {
        identity.storeID == storeID
            && identity.productID == productID
            && identity.variantID == variantID
    }

    private struct Input: Decodable {
        let licensing: Licensing

        struct Licensing: Decodable {
            let checkoutURL: String
            let storeID: Int
            let productID: Int
            let variantID: Int
        }
    }
}

public enum LicensingConfigurationError: LocalizedError, Equatable {
    case missingResource
    case invalidCheckoutURL
    case missingIdentifier(String)

    public var errorDescription: String? {
        switch self {
        case .missingResource:
            return "The bundled licensing configuration is missing."
        case .invalidCheckoutURL:
            return "The Lemon Squeezy checkout URL must be a valid HTTPS URL."
        case .missingIdentifier(let name):
            return "The Lemon Squeezy \(name) must be greater than zero."
        }
    }
}
