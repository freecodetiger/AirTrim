import CoreMedia
import Foundation

/// 一条字幕。时间是从 Transcript 派生的不可变快照（唯一真相源不变量）。
public struct SubtitleCue: Sendable, Equatable {
    public let start: CMTime
    public let end: CMTime
    public let text: String

    public init(start: CMTime, end: CMTime, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// 字幕条生成与 SRT 序列化（设计 D2）。纯函数、无系统框架依赖（CoreMedia 除外）。
public enum Subtitles {
    public struct Rules: Sendable {
        /// 单条最大字符数（中文按字计）
        public var maxChars: Int = 32
        /// 最短显示时长（秒）
        public var minDuration: Double = 1.0
        /// 相邻条间隙 ≤ 此值（秒）时无缝相接
        public var chainGap: Double = 0.12

        public init() {}
    }

    /// Transcript + Patch → 字幕条。
    /// 被 Patch 覆盖过文本的句子不再按词折分（词级时间与新文本不再对齐），整句成条；
    /// 用户手改文本优先，也不做词级剔除。
    /// 无覆盖的句子：词区间完全落入 edits 切口的词从 cue 文本剔除（字幕与音画一致，M3）。
    public static func cues(transcript: Transcript, patch: TranscriptPatch = TranscriptPatch(),
                            edits: EditList = EditList(),
                            rules: Rules = Rules()) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        for sentence in patch.effectiveSentences(in: transcript) {
            guard let range = transcript.sentenceRange(sentence) else { continue }
            if let override = patch.textOverrides[sentence.words.lowerBound] {
                let text = override.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    cues.append(SubtitleCue(start: range.start, end: range.end, text: text))
                }
                continue
            }
            cues.append(contentsOf: split(sentence: sentence, in: transcript,
                                          edits: edits, rules: rules))
        }
        return postProcess(cues, rules: rules)
    }

    /// 超长句按词边界折分为多条；被剪掉的词不进 cue（整句剪光则该句无 cue）
    static func split(sentence: TranscriptSentence, in t: Transcript,
                      edits: EditList = EditList(), rules: Rules = Rules()) -> [SubtitleCue] {
        var out: [SubtitleCue] = []
        var chunkWords: [TranscriptWord] = []
        var chunkChars = 0

        func flush() {
            guard let first = chunkWords.first, let last = chunkWords.last else { return }
            out.append(SubtitleCue(start: first.start, end: last.end,
                                   text: chunkWords.map(\.text).joined()))
            chunkWords = []
            chunkChars = 0
        }

        for w in t.words[sentence.words] {
            if isCutOut(w, in: edits) { continue }
            if chunkChars + w.text.count > rules.maxChars, !chunkWords.isEmpty { flush() }
            chunkWords.append(w)
            chunkChars += w.text.count
        }
        flush()
        return out
    }

    /// 词区间**完全**落入某个切口才剔除（只被 padding 擦边的词保留——宁可多留字）
    static func isCutOut(_ word: TranscriptWord, in edits: EditList) -> Bool {
        edits.cuts.contains {
            CMTimeCompare($0.start, word.start) <= 0 &&
                CMTimeCompare(word.end, $0.end) <= 0
        }
    }

    /// 最短时长延展（不越过下一条）+ 小间隙无缝相接
    static func postProcess(_ cues: [SubtitleCue], rules: Rules) -> [SubtitleCue] {
        guard !cues.isEmpty else { return [] }
        var out = cues
        for i in out.indices {
            let minEnd = CMTimeAdd(out[i].start,
                                   CMTime(seconds: rules.minDuration, preferredTimescale: 600))
            var end = CMTimeCompare(out[i].end, minEnd) < 0 ? minEnd : out[i].end
            if i + 1 < out.count {
                let nextStart = out[i + 1].start
                if CMTimeCompare(end, nextStart) > 0 { end = nextStart }
                let gap = CMTimeSubtract(nextStart, end).seconds
                if gap > 0, gap <= rules.chainGap { end = nextStart }
            }
            out[i] = SubtitleCue(start: out[i].start, end: end, text: out[i].text)
        }
        return out
    }

    /// 源时间轴 cue → 成片时间轴（剪辑后导出用）。
    /// 完全落在被剪区间内的 cue 丢弃；跨切口的自然收缩。时间映射唯一来源是 EditList。
    public static func retime(_ cues: [SubtitleCue], through edits: EditList) -> [SubtitleCue] {
        cues.compactMap { cue in
            let start = edits.outputTime(forSource: cue.start)
            let end = edits.outputTime(forSource: cue.end)
            guard CMTimeCompare(start, end) < 0 else { return nil }
            return SubtitleCue(start: start, end: end, text: cue.text)
        }
    }

    /// SRT 序列化
    public static func srt(_ cues: [SubtitleCue]) -> String {
        cues.enumerated().map { i, c in
            "\(i + 1)\n\(timestamp(c.start)) --> \(timestamp(c.end))\n\(c.text)\n"
        }.joined(separator: "\n")
    }

    static func timestamp(_ t: CMTime) -> String {
        let total = max(0, t.seconds)
        let ms = Int((total * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d",
                      ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }
}
