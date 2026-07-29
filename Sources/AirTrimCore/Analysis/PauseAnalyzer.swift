import CoreMedia
import Foundation

/// 紧凑度参数体系（cut-quality skill 数值落地）。
/// intensity 是无量纲滑杆值；时间量一律 CMTime（毫秒整数分子）。
public struct TightenParams: Sendable, Equatable {
    /// 0（松，句中留 150ms/句尾留 250ms）… 1（紧，双双收到下限 80ms）
    public var intensity: Double
    /// 门槛滑杆：只剪 ≥ 此时长的停顿，短气口留给节奏（0.3s ≈ 现有行为下限）
    public var minGap: CMTime
    /// 词边界外扩，绝不在元音中间切（40–60ms 区间取中）
    public var wordPadding = CMTime(value: 50, timescale: 1000)
    /// 切口净时长低于此值不出建议（剪了听不出，白增审阅负担）
    public var minCutWorth = CMTime(value: 120, timescale: 1000)
    /// "静音"里峰值超过此线性幅度（≈ -20dBFS 瞬态）视为低语/杂音，跳过——宁可少剪
    public var maxSilencePeak: Float = 0.1

    public init(intensity: Double = 0.5, minGapSeconds: Double = 0.3) {
        self.intensity = min(max(intensity, 0), 1)
        let ms = (min(max(minGapSeconds, 0), 10) * 1000).rounded()
        self.minGap = CMTime(value: CMTimeValue(ms), timescale: 1000)
    }

    public var midSentenceKeep: CMTime { keep(nominalMs: 150) }
    public var sentenceEndKeep: CMTime { keep(nominalMs: 250) }

    private func keep(nominalMs: Double) -> CMTime {
        let clamped = min(max(intensity, 0), 1)
        let ms = nominalMs + (80 - nominalMs) * clamped
        return CMTime(value: CMTimeValue(ms.rounded()), timescale: 1000)
    }
}

/// 停顿分析（Analysis · 纯函数）。
/// 切口在此处就定形（含 padding 与最小停顿保留，设计 D-M2-1），accept 原样入 EditList。
///
/// M4 修订：两层间隙策略——
/// 1. **句子卡片间隙**（ASR 句子边界）：不依赖 VAD，句子切分本身就是停顿信号
/// 2. **句内词间隙**：需 VAD ≥30% 验证，确认是真静音而非自然语速慢
/// 两层都产出 pause 类 suggestion，统一经 TightenBar 审阅。
public enum PauseAnalyzer {
    public static func suggest(transcript: Transcript,
                               effectiveSentences: [TranscriptSentence],
                               silences: [SilenceInterval],
                               params: TightenParams = TightenParams()) -> [EditSuggestion] {
        let words = transcript.words
        guard !words.isEmpty else { return [] }
        let usable = silences.filter { $0.peakEnergy <= params.maxSilencePeak }
        let sorted = effectiveSentences.sorted { $0.words.lowerBound < $1.words.lowerBound }
        let sentenceStartIndices = Set(sorted.map(\.words.lowerBound))
        var out: [EditSuggestion] = []

        // ── 开场空场（VAD 验证：无句子边界可参照） ──
        let leadGap = CMTimeRange(start: .zero, end: words[0].start)
        if CMTimeCompare(leadGap.duration, params.minGap) >= 0,
           isMostlySilent(leadGap, in: usable) {
            let rightKeep = CMTimeMaximum(params.sentenceEndKeep, params.wordPadding)
            let cut = CMTimeRange(start: .zero, end: CMTimeSubtract(leadGap.end, rightKeep))
            if CMTimeCompare(cut.duration, params.minCutWorth) >= 0 {
                out.append(EditSuggestion(kind: .pause, cut: cut, originalGap: leadGap))
            }
        }

        // ── 句子卡片间隙（无需 VAD；ASR 句子切分即停顿信号） ──
        for i in 0..<(sorted.count - 1) {
            let a = sorted[i], b = sorted[i + 1]
            guard let ra = transcript.sentenceRange(a),
                  let rb = transcript.sentenceRange(b) else { continue }
            let gap = CMTimeRange(start: ra.end, end: rb.start)
            guard CMTimeCompare(gap.duration, params.minGap) >= 0 else { continue }
            if let cut = cutInside(gap, leftKeep: params.wordPadding,
                                   rightKeep: params.sentenceEndKeep,
                                   params: params, usable: usable) {
                out.append(EditSuggestion(kind: .pause, cut: cut, originalGap: gap))
            }
        }

        // ── 句内词间隙（VAD ≥30% 验证，确认不是语速慢；句界处跳过避免重复） ──
        for i in 0..<(words.count - 1) where !sentenceStartIndices.contains(i + 1) {
            let gap = CMTimeRange(start: words[i].end, end: words[i + 1].start)
            guard CMTimeCompare(gap.duration, params.minGap) >= 0,
                  hasSomeSilence(gap, in: usable) else { continue }
            let leftKeep = params.wordPadding
            let rightKeep = CMTimeMaximum(
                CMTimeSubtract(params.midSentenceKeep, leftKeep), params.wordPadding)
            if let cut = cutInside(gap, leftKeep: leftKeep, rightKeep: rightKeep,
                                   params: params, usable: usable) {
                out.append(EditSuggestion(kind: .pause, cut: cut, originalGap: gap))
            }
        }

        // ── 收尾空场（VAD 验证：无句子边界可参照） ──
        if let last = words.last {
            let tailGap = CMTimeRange(start: last.end, end: transcript.sourceDuration)
            if CMTimeCompare(tailGap.duration, params.minGap) >= 0,
               isMostlySilent(tailGap, in: usable) {
                let leftKeep = CMTimeMaximum(params.sentenceEndKeep, params.wordPadding)
                let cut = CMTimeRange(start: CMTimeAdd(tailGap.start, leftKeep), end: tailGap.end)
                if CMTimeCompare(cut.duration, params.minCutWorth) >= 0 {
                    out.append(EditSuggestion(kind: .pause, cut: cut, originalGap: tailGap))
                }
            }
        }
        return out
    }

