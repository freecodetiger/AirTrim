import CoreMedia
import Foundation

/// 建议式编辑的载体：与 EditList 分离存储，accept 是区间进 EditList 的唯一路径。
/// cut 在分析器产出时就定形（含词边界 padding 与最小停顿保留，设计 D-M2-1）。
public struct EditSuggestion: Sendable, Equatable, Codable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case pause
        // M3: case filler, case verbosity（verbosity 永不自动接受）
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

    public init(id: UUID = UUID(), kind: Kind, cut: CMTimeRange,
                originalGap: CMTimeRange, state: State = .proposed) {
        self.id = id
        self.kind = kind
        self.cut = cut
        self.originalGap = originalGap
        self.state = state
    }

    enum CodingKeys: String, CodingKey { case id, kind, cut, originalGap, state }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(Kind.self, forKey: .kind)
        cut = try c.decode(RationalRange.self, forKey: .cut).range
        originalGap = try c.decode(RationalRange.self, forKey: .originalGap).range
        state = try c.decode(State.self, forKey: .state)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(RationalRange(cut), forKey: .cut)
        try c.encode(RationalRange(originalGap), forKey: .originalGap)
        try c.encode(state, forKey: .state)
    }
}
