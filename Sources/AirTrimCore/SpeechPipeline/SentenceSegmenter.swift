import Foundation

/// 断句：句末标点优先，超长兜底。纯函数，句编号是 LLM 契约（M3）的基础。
public enum SentenceSegmenter {
    static let terminators: Set<Character> = ["。", "？", "！", "?", "!", ";", "；", ".", "…"]

    /// - Parameter maxWords: 无标点时的兜底句长（词数）
    public static func sentences(words: [TranscriptWord], maxWords: Int = 30) -> [TranscriptSentence] {
        guard !words.isEmpty else { return [] }
        var out: [TranscriptSentence] = []
        var sentenceStart = 0
        for (i, w) in words.enumerated() {
            let endsSentence = w.text.last.map { terminators.contains($0) } ?? false
            let tooLong = i - sentenceStart + 1 >= maxWords
            if endsSentence || tooLong || i == words.count - 1 {
                out.append(TranscriptSentence(id: out.count, words: sentenceStart..<(i + 1)))
                sentenceStart = i + 1
            }
        }
        return out
    }
}

/// 简繁归一化（设计 D5）：ICU transform，零依赖。Whisper 中文输出存在简繁漂移（M0 实测）。
public enum ZhNormalizer {
    public static func simplified(_ s: String) -> String {
        s.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? s
    }
}
