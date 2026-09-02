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

    func testAboutContentDoesNotRequireACoffeeSupportURL() throws {
        let json = """
        {
          "name": "NotchFlow",
          "tagline": "Your menu-bar AI workspace",
          "website": "https://www.notch.website",
          "aboutMeURL": "https://www.notch.website/about",
          "xURL": "https://x.com/notchflow",
          "privacyURL": "https://www.notch.website/privacy",
          "feedbackURL": "https://github.com/sidhxntt/NotchFlow/issues"
        }
        """

        let configuration = try AboutContentConfiguration.load(from: Data(json.utf8))

        XCTAssertEqual(configuration.feedbackURL, "https://github.com/sidhxntt/NotchFlow/issues")
    }
}
