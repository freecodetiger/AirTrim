import CoreMedia
import Foundation

/// 持久化编码：CMTime 以 {value, timescale} 有理数原样存取——
/// 绝不经过 Double（时间权威规则在磁盘上的延伸）。
struct RationalTime: Codable {
    let value: CMTimeValue
    let timescale: CMTimeScale

    init(_ t: CMTime) {
        value = t.value
        timescale = t.timescale
    }

    var cmTime: CMTime { CMTime(value: value, timescale: timescale) }
}

extension TranscriptWord: Codable {
    enum CodingKeys: String, CodingKey { case text, start, end }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            text: try c.decode(String.self, forKey: .text),
            start: try c.decode(RationalTime.self, forKey: .start).cmTime,
            end: try c.decode(RationalTime.self, forKey: .end).cmTime
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        try c.encode(RationalTime(start), forKey: .start)
        try c.encode(RationalTime(end), forKey: .end)
    }
}

extension TranscriptSentence: Codable {
    enum CodingKeys: String, CodingKey { case id, words }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(Int.self, forKey: .id),
            words: try c.decode(Range<Int>.self, forKey: .words)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(words, forKey: .words)
    }
}

extension SilenceInterval: Codable {
    enum CodingKeys: String, CodingKey { case start, end, peakEnergy }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            start: try c.decode(RationalTime.self, forKey: .start).cmTime,
            end: try c.decode(RationalTime.self, forKey: .end).cmTime,
            peakEnergy: try c.decode(Float.self, forKey: .peakEnergy)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(RationalTime(start), forKey: .start)
        try c.encode(RationalTime(end), forKey: .end)
        try c.encode(peakEnergy, forKey: .peakEnergy)
    }
}

extension Transcript: Codable {
    enum CodingKeys: String, CodingKey { case words, sentences, silences, sourceDuration }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            words: try c.decode([TranscriptWord].self, forKey: .words),
            sentences: try c.decode([TranscriptSentence].self, forKey: .sentences),
            // v1 缓存无此键 → 空数组（App 层负责后台补算回写）
            silences: try c.decodeIfPresent([SilenceInterval].self, forKey: .silences) ?? [],
            sourceDuration: try c.decode(RationalTime.self, forKey: .sourceDuration).cmTime
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(words, forKey: .words)
        try c.encode(sentences, forKey: .sentences)
        try c.encode(silences, forKey: .silences)
        try c.encode(RationalTime(sourceDuration), forKey: .sourceDuration)
    }
}
