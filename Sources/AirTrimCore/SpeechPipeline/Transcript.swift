import CoreMedia
import Foundation

/// 词级转写结果（overview §4）。权威时间一律 `CMTime`；`Double` 秒只用于 UI 展示。

public struct TranscriptWord: Sendable, Equatable {
    public let text: String
    /// 源时间轴上的词区间
    public let start: CMTime
    public let end: CMTime

    public init(text: String, start: CMTime, end: CMTime) {
        self.text = text
        self.start = start
        self.end = end
    }
}

public struct TranscriptSentence: Sendable, Equatable {
    /// LLM 契约只允许引用这个编号（M3）
    public let id: Int
    /// 指向 `Transcript.words` 的下标区间
    public let words: Range<Int>

    public init(id: Int, words: Range<Int>) {
        self.id = id
        self.words = words
    }
}

/// 不可变快照；重转写 = 新 Transcript。人工修订放 `TranscriptPatch`（EditModel）。
public struct Transcript: Sendable, Equatable {
    public let words: [TranscriptWord]
    public let sentences: [TranscriptSentence]
    public let sourceDuration: CMTime

    public init(words: [TranscriptWord], sentences: [TranscriptSentence], sourceDuration: CMTime) {
        self.words = words
        self.sentences = sentences
        self.sourceDuration = sourceDuration
    }

    public func sentenceText(_ s: TranscriptSentence) -> String {
        words[s.words].map(\.text).joined()
    }

    public func sentenceRange(_ s: TranscriptSentence) -> (start: CMTime, end: CMTime)? {
        guard !s.words.isEmpty else { return nil }
        return (words[s.words.lowerBound].start, words[s.words.upperBound - 1].end)
    }
}

public struct SilenceInterval: Sendable, Equatable {
    public let start: CMTime
    public let end: CMTime
    /// 区分真静音与低语/底噪（M2 用）
    public let peakEnergy: Float

    public init(start: CMTime, end: CMTime, peakEnergy: Float) {
        self.start = start
        self.end = end
        self.peakEnergy = peakEnergy
    }
}
