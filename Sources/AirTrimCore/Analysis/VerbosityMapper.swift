import CoreMedia
import Foundation

/// LLM 废话识别的数据契约：只含句编号与文本字段——时间戳/字符 offset
/// 一律不入库，切口由本地句表反查（CLAUDE.md 铁律）。
public struct VerbosityFinding: Sendable, Equatable {
    /// 建议整句删除的句编号（effectiveSentences 的位置序号，升序）
    public let sentenceIDs: [Int]
    public let category: EditSuggestion.VerbosityCategory
    public let reason: String
    public let confidence: Float

    public init(sentenceIDs: [Int], category: EditSuggestion.VerbosityCategory,
                reason: String, confidence: Float) {
        self.sentenceIDs = sentenceIDs.sorted()
        self.category = category
        self.reason = reason
        self.confidence = min(max(confidence, 0), 1)
    }
}

/// 句编号 → 词下标区间 → CMTime 切口（Analysis · 纯函数）。
/// 整句剪除，两端按句尾 keep + padding 定形（设计 D-M3）。
public enum VerbosityMapper {
    /// 句表指纹：请求发起时快照，返回后校验——期间拆/合句则旧结果作废
    public static func fingerprint(of sentences: [TranscriptSentence]) -> String {
        sentences.map { "\($0.words.lowerBound)..\($0.words.upperBound)" }
            .joined(separator: ",")
    }

    /// 指纹失配返回 nil（调用方提示重跑）；非法句编号的条目静默丢弃不中断。
    /// 连续句编号合并为一个切口；不连续的拆成多条（共享理由/置信度）。
    public static func suggestions(findings: [VerbosityFinding],
                                   transcript: Transcript,
                                   effectiveSentences: [TranscriptSentence],
                                   requestFingerprint: String,
                                   params: TightenParams = TightenParams()) -> [EditSuggestion]? {
        guard fingerprint(of: effectiveSentences) == requestFingerprint else { return nil }
        let words = transcript.words
        var out: [EditSuggestion] = []
        for finding in findings {
            let ids = Array(Set(finding.sentenceIDs)).sorted()
            guard !ids.isEmpty,
                  ids.allSatisfy({ $0 >= 0 && $0 < effectiveSentences.count }) else { continue }
            for run in contiguousRuns(ids) {
                let first = effectiveSentences[run.first!].words.lowerBound
                let last = effectiveSentences[run.last!].words.upperBound - 1
                guard first <= last, last < words.count,
                      let s = shape(firstWord: first, lastWord: last, words: words,
                                    transcript: transcript, finding: finding,
                                    params: params) else { continue }
                out.append(s)
            }
        }
        return out
    }

    /// 升序数组切成连续段：[1,2,4] → [[1,2],[4]]
    static func contiguousRuns(_ sorted: [Int]) -> [[Int]] {
        var runs: [[Int]] = []
        for id in sorted {
            if let last = runs.last?.last, id == last + 1 {
                runs[runs.count - 1].append(id)
            } else {
                runs.append([id])
            }
        }
        return runs
    }

    /// 整句切口定形：删句并把两侧停顿合并为一个（取较长者，clamp 到句尾 keep），
    /// 词边界 padding 保护相邻词（与 FillerAnalyzer.shape 同规则，keep 取句尾档）。
    private static func shape(firstWord: Int, lastWord: Int, words: [TranscriptWord],
                              transcript: Transcript, finding: VerbosityFinding,
                              params: TightenParams) -> EditSuggestion? {
        let hasPrev = firstWord > 0
        let hasNext = lastWord + 1 < words.count
        let prevEnd = hasPrev ? words[firstWord - 1].end : .zero
        let nextStart = hasNext ? words[lastWord + 1].start : transcript.sourceDuration

        let leftGap = CMTimeSubtract(words[firstWord].start, prevEnd)
        let rightGap = CMTimeSubtract(nextStart, words[lastWord].end)
        let merged = CMTimeMinimum(params.sentenceEndKeep,
                                   CMTimeMaximum(CMTimeMaximum(leftGap, rightGap),
                                                 params.wordPadding))

        // 无前词（开篇句）：切口从句首词起；无后词（收尾句）：切口到句末词止
        let cutStart = hasPrev ? CMTimeAdd(prevEnd, params.wordPadding) : words[firstWord].start
        let rightKeep = CMTimeMaximum(CMTimeSubtract(merged, params.wordPadding),
                                      params.wordPadding)
        let cutEnd = hasNext ? CMTimeSubtract(nextStart, rightKeep) : words[lastWord].end

        let cut = CMTimeRange(start: cutStart, end: cutEnd)
        guard CMTimeCompare(cut.duration, params.minCutWorth) >= 0 else { return nil }
        return EditSuggestion(kind: .verbosity, cut: cut,
                              originalGap: CMTimeRange(start: words[firstWord].start,
                                                       end: words[lastWord].end),
                              detail: finding.reason,
                              confidence: finding.confidence,
                              category: finding.category)
    }
}
