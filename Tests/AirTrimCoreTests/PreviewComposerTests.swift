import CoreMedia
import Foundation
import Testing
@testable import AirTrimCore

private func t(_ ms: Int64) -> CMTime { CMTime(value: ms, timescale: 1000) }
private func r(_ from: Int64, _ to: Int64) -> CMTimeRange {
    CMTimeRange(start: t(from), end: t(to))
}

@Suite("PreviewComposer：切点淡化窗口")
struct FadeWindowTests {
    @Test func twoSegmentsGetOutAndInAroundJunction() {
        let windows = PreviewComposer.fadeWindows(
            segmentDurations: [t(1000), t(2000)], fade: t(30))
        // 接缝在 1000ms：前段末尾淡出 [970,1000]，后段开头淡入 [1000,1030]
        #expect(windows == [
            PreviewComposer.FadeWindow(range: r(970, 1000), fromVolume: 1, toVolume: 0),
            PreviewComposer.FadeWindow(range: r(1000, 1030), fromVolume: 0, toVolume: 1),
        ])
    }

    @Test func singleSegmentNeedsNoFades() {
        #expect(PreviewComposer.fadeWindows(segmentDurations: [t(5000)], fade: t(30)).isEmpty)
    }

    @Test func shortSegmentClampsAndNeverOverlaps() {
        // 中段仅 40ms（< 2×30ms）：淡入淡出窗口会打架，裁剪后必须无重叠
        let windows = PreviewComposer.fadeWindows(
            segmentDurations: [t(1000), t(40), t(1000)], fade: t(30))
        for (a, b) in zip(windows, windows.dropFirst()) {
            #expect(CMTimeCompare(a.range.end, b.range.start) <= 0,
                    "重叠：\(a.range) vs \(b.range)")
        }
        // 所有 ramp 都有正时长
        #expect(windows.allSatisfy { CMTimeCompare($0.range.duration, .zero) > 0 })
    }
}

@Suite("Subtitles.retime：cue 重定时到成片轴")
struct RetimeTests {
    @Test func cuesShiftAndVanishThroughCuts() {
        var edits = EditList()
        edits.add(r(1000, 2000))
        let cues = [
            SubtitleCue(start: t(0), end: t(900), text: "切口之前"),
            SubtitleCue(start: t(1100), end: t(1900), text: "整条在切口里"),
            SubtitleCue(start: t(500), end: t(2500), text: "跨越切口"),
            SubtitleCue(start: t(3000), end: t(4000), text: "切口之后"),
        ]
        let out = Subtitles.retime(cues, through: edits)
        #expect(out.count == 3)
        #expect(out[0].start == t(0) && out[0].end == t(900))
        // 跨切口：500→500，2500→1500（收缩 1s）
        #expect(out[1].start == t(500) && out[1].end == t(1500))
        // 切口之后整体前移 1s
        #expect(out[2].start == t(2000) && out[2].end == t(3000))
    }

    @Test func emptyEditsIsIdentity() {
        let cues = [SubtitleCue(start: t(100), end: t(200), text: "x")]
        #expect(Subtitles.retime(cues, through: EditList()) == cues)
    }
}
