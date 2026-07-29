// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "AirTrim",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AirTrimCore", targets: ["AirTrimCore"]),
        .executable(name: "AirTrimApp", targets: ["AirTrimApp"]),
        // spike 工具单独成品，便于 `swift run airtrim-spike`；不属于产品依赖图
        .executable(name: "airtrim-spike", targets: ["AirTrimSpike"]),
    ],
    dependencies: [
        // 仅 spike 使用（M0 ASR 验证，见 docs/spikes/m0-asr-spike.md）；产品目标不得依赖
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "AirTrimCore",
            dependencies: [
                // ADR-0006：v1 ASR 引擎。SpeechPipeline 只加载本地模型目录，
                // 永不触发其下载路径（设计 D1，网络仍仅限 LLMProvider）
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // App 层模型下载器（设计 D1：Core 永不联网，下载在组合根一侧）
        .target(
            name: "AirTrimInstaller",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "AirTrimApp",
            dependencies: ["AirTrimCore", "AirTrimInstaller"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // ―― M0 spike：可测纯逻辑（Kit）与 CLI 分离；不进入 AirTrimCore/App 依赖图 ――
        .target(
            name: "AirTrimSpikeKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "AirTrimSpike",
            dependencies: [
                "AirTrimSpikeKit",
                "AirTrimCore",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AirTrimCoreTests",
            dependencies: ["AirTrimCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // App 层纯 I/O 逻辑测试（ProjectStore 扫描/删除；项目列表不归 Core）
        .testTarget(
            name: "AirTrimAppTests",
            dependencies: ["AirTrimApp"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AirTrimSpikeTests",
            dependencies: ["AirTrimSpikeKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AirTrimInstallerTests",
            dependencies: ["AirTrimInstaller"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
