// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AetherUnzipKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "AetherUnzipKit", targets: ["AetherUnzipKit"])],
    targets: [
        .binaryTarget(name: "CAetherUnzip", path: "Artifacts/CAetherUnzip.xcframework"),
        .target(name: "AetherUnzipKit", dependencies: ["CAetherUnzip"],
                resources: [.process("Resources")],
                linkerSettings: [.linkedLibrary("z"), .linkedLibrary("bz2"),
                                 .linkedLibrary("iconv"), .linkedLibrary("charset")]),
        .testTarget(name: "AetherUnzipKitTests", dependencies: ["AetherUnzipKit"],
                    resources: [.copy("Fixtures")])
    ]
)
