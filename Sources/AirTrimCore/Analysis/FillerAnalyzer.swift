import CoreMedia
import Foundation

/// 语气词分析（Analysis · 纯函数）：词表匹配 + 孤立判定出建议。
/// 词表分两档，保守优先——宁可漏不误杀（优先级：剪切正确性 > 紧凑）。
/// 切口定形规则见设计 D-M3（cut-quality 规则 4：删词后两侧停顿合并取较长者）。
public enum FillerAnalyzer {
    /// 高置信单字叹词：独立成词即命中（句尾语气助词豁免见 isSentenceEndParticle）
    static let singleFillers: Set<String> = ["嗯", "啊", "呃", "唔", "诶", "哦"]
    /// 低置信多字口头禅（有实义用法）：仅孤立漂浮时出建议
    static let multiFillers: Set<String> = ["那个", "就是", "就是说", "然后"]
    /// 多字词表最长字符数（匹配窗口上界）
    static let maxPhraseChars = 3

    /// 多字口头禅的孤立判定：两侧词间隙下限
    static let isolationGap = CMTime(value: 150, timescale: 1000)
    /// 句尾语气助词判定：与前词连读的间隙上限
    static let particleGap = CMTime(value: 80, timescale: 1000)

    public static func suggest(transcript: Transcript,
                               effectiveSentences: [TranscriptSentence],
                               silences: [SilenceInterval],
                               params: TightenParams = TightenParams()) -> [EditSuggestion] {
        let words = transcript.words
        guard !words.isEmpty else { return [] }
        let usable = silences.filter { $0.peakEnergy <= params.maxSilencePeak }
        let sentenceStartWords = Set(effectiveSentences.map(\.words.lowerBound))
        // 句末词下标（句尾助词豁免用）
        let sentenceLastWords = Set(effectiveSentences.compactMap {
            $0.words.isEmpty ? nil : $0.words.upperBound - 1
        })

        var out: [EditSuggestion] = []
        var i = 0
        while i < words.count {
            // 多字口头禅优先（最长匹配：「就是说」优先于「就是」）
            if let span = matchMultiFiller(at: i, words: words,
                                           sentenceStartWords: sentenceStartWords) {
                if isIsolated(first: span.lowerBound, last: span.upperBound - 1,
                              words: words, transcript: transcript, silences: usable),
                   let s = shape(first: span.lowerBound, last: span.upperBound - 1,
                                 words: words, transcript: transcript,
                                 sentenceStartWords: sentenceStartWords, params: params) {
                    out.append(s)
                    i = span.upperBound
                    continue
                }
            }
            // 单字叹词
            if singleFillers.contains(normalize(words[i].text)),
               !isSentenceEndParticle(at: i, words: words, sentenceLastWords: sentenceLastWords),
               let s = shape(first: i, last: i, words: words, transcript: transcript,
                             sentenceStartWords: sentenceStartWords, params: params) {
                out.append(s)
            }
            i += 1
        }
        return out
    }

    /// 去除空白与标点后的匹配文本（ASR 词可能带句读）
    static func normalize(_ text: String) -> String {
        text.filter { !$0.isWhitespace && !$0.isPunctuation && !$0.isSymbol }
    }

    /// 从 index 起做多字词表最长匹配（中文管线词≈单字，需跨词拼接）；
    /// 匹配片段不得跨句边界。命中返回词下标区间。
    static func matchMultiFiller(at index: Int, words: [TranscriptWord],
                                 sentenceStartWords: Set<Int>) -> Range<Int>? {
        var text = ""
        var best: Range<Int>? = nil
        var j = index
        while j < words.count, text.count < maxPhraseChars {
            if j > index, sentenceStartWords.contains(j) { break }   // 不跨句
            text += normalize(words[j].text)
            j += 1
            if multiFillers.contains(text) { best = index..<j }      // 继续找更长的
            if text.count >= maxPhraseChars { break }
        }
        return best
    }

    /// 句尾语气助词豁免：句末词且与前词连读（间隙 < 80ms）→ 是助词不是填充词
    static func isSentenceEndParticle(at index: Int, words: [TranscriptWord],
                                      sentenceLastWords: Set<Int>) -> Bool {
        guard sentenceLastWords.contains(index), index > 0 else { return false }
        let gap = CMTimeSubtract(words[index].start, words[index - 1].end)
        return CMTimeCompare(gap, particleGap) < 0
    }

    /// 多字口头禅的孤立判定：两侧间隙均 ≥150ms；间隙长到 VAD 可检（≥500ms）时
    /// 还需静音佐证（更短的间隙 VAD 无数据，只看词间隙）
    static func isIsolated(first: Int, last: Int, words: [TranscriptWord],
                           transcript: Transcript, silences: [SilenceInterval]) -> Bool {
        let prevEnd = first > 0 ? words[first - 1].end : .zero
        let nextStart = last + 1 < words.count ? words[last + 1].start : transcript.sourceDuration
        let leftGap = CMTimeRange(start: prevEnd, end: words[first].start)
        let rightGap = CMTimeRange(start: words[last].end, end: nextStart)
        for gap in [leftGap, rightGap] {
            guard CMTimeCompare(gap.duration, isolationGap) >= 0 else { return false }
            let vadDetectable = CMTime(value: 500, timescale: 1000)
            if CMTimeCompare(gap.duration, vadDetectable) >= 0,
               !PauseAnalyzer.isMostlySilent(gap, in: silences) {
                return false
            }
        }
        return true
    }

    /// 切口定形：删词并把两侧停顿合并为一个（取较长者，clamp 到句中/句尾 keep），
    /// 词边界 padding 保护相邻词；净时长 < minCutWorth 不出建议。
    static func shape(first: Int, last: Int, words: [TranscriptWord],
                      transcript: Transcript, sentenceStartWords: Set<Int>,
                      params: TightenParams) -> EditSuggestion? {
        let hasPrev = first > 0
        let hasNext = last + 1 < words.count
        let prevEnd = hasPrev ? words[first - 1].end : .zero
        let nextStart = hasNext ? words[last + 1].start : transcript.sourceDuration

        let leftGap = CMTimeSubtract(words[first].start, prevEnd)
        let rightGap = CMTimeSubtract(nextStart, words[last].end)
        // 删词后保留的停顿 = 较长一侧，clamp 到 [padding, 句位 keep]
        let keepCeiling = sentenceStartWords.contains(last + 1)
            ? params.sentenceEndKeep : params.midSentenceKeep
        let merged = CMTimeMinimum(keepCeiling,
                                   CMTimeMaximum(CMTimeMaximum(leftGap, rightGap),
                                                 params.wordPadding))

        // 无前词（开场语气词）：切口从词起点开始，开场静音归 PauseAnalyzer
        let cutStart = hasPrev ? CMTimeAdd(prevEnd, params.wordPadding) : words[first].start
        // 无后词（收尾语气词）：切口到词终点为止，收尾静音归 PauseAnalyzer
        let rightKeep = CMTimeMaximum(CMTimeSubtract(merged, params.wordPadding),
                                      params.wordPadding)
        let cutEnd = hasNext ? CMTimeSubtract(nextStart, rightKeep) : words[last].end

        let cut = CMTimeRange(start: cutStart, end: cutEnd)
        guard CMTimeCompare(cut.duration, params.minCutWorth) >= 0 else { return nil }
        let text = words[first...last].map(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // originalGap = 词区间本身（与 pause 建议的 gap 键天然不重叠，互不去重）
        return EditSuggestion(kind: .filler, cut: cut,
                              originalGap: CMTimeRange(start: words[first].start,
                                                       end: words[last].end),
                              detail: text)
    }
}
