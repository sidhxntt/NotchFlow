import XCTest
@testable import NotchCapabilities

final class UtilityProcessPolicyTests: XCTestCase {
    func testAllowsOnlyKnownAbsoluteSystemExecutables() {
        XCTAssertTrue(UtilityProcessPolicy.allows(executable: "/usr/bin/pmset"))
        XCTAssertTrue(UtilityProcessPolicy.allows(executable: "/usr/bin/hdiutil"))
        XCTAssertFalse(UtilityProcessPolicy.allows(executable: "/bin/sh"))
        XCTAssertFalse(UtilityProcessPolicy.allows(executable: "hdiutil"))
    }

    func testRejectsArgumentsContainingNulBytes() {
        XCTAssertFalse(UtilityProcessPolicy.validate(arguments: ["attach", "bad\u{0000}path"]))
        XCTAssertTrue(UtilityProcessPolicy.validate(arguments: ["attach", "/tmp/example.dmg"]))
    }

    func testOutputLimitKeepsPrefixAndMarksTruncation() {
        let result = UtilityProcessPolicy.boundedOutput(Data("abcdef".utf8), maximumBytes: 4)
        XCTAssertEqual(String(decoding: result.data, as: UTF8.self), "abcd")
        XCTAssertTrue(result.wasTruncated)
    }
}
