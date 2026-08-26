// swift-tools-version: 6.0
import PackageDescription

// Dependency policy: Apple/swiftlang-maintained packages and system libraries
// only. See ARCHITECTURE.md decisions #2 and #3.
let package = Package(
    name: "mac-sitrep",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "sitrep", targets: ["sitrep"]),
        .executable(name: "sitrepd", targets: ["sitrepd"]),
        .library(name: "SitrepCore", targets: ["SitrepCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        // Required because Command Line Tools does not vendor XCTest or the
        // toolchain's bundled Testing module — see ARCHITECTURE.md decision #3.
        .package(url: "https://github.com/swiftlang/swift-testing.git", from: "0.10.0"),
    ],
    targets: [
        .target(
            name: "SitrepCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "sitrep",
            dependencies: [
                "SitrepCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "sitrepd",
            dependencies: ["SitrepCore"]
        ),
        .testTarget(
            name: "SitrepCoreTests",
            dependencies: [
                "SitrepCore",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
)
