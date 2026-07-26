import Foundation

/// 耳朵验收用的剪切规划：从词级时间戳找 ≥minGap 的停顿并生成保留区间表。
/// 切法遵循 cut-quality 规则的简化版：每个切口两侧保留 padding + 最小停顿的一半，
/// 绝不零间隙硬拼。产品版将在 EditModel/MediaEngine 中以 CMTime 重新实现。
public enum CutPlan {
    /// 相邻词之间 ≥ minGap 秒的间隙。
    public static func silenceGaps(words: [SpikeWord], minGap: Double) -> [ClosedRange<Double>] {
        guard words.count > 1 else { return [] }
        var gaps: [ClosedRange<Double>] = []
        for (prev, next) in zip(words, words.dropFirst()) {
            let gap = next.start - prev.end
            if gap >= minGap, prev.end < next.start {
                gaps.append(prev.end...next.start)
            }
        }
        return gaps
    }

    /// 把停顿间隙转成实际剪除区间：两侧各保留 `padding + minPauseKeep/2` 秒。
    /// 剪除后仍剩 ≥ minPauseKeep 的自然停顿。收缩后为空的间隙不剪。
    public static func cutRegions(
        gaps: [ClosedRange<Double>],
        minPauseKeep: Double = 0.15,
        padding: Double = 0.05
    ) -> [ClosedRange<Double>] {
        let keep = padding + minPauseKeep / 2
        return gaps.compactMap { g in
            let lo = g.lowerBound + keep
            let hi = g.upperBound - keep
            return lo < hi ? lo...hi : nil
        }
    }

    /// 剪除区间的补集 = 保留区间（有序、互不重叠、限制在 [0, duration]）。
    public static func keepRanges(
        duration: Double,
        cuts: [ClosedRange<Double>]
    ) -> [ClosedRange<Double>] {
        let clamped = cuts
            .compactMap { c -> ClosedRange<Double>? in
                let lo = max(0, c.lowerBound), hi = min(duration, c.upperBound)
                return lo < hi ? lo...hi : nil
            }
            .sorted { $0.lowerBound < $1.lowerBound }

        var merged: [ClosedRange<Double>] = []
        for c in clamped {
            if let last = merged.last, c.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, c.upperBound)
            } else {
                merged.append(c)
            }
        }

        var keeps: [ClosedRange<Double>] = []
        var cursor = 0.0
        for c in merged {
            if cursor < c.lowerBound { keeps.append(cursor...c.lowerBound) }
            cursor = c.upperBound
        }
        if cursor < duration { keeps.append(cursor...duration) }
        return keeps
    }

    /// 剪除总时长（紧凑收益，秒）。
    public static func removedSeconds(_ cuts: [ClosedRange<Double>]) -> Double {
        cuts.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
    }
}
