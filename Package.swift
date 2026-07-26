// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "AirCut",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AirCutCore", targets: ["AirCutCore"]),
        .executable(name: "AirCutApp", targets: ["AirCutApp"]),
    ],
    targets: [
        .target(
            name: "AirCutCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "AirCutApp",
            dependencies: ["AirCutCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AirCutCoreTests",
            dependencies: ["AirCutCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
