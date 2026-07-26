import Testing
@testable import AirTrimSpikeKit

@Suite("停顿检测")
struct SilenceGapTests {
    @Test func findsGapsAtOrAboveThreshold() {
        let words = [
            SpikeWord(text: "a", start: 0.0, end: 1.0),
            SpikeWord(text: "b", start: 1.6, end: 2.0),   // 0.6s 间隙
            SpikeWord(text: "c", start: 2.2, end: 2.5),   // 0.2s 间隙
            SpikeWord(text: "d", start: 3.0, end: 3.5),   // 0.5s 间隙（恰好达线）
        ]
        let gaps = CutPlan.silenceGaps(words: words, minGap: 0.5)
        #expect(gaps == [1.0...1.6, 2.5...3.0])
    }

    @Test func overlappingWordsProduceNoGap() {
        let words = [
            SpikeWord(text: "a", start: 0.0, end: 1.2),
            SpikeWord(text: "b", start: 1.0, end: 1.5),
        ]
        #expect(CutPlan.silenceGaps(words: words, minGap: 0.1).isEmpty)
    }
}

@Suite("剪切区间")
struct CutRegionTests {
    @Test func keepsMinimumPauseAndPadding() {
        // 1.0s 间隙，两侧各留 0.05 + 0.075 = 0.125s → 剪 [1.125, 1.875]，剩 0.25s 停顿
        let cuts = CutPlan.cutRegions(gaps: [1.0...2.0], minPauseKeep: 0.15, padding: 0.05)
        #expect(cuts.count == 1)
        #expect(abs(cuts[0].lowerBound - 1.125) < 0.001)
        #expect(abs(cuts[0].upperBound - 1.875) < 0.001)
    }

    @Test func tooShortGapIsNotCut() {
        // 0.2s 间隙收缩 0.25s 后为空 → 不剪，绝不产生零间隙硬拼
        #expect(CutPlan.cutRegions(gaps: [1.0...1.2]).isEmpty)
    }
}

@Suite("保留区间")
struct KeepRangeTests {
    @Test func complementCoversTimeline() {
        let keeps = CutPlan.keepRanges(duration: 10, cuts: [2.0...3.0, 5.0...6.0])
        #expect(keeps == [0.0...2.0, 3.0...5.0, 6.0...10.0])
    }

    @Test func mergesOverlappingCuts() {
        let keeps = CutPlan.keepRanges(duration: 10, cuts: [2.0...5.0, 4.0...6.0])
        #expect(keeps == [0.0...2.0, 6.0...10.0])
    }

    @Test func clampsOutOfBoundsCuts() {
        let keeps = CutPlan.keepRanges(duration: 5, cuts: [-1.0...1.0, 4.0...9.0])
        #expect(keeps == [1.0...4.0])
    }

    @Test func noCutsKeepsEverything() {
        #expect(CutPlan.keepRanges(duration: 5, cuts: []) == [0.0...5.0])
    }

    @Test func removedSecondsSums() {
        #expect(abs(CutPlan.removedSeconds([1.0...2.0, 3.0...3.5]) - 1.5) < 0.001)
    }
}
