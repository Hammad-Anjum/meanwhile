// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeanwhileKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MeanwhileCore", targets: ["MeanwhileCore"]),
        .library(name: "MeanwhileIPC", targets: ["MeanwhileIPC"]),
        .executable(name: "meanwhile-hook", targets: ["MeanwhileHook"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
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
            ]
        ),
        .executableTarget(name: "MeanwhileHook", dependencies: ["MeanwhileIPC"]),
        .testTarget(name: "MeanwhileCoreTests", dependencies: ["MeanwhileCore"]),
    ]
)
