import CoreMedia
import Foundation
import Testing
@testable import AirTrimCore

private func t(_ ms: Int64) -> CMTime { CMTime(value: ms, timescale: 1000) }

private func word(_ text: String, _ fromMs: Int64, _ toMs: Int64) -> TranscriptWord {
    TranscriptWord(text: text, start: t(fromMs), end: t(toMs))
}

private func silence(_ fromMs: Int64, _ toMs: Int64, peak: Float = 0.01) -> SilenceInterval {
    SilenceInterval(start: t(fromMs), end: t(toMs), peakEnergy: peak)
}

@Suite("PauseAnalyzer：双层间隙（句子卡片 + 句内词间隙）")
struct PauseAnalyzerTests {
    /// 两句四词：句间 1s 大停顿、句中 600ms 停顿、开场 900ms、收尾 800ms
    private var transcript: Transcript {
        Transcript(
            words: [
                word("今天", 900, 1400),
                word("很好", 2000, 2500),      // 句中停顿 1400→2000 (600ms)
                word("明天", 3500, 4000),      // 句尾停顿 2500→3500 (1000ms)
                word("再说", 4100, 4600),      // 100ms 小间隙
            ],
            sentences: [
                TranscriptSentence(id: 0, words: 0..<2),
                TranscriptSentence(id: 1, words: 2..<4),
            ],
            sourceDuration: t(5400)
        )
    }

    private var fullSilences: [SilenceInterval] {
        [silence(0, 900), silence(1400, 2000), silence(2500, 3500), silence(4600, 5400)]
    }

    /// 开场 + 句子间隙 + 句内间隙 + 收尾 → 4 条
    /// 句子间隙先于句内词间隙（双层循环顺序）
    @Test func cutsAreShapedWithKeepAndPadding() {
        let params = TightenParams(intensity: 0)
        let out = PauseAnalyzer.suggest(transcript: transcript,
                                        effectiveSentences: transcript.sentences,
                                        silences: fullSilences, params: params)
        #expect(out.count == 4)

        // 开场：0 → 900-250 = 650
        #expect(out[0].cut == CMTimeRange(start: t(0), end: t(650)))
        // 句子间隙（1000ms）：左 50、右 250 → [2550, 3250]（句子循环先跑）
        #expect(out[1].cut == CMTimeRange(start: t(2550), end: t(3250)))
        // 句内（600ms）：左 pad 50、右 keep 150-50=100 → [1450, 1900]
        #expect(out[2].cut == CMTimeRange(start: t(1450), end: t(1900)))
        // 收尾：4600+250 → 5400
        #expect(out[3].cut == CMTimeRange(start: t(4850), end: t(5400)))
        #expect(out.allSatisfy { $0.state == .proposed && $0.kind == .pause })
    }

    /// 句子间隙不依赖 VAD；句内词间隙需要 VAD
    @Test func sentenceGapWithoutVAD_wordGapNeedsVAD() {
        let out = PauseAnalyzer.suggest(transcript: transcript,
                                        effectiveSentences: transcript.sentences,
                                        silences: [silence(0, 900)],
                                        params: TightenParams(intensity: 0))
        // 开场(VAD✅) + 句子间隙(2500→3500, 无需VAD) = 2；句内 1400→2000 缺 VAD 跳过
        #expect(out.count == 2)
        #expect(out[0].originalGap.start == t(0))
        #expect(out[1].originalGap.start == t(2500))
    }

    /// 句内词间隙：VAD ≥30% 即可（60% 门槛已废除）
    @Test func intraSentencePartialVADPasses() {
        // 1400→2000 (600ms) 间隙只覆盖 200ms → 33% ≥ 30% ✅
        let out = PauseAnalyzer.suggest(transcript: transcript,
                                        effectiveSentences: transcript.sentences,
                                        silences: [silence(1400, 1600)],
                                        params: TightenParams(intensity: 0))
        let intra = out.first { $0.originalGap.start == t(1400) }
        #expect(intra != nil)
    }

    /// 句内词间隙 VAD <30% 跳过（句子间隙不受影响）
    @Test func intraSentenceBelow30PercentSkipped() {
        // 1400→2000 (600ms) 只覆盖 120ms → 20% < 30% → 句内跳过
        // 句子间隙 2500→3500 仍出（无需 VAD）
        let out = PauseAnalyzer.suggest(transcript: transcript,
                                        effectiveSentences: transcript.sentences,
                                        silences: [silence(1400, 1520)],
                                        params: TightenParams(intensity: 0))
        #expect(out.count == 1)
        #expect(out[0].originalGap.start == t(2500))   // 句子间隙
    }

