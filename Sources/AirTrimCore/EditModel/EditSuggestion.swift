import CoreMedia
import Foundation

/// 建议式编辑的载体：与 EditList 分离存储，accept 是区间进 EditList 的唯一路径。
/// cut 在分析器产出时就定形（含词边界 padding 与最小停顿保留，设计 D-M2-1）。
public struct EditSuggestion: Sendable, Equatable, Codable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case pause
        case filler
        /// 永不自动接受（acceptAllProposed 模型层硬性拒绝，D-M3-2）
        case verbosity
    }

    /// verbosity 四分类（LLM 契约，cut-quality skill）
    public enum VerbosityCategory: String, Codable, Sendable, CaseIterable {
        case repetition, falseStart, offTopic, padding
    }

    public enum State: String, Codable, Sendable {
        case proposed, accepted, rejected
    }

    public let id: UUID
    public let kind: Kind
    /// 最终切口（源时间轴）
    public let cut: CMTimeRange
    /// 完整静音/间隙区间（UI 展示、跳听定位、重跑去重的键）
    public let originalGap: CMTimeRange
    public var state: State
    /// filler = 所删词文本；verbosity = LLM reason（D-M3-1：全部 optional，M2 档兼容）
    public let detail: String?
    /// verbosity 置信度（本地分析器不填）
    public let confidence: Float?
    public let category: VerbosityCategory?

    public init(id: UUID = UUID(), kind: Kind, cut: CMTimeRange,
                originalGap: CMTimeRange, state: State = .proposed,
                detail: String? = nil, confidence: Float? = nil,
                category: VerbosityCategory? = nil) {
        self.id = id
        self.kind = kind
        self.cut = cut
        self.originalGap = originalGap
        self.state = state
        self.detail = detail
        self.confidence = confidence
        self.category = category
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, cut, originalGap, state, detail, confidence, category
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(Kind.self, forKey: .kind)
        cut = try c.decode(RationalRange.self, forKey: .cut).range
        originalGap = try c.decode(RationalRange.self, forKey: .originalGap).range
        state = try c.decode(State.self, forKey: .state)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        confidence = try c.decodeIfPresent(Float.self, forKey: .confidence)
        category = try c.decodeIfPresent(VerbosityCategory.self, forKey: .category)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(RationalRange(cut), forKey: .cut)
        try c.encode(RationalRange(originalGap), forKey: .originalGap)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(detail, forKey: .detail)
        try c.encodeIfPresent(confidence, forKey: .confidence)
        try c.encodeIfPresent(category, forKey: .category)
    }
}
