import Foundation

/// 转写引擎（App 每次转写前选择；本地默认 + 云端可选，ADR-0007）。
public enum ASREngine: String, Sendable, CaseIterable, Identifiable {
    case local
    case cloud

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .local: "本地（WhisperKit）"
        case .cloud: "云端（DashScope paraformer）"
        }
    }

    /// 云端转写的隐私说明（选择页/设置页共用）。
    public var privacyNote: String {
        switch self {
        case .local: "完全离线，音视频不上传。"
        case .cloud: "音频将上传阿里云 DashScope 转写；文字稿/废话判断仍只见文字稿。"
        }
    }
}
