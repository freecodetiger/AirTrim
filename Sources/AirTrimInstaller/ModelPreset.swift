import Foundation

/// 可下载的推荐模型档位。
public struct ModelPreset: Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let tier: ModelTier
    public let description: String
    public let manifest: ModelManifest
    public let isRecommended: Bool

    public init(id: String, displayName: String, tier: ModelTier, description: String,
                manifest: ModelManifest, isRecommended: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.tier = tier
        self.description = description
        self.manifest = manifest
        self.isRecommended = isRecommended
    }
}

/// 模型档位分类。
public enum ModelTier: String, Sendable, CaseIterable {
    case light
    case balanced
    case highAccuracy

    public var label: String {
        switch self {
        case .light: "轻量"
        case .balanced: "均衡"
        case .highAccuracy: "高精度"
        }
    }

    public var icon: String {
        switch self {
        case .light: "hare"
        case .balanced: "scalemass"
        case .highAccuracy: "sparkles"
        }
    }
}

// MARK: - 推荐预设列表

extension ModelPreset {
    /// 所有可下载的预设。
    public static var available: [ModelPreset] {
        [.largeV3]  // v1 只有 large-v3 可下载；tiny / turbo 待 argmax 发布 CoreML 编译版后加入
    }

    /// 高精度 · 推荐 · ~3.1 GB
    public static let largeV3 = ModelPreset(
        id: "openai_whisper-large-v3",
        displayName: "Whisper large-v3",
        tier: .highAccuracy,
        description: "中文口播精度最高，推荐用于精剪",
        manifest: .largeV3,
        isRecommended: true
    )
}
