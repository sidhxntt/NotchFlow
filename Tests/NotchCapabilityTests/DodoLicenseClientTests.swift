import Foundation
import XCTest
@testable import NotchCapabilities

final class DodoLicenseClientTests: XCTestCase {
    private let base = URL(string: "https://test.dodopayments.com/")!

    override func tearDown() {
        StubURLProtocol.respond = nil
        StubURLProtocol.lastRequest = nil
        super.tearDown()
    }

    func testActivationPostsJSONAndReadsInstanceProductAndEmail() async throws {
        StubURLProtocol.respond = { _ in (201, """
            {"id":"lki_123","business_id":"bus_1","name":"install","license_key_id":"lic_1",
             "created_at":"2026-11-22T00:00:00Z","product":{"product_id":"pdt_notchflow","name":"NotchFlow"},
             "customer":{"customer_id":"cus_1","name":"Owner","email":"owner@example.com"}}
            """) }

        let result = try await client().activate(key: "KEY-1", instanceName: "install-id")

        XCTAssertEqual(result, .success(instanceID: "lki_123",
                                        identity: LicenseIdentity(productID: "pdt_notchflow",
                                                                  customerEmail: "owner@example.com")))
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://test.dodopayments.com/licenses/activate")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "The app must not send an API key.")
        XCTAssertEqual(StubURLProtocol.lastBody, ["license_key": "KEY-1", "name": "install-id"])
    }

    func testActivationRejectionsNameTheReason() async throws {
        for (status, phrase) in [(403, "not active"), (404, "does not exist"), (422, "Deactivate it")] {
            StubURLProtocol.respond = { _ in (status, #"{"code":"X","message":"server text"}"#) }
            let result = try await client().activate(key: "KEY", instanceName: "i")
            guard case .rejected(let message) = result else { return XCTFail("\(status) should reject") }
            XCTAssertTrue(message.contains(phrase), "\(status): \(message)")
        }
    }

    func testOutagesAndRateLimitsThrowInsteadOfRejecting() async {
        for status in [429, 500, 503] {
            StubURLProtocol.respond = { _ in (status, "{}") }
            do {
                _ = try await client().validate(key: "KEY", instanceID: "lki_1")
                XCTFail("\(status) must throw so a cached valid license is kept")
            } catch { }
        }
    }

    func testValidationSendsTheInstanceAndReadsValid() async throws {
        StubURLProtocol.respond = { _ in (200, #"{"valid":true}"#) }
        let valid = try await client().validate(key: "KEY", instanceID: "lki_9")
        XCTAssertEqual(valid, .valid)
        XCTAssertEqual(StubURLProtocol.lastBody, ["license_key": "KEY", "license_key_instance_id": "lki_9"])

        StubURLProtocol.respond = { _ in (200, #"{"valid":false}"#) }
        guard case .invalid = try await client().validate(key: "KEY", instanceID: "lki_9") else {
            return XCTFail("valid:false must be invalid")
        }
    }

    func testDeactivationSucceedsOnOKAndRejectsOtherwise() async throws {
        StubURLProtocol.respond = { _ in (200, "") }
        let ok = try await client().deactivate(key: "KEY", instanceID: "lki_9")
        XCTAssertEqual(ok, .success)
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/licenses/deactivate")

        StubURLProtocol.respond = { _ in (403, #"{"message":"Instance not found"}"#) }
        let rejected = try await client().deactivate(key: "KEY", instanceID: "lki_9")
        XCTAssertEqual(rejected, .rejected(error: "Instance not found"))
    }

    private func client() -> DodoLicenseClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return DodoLicenseClient(baseURL: base, session: URLSession(configuration: configuration))
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var respond: ((URLRequest) -> (Int, String))?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: [String: String]?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        // URLSession hands a protocol the body as a stream, not httpBody.
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            Self.lastBody = try? JSONDecoder().decode([String: String].self, from: data)
        }
        let (status, body) = Self.respond?(request) ?? (500, "")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
