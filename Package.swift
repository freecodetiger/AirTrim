// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "AirTrim",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AirTrimCore", targets: ["AirTrimCore"]),
        .executable(name: "AirTrimApp", targets: ["AirTrimApp"]),
    ],
    targets: [
        .target(
            name: "AirTrimCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "AirTrimApp",
            dependencies: ["AirTrimCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AirTrimCoreTests",
            dependencies: ["AirTrimCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
