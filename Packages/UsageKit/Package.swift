// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UsageKit",
    platforms: [.macOS(.v14)],
    products: [.library(name: "UsageKit", targets: ["UsageKit"])],
    targets: [
        .target(name: "UsageKit"),
        .testTarget(name: "UsageKitTests", dependencies: ["UsageKit"],
                    resources: [.process("Fixtures")]),
    ],
    swiftLanguageModes: [.v6]
)
