// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TrellisHUD",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "TrellisCore",
            targets: ["TrellisCore"]
        ),
        .executable(
            name: "trellis-card-hook",
            targets: ["TrellisHookCLI"]
        ),
        .executable(
            name: "TrellisHUD",
            targets: ["TrellisHUDApp"]
        ),
    ],
    targets: [
        .target(
            name: "TrellisCore",
            path: "Sources/TrellisCore"
        ),
        .executableTarget(
            name: "TrellisHookCLI",
            dependencies: ["TrellisCore"],
            path: "Sources/TrellisHookCLI"
        ),
        .executableTarget(
            name: "TrellisHUDApp",
            dependencies: ["TrellisCore"],
            path: "Sources/TrellisHUDApp"
        ),
        .testTarget(
            name: "TrellisCoreTests",
            dependencies: ["TrellisCore"],
            path: "Tests/TrellisCoreTests"
        ),
    ]
)
