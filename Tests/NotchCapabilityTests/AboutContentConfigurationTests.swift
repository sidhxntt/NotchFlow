import XCTest
@testable import NotchCapabilities

final class AboutContentConfigurationTests: XCTestCase {
    func testInputJSONFileSuppliesTheAboutContent() throws {
        let inputURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "NotchFlow/Resources/input.json")

        let configuration = try AboutContentConfiguration.load(from: Data(contentsOf: inputURL))

        XCTAssertEqual(configuration.name, "NotchFlow")
        XCTAssertEqual(configuration.tagline, "Your menu-bar AI workspace")
        XCTAssertEqual(configuration.aboutMeURL, "https://www.notch.website")
    }

    func testInvalidInputJSONIsRejected() {
        XCTAssertThrowsError(try AboutContentConfiguration.load(from: Data("{ \"name\": \"Missing links\" }".utf8)))
    }
}
