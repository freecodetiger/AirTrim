import CoreMedia
import Foundation

/// 紧凑度参数体系（cut-quality skill 数值落地）。
/// intensity 是无量纲滑杆值；时间量一律 CMTime（毫秒整数分子）。
public struct TightenParams: Sendable, Equatable {
    /// 0（松，句中留 150ms/句尾留 250ms）… 1（紧，双双收到下限 80ms）
    public var intensity: Double
    /// 词边界外扩，绝不在元音中间切（40–60ms 区间取中）
    public var wordPadding = CMTime(value: 50, timescale: 1000)
    /// 切口净时长低于此值不出建议（剪了听不出，白增审阅负担）
    public var minCutWorth = CMTime(value: 120, timescale: 1000)
    /// "静音"里峰值超过此线性幅度（≈ -20dBFS 瞬态）视为低语/杂音，跳过——宁可少剪
    public var maxSilencePeak: Float = 0.1

    public init(intensity: Double = 0.5) {
        self.intensity = min(max(intensity, 0), 1)
    }

    public var midSentenceKeep: CMTime { keep(nominalMs: 150) }
    public var sentenceEndKeep: CMTime { keep(nominalMs: 250) }

    private func keep(nominalMs: Double) -> CMTime {
        let clamped = min(max(intensity, 0), 1)
        let ms = nominalMs + (80 - nominalMs) * clamped
        return CMTime(value: CMTimeValue(ms.rounded()), timescale: 1000)
    }
}

/// 停顿分析（Analysis · 纯函数）：VAD 真静音 × ASR 词间隙交叉验证出建议。
/// 词间隙单独不算数（ASR 在静音段会漂移，speech-pipeline skill）；
/// 切口在此处就定形（含 padding 与最小停顿保留，设计 D-M2-1），accept 原样入 EditList。
public enum PauseAnalyzer {
    public static func suggest(transcript: Transcript,
                               effectiveSentences: [TranscriptSentence],
                               silences: [SilenceInterval],
                               params: TightenParams = TightenParams()) -> [EditSuggestion] {
        let words = transcript.words
        guard !words.isEmpty else { return [] }
        let usable = silences.filter { $0.peakEnergy <= params.maxSilencePeak }
        let sentenceStartWords = Set(effectiveSentences.map(\.words.lowerBound))
        var out: [EditSuggestion] = []

        // 开场空场：0 → 首词（无左词可 pad，切口从 0 起）
        let leadGap = CMTimeRange(start: .zero, end: words[0].start)
        if isMostlySilent(leadGap, in: usable) {
            let rightKeep = CMTimeMaximum(params.sentenceEndKeep, params.wordPadding)
            let cut = CMTimeRange(start: .zero, end: CMTimeSubtract(leadGap.end, rightKeep))
            if CMTimeCompare(cut.duration, params.minCutWorth) >= 0 {
                out.append(EditSuggestion(kind: .pause, cut: cut, originalGap: leadGap))
            }
        }

        // 词间停顿
        for i in 0..<(words.count - 1) {
            let gap = CMTimeRange(start: words[i].end, end: words[i + 1].start)
            guard CMTimeCompare(gap.duration, .zero) > 0, isMostlySilent(gap, in: usable) else { continue }
            let keep = sentenceStartWords.contains(i + 1)
                ? params.sentenceEndKeep : params.midSentenceKeep
            // 保留的停顿分两侧：左侧 = 词边界 padding，右侧 = 其余（但不低于 padding）
            let leftKeep = params.wordPadding
            let rightKeep = CMTimeMaximum(CMTimeSubtract(keep, leftKeep), params.wordPadding)
            let cut = CMTimeRange(start: CMTimeAdd(gap.start, leftKeep),
                                  end: CMTimeSubtract(gap.end, rightKeep))
            guard CMTimeCompare(cut.duration, params.minCutWorth) >= 0 else { continue }
            out.append(EditSuggestion(kind: .pause, cut: cut, originalGap: gap))
        }

        // 收尾空场：末词 → 源末尾（右边界贴源末，无右词可 pad）
        if let last = words.last {
            let tailGap = CMTimeRange(start: last.end, end: transcript.sourceDuration)
            if CMTimeCompare(tailGap.duration, .zero) > 0, isMostlySilent(tailGap, in: usable) {
                let leftKeep = CMTimeMaximum(params.sentenceEndKeep, params.wordPadding)
                let cut = CMTimeRange(start: CMTimeAdd(tailGap.start, leftKeep),
                                      end: tailGap.end)
                if CMTimeCompare(cut.duration, params.minCutWorth) >= 0 {
                    out.append(EditSuggestion(kind: .pause, cut: cut, originalGap: tailGap))
                }
            }
        }
        return out
    }

    /// VAD 交叉验证：静音覆盖 gap 的 ≥60%（比例判定用整数倍乘，不出 Double）
    static func isMostlySilent(_ gap: CMTimeRange, in silences: [SilenceInterval]) -> Bool {
        guard CMTimeCompare(gap.duration, .zero) > 0 else { return false }
        var covered = CMTime.zero
        for s in silences {
            let overlap = CMTimeRangeGetIntersection(
                gap, otherRange: CMTimeRange(start: s.start, end: s.end))
            covered = CMTimeAdd(covered, overlap.duration)
        }
        return CMTimeCompare(CMTimeMultiply(covered, multiplier: 10),
                             CMTimeMultiply(gap.duration, multiplier: 6)) >= 0
    }
}
