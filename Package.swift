// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotchFlow",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NotchCapabilities", targets: ["NotchCapabilities"])
    ],
    targets: [
        .target(name: "NotchCapabilities", path: "NotchFlow/Sources/Capabilities"),
        .testTarget(name: "NotchCapabilityTests", dependencies: ["NotchCapabilities"])
    ]
)
