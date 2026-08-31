import XCTest
@testable import NotchCapabilities

final class URLCleaningServiceTests: XCTestCase {
    func testRemovesKnownTrackingParametersButKeepsUsefulQuery() {
        let value = URLCleaningService.clean("https://example.com/p?a=1&utm_source=mail&fbclid=abc")
        XCTAssertEqual(value, "https://example.com/p?a=1")
    }

    func testRemovesCustomParametersCaseInsensitively() {
        let value = URLCleaningService.clean("https://example.com/?Referral=one&ok=yes", customParameters: ["referral"])
        XCTAssertEqual(value, "https://example.com/?ok=yes")
    }

    func testLeavesNonURLAndFragmentUntouched() {
        XCTAssertEqual(URLCleaningService.clean("not a url"), "not a url")
        XCTAssertEqual(URLCleaningService.clean("https://example.com/p?utm_medium=x#section"),
                       "https://example.com/p#section")
    }
}
