import CoreMedia
import Foundation
import Testing
@testable import AirTrimCore

private func t(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 600)
}

private func word(_ text: String, _ from: Double, _ to: Double) -> TranscriptWord {
    TranscriptWord(text: text, start: t(from), end: t(to))
}

private func silence(_ from: Double, _ to: Double) -> SilenceInterval {
    SilenceInterval(start: t(from), end: t(to), peakEnergy: 0)
}

/// 词：0.2–0.8 / 1.5–2.2；静音：0.9–1.4
private let fixture = Transcript(
    words: [word("你", 0.2, 0.8), word("好", 1.5, 2.2)],
    sentences: [],
    silences: [silence(0.9, 1.4)],
    sourceDuration: t(3))

@Suite("手动精确剪磁吸")
struct ManualCutSnapTests {
    @Test func nearWordBoundarySnaps() {
        // 0.19 → 吸附到词起点 0.2；2.22 → 吸附到词尾 2.2
        #expect(ManualCutSnap.snap(t(0.19), transcript: fixture) == t(0.2))
        #expect(ManualCutSnap.snap(t(2.22), transcript: fixture) == t(2.2))
    }

    @Test func nearSilenceEdgeSnaps() {
        // 0.88 → 静音起点 0.9；1.42 → 静音终点 1.4
        #expect(ManualCutSnap.snap(t(0.88), transcript: fixture) == t(0.9))
        #expect(ManualCutSnap.snap(t(1.42), transcript: fixture) == t(1.4))
    }

    @Test func insideWordFarFromBoundaryStays() {
        // 词中 1.6 距最近边界 0.1s（词尾 2.2）> 阈值内？0.1s < 250ms → 吸到 1.5
        // 用更居中的点验证自由剪：0.5 距 0.2/0.8 各 300ms > 阈值 → 原样
        #expect(ManualCutSnap.snap(t(0.5), transcript: fixture) == t(0.5))
    }

    @Test func snapChoosesNearestBoundary() {
        // 1.45 距 1.4（100ms）与 1.5（50ms）→ 取 1.5
        #expect(ManualCutSnap.snap(t(1.45), transcript: fixture) == t(1.5))
    }

    @Test func beyondThresholdReturnsOriginal() {
        // 0.5 距词边界 300ms；无静音候选更近 → 原样
        #expect(ManualCutSnap.snap(t(0.5), transcript: fixture) == t(0.5))
    }
}
