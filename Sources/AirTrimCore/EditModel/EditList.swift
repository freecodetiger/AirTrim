import CoreMedia
import Foundation

/// 剪辑状态唯一真相源（edit-model skill 不变量 1）。
/// cuts 有序且互不重叠——由唯一写入口 `add` 归并保证，消费方不做兜底。
/// 所有区间落【源时间轴】；权威时间 CMTime，Double 不得出现在本类型逻辑里。
public struct EditList: Sendable, Equatable, Codable {
    public private(set) var cuts: [CMTimeRange]

    public init() { cuts = [] }

    /// 唯一写入口：插入并与既有 cuts 归并（重叠或首尾相接都并成一段）
    public mutating func add(_ range: CMTimeRange) {
        guard CMTimeCompare(range.duration, .zero) > 0 else { return }
        var merged = range
        var rest: [CMTimeRange] = []
        for cut in cuts {
            if CMTimeCompare(cut.end, merged.start) < 0 || CMTimeCompare(merged.end, cut.start) < 0 {
                rest.append(cut)
            } else {
                let start = CMTimeMinimum(cut.start, merged.start)
                let end = CMTimeMaximum(cut.end, merged.end)
                merged = CMTimeRange(start: start, end: end)
            }
        }
        rest.append(merged)
        cuts = rest.sorted { CMTimeCompare($0.start, $1.start) < 0 }
    }

    /// 撤销某个区间的剪切：裁掉/切分与之相交的 cuts
    public mutating func remove(overlapping range: CMTimeRange) {
        var result: [CMTimeRange] = []
        for cut in cuts {
            let overlap = CMTimeRangeGetIntersection(cut, otherRange: range)
            guard CMTimeCompare(overlap.duration, .zero) > 0 else {
                result.append(cut)
                continue
            }
            if CMTimeCompare(cut.start, overlap.start) < 0 {
                result.append(CMTimeRange(start: cut.start, end: overlap.start))
            }
            if CMTimeCompare(overlap.end, cut.end) < 0 {
                result.append(CMTimeRange(start: overlap.end, end: cut.end))
            }
        }
        cuts = result
    }

    /// 派生：保留段（预览合成 / 导出消费）
    public func keepSegments(sourceDuration: CMTime) -> [CMTimeRange] {
        var segments: [CMTimeRange] = []
        var cursor = CMTime.zero
        for cut in cuts {
            if CMTimeCompare(cursor, cut.start) < 0 {
                segments.append(CMTimeRange(start: cursor, end: cut.start))
            }
            cursor = CMTimeMaximum(cursor, cut.end)
        }
        if CMTimeCompare(cursor, sourceDuration) < 0 {
            segments.append(CMTimeRange(start: cursor, end: sourceDuration))
        }
        return segments
    }

    public var removedDuration: CMTime {
        cuts.reduce(.zero) { CMTimeAdd($0, $1.duration) }
    }

    public func outputDuration(sourceDuration: CMTime) -> CMTime {
        CMTimeSubtract(sourceDuration, removedDuration)
    }

    /// 源轴 → 成片轴（cuts 前缀和；落在被剪区间内的点映射到该剪切点）
    public func outputTime(forSource t: CMTime) -> CMTime {
        var removed = CMTime.zero
        for cut in cuts {
            if CMTimeCompare(cut.end, t) <= 0 {
                removed = CMTimeAdd(removed, cut.duration)
            } else if CMTimeCompare(cut.start, t) < 0 {
                removed = CMTimeAdd(removed, CMTimeSubtract(t, cut.start))
            } else {
                break
            }
        }
        return CMTimeSubtract(t, removed)
    }

    /// 成片轴 → 源轴（预览 seek / 播放头映射）
    public func sourceTime(forOutput t: CMTime, sourceDuration: CMTime) -> CMTime {
        var remaining = t
        for segment in keepSegments(sourceDuration: sourceDuration) {
            if CMTimeCompare(remaining, segment.duration) < 0 {
                return CMTimeAdd(segment.start, remaining)
            }
            remaining = CMTimeSubtract(remaining, segment.duration)
        }
        return sourceDuration
    }

    // MARK: Codable（有理数编码，D7 规则延伸）

    enum CodingKeys: String, CodingKey { case cuts }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cuts = try c.decode([RationalRange].self, forKey: .cuts).map(\.range)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(cuts.map(RationalRange.init), forKey: .cuts)
    }
}

/// CMTimeRange 的有理数持久化形态（EditModel 内部共用）
struct RationalRange: Codable {
    let start: RationalTime
    let duration: RationalTime

    init(_ r: CMTimeRange) {
        start = RationalTime(r.start)
        duration = RationalTime(r.duration)
    }

    var range: CMTimeRange { CMTimeRange(start: start.cmTime, duration: duration.cmTime) }
}
