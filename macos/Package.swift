// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GameShelf",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "GameShelf", targets: ["GameShelf"]),
        .library(name: "LibraryCore", targets: ["LibraryCore"]),
        .library(name: "ThumbnailKit", targets: ["ThumbnailKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "LibraryCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(name: "ThumbnailKit"),
        .target(name: "GameLaunch", dependencies: ["LibraryCore"]),
        .target(name: "Integrations"),
        .target(name: "Metadata", dependencies: ["LibraryCore"]),
        .executableTarget(
            name: "GameShelf",
            dependencies: ["LibraryCore", "ThumbnailKit", "GameLaunch", "Integrations", "Metadata"]
        ),
        .testTarget(name: "LibraryCoreTests", dependencies: ["LibraryCore"]),
        .testTarget(name: "ThumbnailKitTests", dependencies: ["ThumbnailKit"]),
        .testTarget(name: "GameLaunchTests", dependencies: ["GameLaunch", "LibraryCore"]),
        .testTarget(name: "IntegrationsTests", dependencies: ["Integrations", "TestSupport"], resources: [.copy("Fixtures")]),
        .target(name: "TestSupport", path: "Tests/TestSupport"),
        .testTarget(name: "MetadataTests", dependencies: ["Metadata", "LibraryCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "GameShelfTests", dependencies: ["GameShelf", "LibraryCore", "Integrations", "TestSupport"]),
    ]
)
