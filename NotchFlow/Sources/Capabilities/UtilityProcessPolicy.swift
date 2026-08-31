import Foundation

/// Policy shared by utilities that invoke a small, audited set of macOS tools.
/// It intentionally does not accept shell syntax or a PATH lookup.
public enum UtilityProcessPolicy {
    public static let allowedExecutables: Set<String> = [
        "/usr/bin/hdiutil", "/usr/bin/pmset", "/usr/bin/osascript",
        "/usr/bin/open", "/usr/bin/xattr", "/usr/sbin/diskutil",
        "/usr/bin/killall", "/usr/bin/qlmanage", "/usr/bin/mdfind"
    ]

    public struct BoundedOutput: Equatable, Sendable {
        public let data: Data
        public let wasTruncated: Bool
    }

    public static func allows(executable: String) -> Bool {
        allowedExecutables.contains(executable)
    }

    public static func validate(arguments: [String]) -> Bool {
        arguments.allSatisfy { !$0.utf8.contains(0) }
    }

    public static func boundedOutput(_ data: Data, maximumBytes: Int) -> BoundedOutput {
        let limit = max(0, maximumBytes)
        guard data.count > limit else { return BoundedOutput(data: data, wasTruncated: false) }
        return BoundedOutput(data: data.prefix(limit), wasTruncated: true)
    }
}
