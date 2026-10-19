// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeanwhileKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MeanwhileCore", targets: ["MeanwhileCore"]),
        .library(name: "MeanwhileIPC", targets: ["MeanwhileIPC"]),
        .executable(name: "meanwhile", targets: ["MeanwhileApp"]),
        .executable(name: "meanwhile-hook", targets: ["MeanwhileHook"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        .package(url: "https://github.com/MrKai77/DynamicNotchKit", from: "1.1.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        // Shared by the app and the hook: paths and the wire format. No dependencies,
        // so the hook binary stays small and starts fast.
        .target(name: "MeanwhileIPC"),
        .target(
            name: "MeanwhileCore",
            dependencies: [
                "MeanwhileIPC",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            // Starter decks (task 1.4). The resource bundle must ship next to the binary.
            resources: [.copy("Resources/Packs")]
        ),
        // The `meanwhile` command: CLI subcommands plus the background notch process.
        .executableTarget(
            name: "MeanwhileApp",
            dependencies: [
                "MeanwhileCore",
                "MeanwhileIPC",
                .product(name: "DynamicNotchKit", package: "DynamicNotchKit"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/MeanwhileApp"
        ),
        // Kept separate from `meanwhile` so it never links AppKit, SwiftUI or GRDB.
        .executableTarget(name: "MeanwhileHook", dependencies: ["MeanwhileIPC"]),
        .testTarget(
            name: "MeanwhileCoreTests",
            dependencies: ["MeanwhileCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