    /// 在 gap 内成形切口：左右保留 padding → 中间切掉；VAD 用于收紧边界
    private static func cutInside(_ gap: CMTimeRange,
                                  leftKeep: CMTime, rightKeep: CMTime,
                                  params: TightenParams,
                                  usable: [SilenceInterval]) -> CMTimeRange? {
        var cutStart = CMTimeAdd(gap.start, leftKeep)
        var cutEnd = CMTimeSubtract(gap.end, rightKeep)

        if let best = bestSilence(overlapping: gap, in: usable) {
            if CMTimeCompare(best.start, cutStart) > 0 { cutStart = best.start }
            if CMTimeCompare(best.end, cutEnd) < 0   { cutEnd   = best.end }
        }

        guard CMTimeCompare(cutEnd, cutStart) > 0 else { return nil }
        let cut = CMTimeRange(start: cutStart, end: cutEnd)
        guard CMTimeCompare(cut.duration, params.minCutWorth) >= 0 else { return nil }
        return cut
    }

    /// 找 gap 内重叠最长的静音段（VAD 边界精修）
    private static func bestSilence(overlapping gap: CMTimeRange,
                                    in silences: [SilenceInterval]) -> SilenceInterval? {
        silences.compactMap { s -> (SilenceInterval, CMTime)? in
            let o = CMTimeRangeGetIntersection(
                gap, otherRange: CMTimeRange(start: s.start, end: s.end))
            return CMTimeCompare(o.duration, .zero) > 0 ? (s, o.duration) : nil
        }.max { CMTimeCompare($0.1, $1.1) < 0 }?.0
    }

    /// VAD ≥60%：开场/收尾 + FillerAnalyzer 共用
    public static func isMostlySilent(_ gap: CMTimeRange,
                                      in silences: [SilenceInterval]) -> Bool {
        coveredRatio(gap, in: silences) >= 0.6
    }

    /// VAD ≥30%：句内词间隙的松散验证——确认是真停顿而非语速变化
    private static func hasSomeSilence(_ gap: CMTimeRange,
                                       in silences: [SilenceInterval]) -> Bool {
        coveredRatio(gap, in: silences) >= 0.3
    }

    private static func coveredRatio(_ gap: CMTimeRange,
                                     in silences: [SilenceInterval]) -> Double {
        guard CMTimeCompare(gap.duration, .zero) > 0 else { return 0 }
        var covered = CMTime.zero
        for s in silences {
            let overlap = CMTimeRangeGetIntersection(
                gap, otherRange: CMTimeRange(start: s.start, end: s.end))
            covered = CMTimeAdd(covered, overlap.duration)
        }
        return covered.seconds / gap.duration.seconds
    }
}
