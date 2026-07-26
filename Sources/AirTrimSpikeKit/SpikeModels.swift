import Foundation

/// M0 spike 专用数据模型（见 docs/spikes/m0-asr-spike.md）。
///
/// 注意：spike 是一次性评测装置，时间用 `Double` 秒以便 JSON 读写与统计；
/// 产品代码的权威时间必须用 `CMTime`（CLAUDE.md 规则），二者不共享类型。

/// 一个带词级时间戳的预测词。
public struct SpikeWord: Codable, Sendable, Equatable {
    public let text: String
    /// 词开始（秒，源音频时间轴）
    public let start: Double
    /// 词结束（秒）
    public let end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// 一次转写的完整输出（引擎产物，评测输入）。
public struct SpikeTranscript: Codable, Sendable {
    /// 引擎标识，如 "whisperkit/large-v3"
    public let engine: String
    public let audioFile: String
    /// 音频总时长（秒），用于 RTF
    public let audioDuration: Double
    /// 转写耗时（秒，墙钟），用于 RTF
    public let transcribeSeconds: Double
    /// 全文（用于 CER）
    public let text: String
    public let words: [SpikeWord]

    public init(engine: String, audioFile: String, audioDuration: Double,
                transcribeSeconds: Double, text: String, words: [SpikeWord]) {
        self.engine = engine
        self.audioFile = audioFile
        self.audioDuration = audioDuration
        self.transcribeSeconds = transcribeSeconds
        self.text = text
        self.words = words
    }

    /// 实时率：转写耗时 / 音频时长。通过线 ≤ 0.5。
    public var rtf: Double { audioDuration > 0 ? transcribeSeconds / audioDuration : .infinity }
}

/// 人工标注的 ground truth（每段素材 ~100 个词边界 + 参考全文）。
public struct GroundTruth: Codable, Sendable {
    /// 参考文字稿（人工校对，用于 CER）；可空 = 只测边界
    public let referenceText: String?
    /// 人工标注的词边界时刻（秒），无需区分词首/词尾——评测取最近预测边界
    public let boundaries: [Double]

    public init(referenceText: String?, boundaries: [Double]) {
        self.referenceText = referenceText
        self.boundaries = boundaries
    }
}

public enum SpikeJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
