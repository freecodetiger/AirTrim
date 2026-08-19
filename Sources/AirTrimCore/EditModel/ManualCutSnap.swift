import CoreMedia
import Foundation

/// 手动精确剪的磁吸（纯值函数，可单测；spec docs/design/manual-cut.md §磁吸）。
/// 候选边界 = 全部词边界 + 静音沿；点击落在 `threshold` 内吸附到最近边界，
/// 附近无边界则原样——宁可自由也不远吸（词中自由剪是用户明确意图）。
public enum ManualCutSnap {
    /// 吸附半径 ±250ms（词级时间戳误差中位 ~80ms，留足余量）
    public static let threshold = CMTime(value: 250, timescale: 1000)

    /// 吸附：距最近候选边界 ≤ threshold 返回该边界，否则返回原值
    public static func snap(_ t: CMTime, transcript: Transcript) -> CMTime {
        guard let best = nearestBoundary(to: t, in: transcript),
              CMTimeCompare(absDiff(best, t), threshold) <= 0 else { return t }
        return best
    }

    static func nearestBoundary(to t: CMTime, in transcript: Transcript) -> CMTime? {
        var best: CMTime?
        var bestDist: CMTime?
        func consider(_ c: CMTime) {
            let d = absDiff(c, t)
            if let bd = bestDist, CMTimeCompare(d, bd) >= 0 { return }
            best = c
            bestDist = d
        }
        for w in transcript.words {
            consider(w.start)
            consider(w.end)
        }
        for s in transcript.silences {
            consider(s.start)
            consider(s.end)
        }
        return best
    }

    static func absDiff(_ a: CMTime, _ b: CMTime) -> CMTime {
        CMTimeAbsoluteValue(CMTimeSubtract(a, b))
    }
}