    @Test func noisySilenceSkipsIntraSentenceButNotSentenceGap() {
        let noisy = fullSilences.map {
            SilenceInterval(start: $0.start, end: $0.end, peakEnergy: 0.5)
        }
        let out = PauseAnalyzer.suggest(transcript: transcript,
                                        effectiveSentences: transcript.sentences,
                                        silences: noisy,
                                        params: TightenParams(intensity: 0))
        // 全部静音 peak 超标 → 开场/收尾/句内跳过；句子间隙 2500→3500 仍出
        #expect(out.count == 1)
        #expect(out[0].originalGap.start == t(2500))
    }

    @Test func intensityTightensKeeps() {
        let loose = TightenParams(intensity: 0)
        let tight = TightenParams(intensity: 1)
        #expect(loose.midSentenceKeep == t(150) && loose.sentenceEndKeep == t(250))
        #expect(tight.midSentenceKeep == t(80) && tight.sentenceEndKeep == t(80))
        #expect(TightenParams(intensity: 0.5).midSentenceKeep == t(115))

        let outLoose = PauseAnalyzer.suggest(transcript: transcript,
                                             effectiveSentences: transcript.sentences,
                                             silences: fullSilences, params: loose)
        let outTight = PauseAnalyzer.suggest(transcript: transcript,
                                             effectiveSentences: transcript.sentences,
                                             silences: fullSilences, params: tight)
        #expect(outLoose.count == outTight.count)
        for (l, t2) in zip(outLoose, outTight) {
            #expect(CMTimeCompare(t2.cut.duration, l.cut.duration) >= 0)
        }
    }

    @Test func tinyGapsAndTinyCutsProduceNothing() {
        let extra = fullSilences + [silence(4000, 4100)]
        let out = PauseAnalyzer.suggest(transcript: transcript,
                                        effectiveSentences: transcript.sentences,
                                        silences: extra,
                                        params: TightenParams(intensity: 1))
        // 100ms < minGap(300ms) → 不出；其余 4 条照旧
        #expect(out.count == 4)
        #expect(!out.contains { $0.originalGap.start == t(4000) })
    }

    @Test func singleSentenceOnlyWordGapsAndEdges() {
        let oneSentence = [TranscriptSentence(id: 0, words: 0..<4)]
        let out = PauseAnalyzer.suggest(transcript: transcript,
                                        effectiveSentences: oneSentence,
                                        silences: fullSilences,
                                        params: TightenParams(intensity: 0))
        // 无句子间隙 → 开场 + 句内 1400→2000 + 句内 2500→3500 + 收尾 = 4
        // 2500→3500 虽是 1000ms 但在一句内 → 走句内路径，需 VAD（有）
        #expect(out.count == 4)
        let mid1 = out.first { $0.originalGap.start == t(1400) }!
        let mid2 = out.first { $0.originalGap.start == t(2500) }!
        // 句内用 midSentenceKeep(150) 而非 sentenceEndKeep(250)
        #expect(mid1.cut.end == t(1900))   // 2000 - (150-50)
        #expect(mid2.cut.end == t(3400))   // 3500 - (150-50)
    }

    @Test func minGapThresholdFiltersShortGaps() {
        let out = PauseAnalyzer.suggest(transcript: transcript,
                                        effectiveSentences: transcript.sentences,
                                        silences: fullSilences,
                                        params: TightenParams(intensity: 0, minGapSeconds: 0.7))
        // 句内 600ms < 700ms 被过滤 → 开场 900 + 句子 1000 + 收尾 800 = 3
        #expect(out.count == 3)
        #expect(!out.contains { $0.originalGap.start == t(1400) })

        let strict = PauseAnalyzer.suggest(transcript: transcript,
                                           effectiveSentences: transcript.sentences,
                                           silences: fullSilences,
                                           params: TightenParams(intensity: 0, minGapSeconds: 1.2))
        #expect(strict.isEmpty)

        #expect(TightenParams().minGap == t(300))
    }

    @Test func leadingAndTrailingStillRequireVAD() {
        let out = PauseAnalyzer.suggest(transcript: transcript,
                                        effectiveSentences: transcript.sentences,
                                        silences: [],
                                        params: TightenParams(intensity: 0))
        // 无 VAD → 开场/收尾/句内跳过 → 仅句子间隙 2500→3500
        #expect(out.count == 1)
        #expect(out[0].originalGap.start == t(2500))
    }
}
