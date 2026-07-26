import Foundation

/// 词边界误差统计（毫秒）。对每个人工标注边界，取最近预测边界的 |预测 − 标注|。
public struct BoundaryErrorStats: Sendable {
    public let count: Int
    /// 各标注边界的误差（毫秒），与标注顺序一致
    public let errorsMs: [Double]
    public let medianMs: Double
    public let p95Ms: Double
    public let maxMs: Double
    /// 直方图桶：[0,20) [20,40) … [180,200) [200,∞)，共 11 桶
    public let histogram: [Int]

    /// 通过线（docs/spikes/m0-asr-spike.md）：中位 ≤ 80ms 且 P95 ≤ 200ms
    public var passes: Bool { medianMs <= 80 && p95Ms <= 200 }
}

public enum Metrics {
    /// 计算边界误差。predicted 为空时返回 nil（无法评测）。
    public static func boundaryErrors(annotated: [Double], predictedWords: [SpikeWord]) -> BoundaryErrorStats? {
        let predicted = predictedWords.flatMap { [$0.start, $0.end] }.sorted()
        guard !predicted.isEmpty, !annotated.isEmpty else { return nil }

        let errorsMs = annotated.map { t in
            nearestDistance(to: t, inSorted: predicted) * 1000
        }
        let sorted = errorsMs.sorted()
        var histogram = [Int](repeating: 0, count: 11)
        for e in errorsMs {
            histogram[min(Int(e / 20), 10)] += 1
        }
        return BoundaryErrorStats(
            count: errorsMs.count,
            errorsMs: errorsMs,
            medianMs: percentile(sorted, 0.5),
            p95Ms: percentile(sorted, 0.95),
            maxMs: sorted.last ?? 0,
            histogram: histogram
        )
    }

    /// 字错率 CER = Levenshtein(参考, 预测) / 参考长度。
    /// 归一化：去空白与中英文标点，只比内容字符；大小写不敏感。
    public static func characterErrorRate(reference: String, hypothesis: String) -> Double {
        let ref = normalize(reference)
        let hyp = normalize(hypothesis)
        guard !ref.isEmpty else { return hyp.isEmpty ? 0 : 1 }
        return Double(levenshtein(ref, hyp)) / Double(ref.count)
    }

    /// 内容字符归一化（公开以便测试与标注工具复用）。
    public static func normalize(_ s: String) -> [Character] {
        s.lowercased().filter { ch in
            !ch.isWhitespace && !ch.isPunctuation && !ch.isSymbol
        }
    }

    static func percentile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        guard sorted.count > 1 else { return sorted[0] }
        // 线性插值（R-7）
        let pos = q * Double(sorted.count - 1)
        let lo = Int(pos.rounded(.down)), hi = Int(pos.rounded(.up))
        let frac = pos - Double(lo)
        return sorted[lo] * (1 - frac) + sorted[hi] * frac
    }

    static func nearestDistance(to t: Double, inSorted xs: [Double]) -> Double {
        var lo = 0, hi = xs.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if xs[mid] < t { lo = mid + 1 } else { hi = mid }
        }
        var best = Double.infinity
        if lo < xs.count { best = min(best, abs(xs[lo] - t)) }
        if lo > 0 { best = min(best, abs(xs[lo - 1] - t)) }
        return best
    }

    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var curr = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            curr[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[b.count]
    }
}
