// swift-tools-version: 6.2
import PackageDescription

let approachableConcurrency: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
    name: "Squish",
    platforms: [.macOS(.v14)],
    targets: [
        // Pipeline, settings model and file handling. No UI, no default isolation.
        .target(name: "SquishKit", swiftSettings: approachableConcurrency),
        // The menu bar app. Main actor by default.
        .executableTarget(
            name: "Squish",
            dependencies: ["SquishKit"],
            swiftSettings: approachableConcurrency + [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "SquishKitTests", dependencies: ["SquishKit"], swiftSettings: approachableConcurrency),
    ]
)
