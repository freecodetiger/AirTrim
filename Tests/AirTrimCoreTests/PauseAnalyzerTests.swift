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

@Suite("PauseAnalyzer：VAD×词间隙交叉验证与切口定形")
struct PauseAnalyzerTests {
    /// 两句四词：句间 1s 大停顿、句中 600ms 停顿、开场 900ms、收尾 800ms
    private var transcript: Transcript {
        Transcript(
            words: [
                word("今天", 900, 1400),
                word("很好", 2000, 2500),      // 句中停顿 1400→2000 (600ms)
                word("明天", 3500, 4000),      // 句尾停顿 2500→3500 (1000ms)
                word("再说", 4100, 4600),      // 100ms 小间隙（不出建议）
            ],
            sentences: [
                TranscriptSentence(id: 0, words: 0..<2),
                TranscriptSentence(id: 1, words: 2..<4),
            ],
            sourceDuration: t(5400)            // 收尾 4600→5400 (800ms)
        )
    }

    private var fullSilences: [SilenceInterval] {
        [silence(0, 900), silence(1400, 2000), silence(2500, 3500), silence(4600, 5400)]
    }

    @Test func cutsAreShapedWithKeepAndPadding() {
        let params = TightenParams(intensity: 0)   // 标称：句中 150 / 句尾 250 / padding 50
        let out = PauseAnalyzer.suggest(transcript: transcript,
                                        effectiveSentences: transcript.sentences,
                                        silences: fullSilences, params: params)
        #expect(out.count == 4)

        // 开场：0 → 900-250 = 650
        #expect(out[0].cut == CMTimeRange(start: t(0), end: t(650)))
        // 句中（600ms 停顿）：左 pad 50、右 keep 150-50=100 → [1450, 1900]
        #expect(out[1].cut == CMTimeRange(start: t(1450), end: t(1900)))
        // 句尾（1000ms 停顿，下一词是句首）：左 50、右 250-50=200 → [2550, 3300]
        #expect(out[2].cut == CMTimeRange(start: t(2550), end: t(3300)))
        // 收尾：4600+250 → 5400
        #expect(out[3].cut == CMTimeRange(start: t(4850), end: t(5400)))
        // originalGap 保留完整间隙（重跑去重的键）
        #expect(out[1].originalGap == CMTimeRange(start: t(1400), end: t(2000)))
        #expect(out.allSatisfy { $0.state == .proposed && $0.kind == .pause })
    }

    @Test func gapWithoutVADSilenceIsIgnored() {
        // 只给开场静音：其余词间隙即使够长也不出建议（ASR 间隙单独不算数）
        let out = PauseAnalyzer.suggest(transcript: transcript,
                                        effectiveSentences: transcript.sentences,
                                        silences: [silence(0, 900)],
                                        params: TightenParams(intensity: 0))
        #expect(out.count == 1)
        #expect(out[0].originalGap.start == t(0))
    }

    @Test func partialCoverageBelow60PercentIsIgnored() {
        // 句中 600ms 间隙只有 300ms 静音覆盖（50% < 60%）
        let out = PauseAnalyzer.suggest(transcript: transcript,
                                        effectiveSentences: transcript.sentences,
                                        silences: [silence(1400, 1700)],
                                        params: TightenParams(intensity: 0))
        #expect(out.isEmpty)
    }

    @Test func noisySilenceIsSkipped() {
        // 静音段峰值过高（低语/杂音）→ 宁可少剪
        let noisy = fullSilences.map {
            SilenceInterval(start: $0.start, end: $0.end, peakEnergy: 0.5)
        }
        let out = PauseAnalyzer.suggest(transcript: transcript,
                                        effectiveSentences: transcript.sentences,
                                        silences: noisy,
                                        params: TightenParams(intensity: 0))
        #expect(out.isEmpty)
    }

    @Test func intensityTightensKeeps() {
        let loose = TightenParams(intensity: 0)
        let tight = TightenParams(intensity: 1)
        #expect(loose.midSentenceKeep == t(150) && loose.sentenceEndKeep == t(250))
        #expect(tight.midSentenceKeep == t(80) && tight.sentenceEndKeep == t(80))
        // 中点线性
        #expect(TightenParams(intensity: 0.5).midSentenceKeep == t(115))

        let outLoose = PauseAnalyzer.suggest(transcript: transcript,
                                             effectiveSentences: transcript.sentences,
                                             silences: fullSilences, params: loose)
        let outTight = PauseAnalyzer.suggest(transcript: transcript,
                                             effectiveSentences: transcript.sentences,
                                             silences: fullSilences, params: tight)
        // 更紧 → 每个切口不短于宽松版
        for (l, t2) in zip(outLoose, outTight) {
            #expect(CMTimeCompare(t2.cut.duration, l.cut.duration) >= 0)
        }
        // 最紧时右侧保留也不低于词边界 padding（80-50=30 < 50 → 取 50）
        let tightMid = outTight.first { $0.originalGap.start == t(1400) }!
        #expect(tightMid.cut.end == t(1950))   // 2000 - max(80-50, 50)
    }

    @Test func tinyGapsAndTinyCutsProduceNothing() {
        // 100ms 间隙（再紧也剪不出 minCutWorth）——上面素材里 4000→4100 已覆盖：
        // 全静音下也不该出现第 5 条建议
        let extra = fullSilences + [silence(4000, 4100)]
        let out = PauseAnalyzer.suggest(transcript: transcript,
                                        effectiveSentences: transcript.sentences,
                                        silences: extra,
                                        params: TightenParams(intensity: 1))
        #expect(out.count == 4)
    }

    @Test func splitSentenceChangesKeepClassification() {
        // 把"很好|明天"的句界移走：用单句划分 → 3500 处的停顿按句中算（keep 150 而非 250）
        let oneSentence = [TranscriptSentence(id: 0, words: 0..<4)]
        let out = PauseAnalyzer.suggest(transcript: transcript,
                                        effectiveSentences: oneSentence,
                                        silences: fullSilences,
                                        params: TightenParams(intensity: 0))
        let mid = out.first { $0.originalGap.start == t(2500) }!
        #expect(mid.cut.end == t(3400))   // 3500 - (150-50)
    }

    @Test func minGapThresholdFiltersShortPauses() {
        // 门槛 0.7s：句中 600ms 停顿被挡，开场 900ms/句尾 1000ms/收尾 800ms 仍在
        let out = PauseAnalyzer.suggest(transcript: transcript,
                                        effectiveSentences: transcript.sentences,
                                        silences: fullSilences,
                                        params: TightenParams(intensity: 0, minGapSeconds: 0.7))
        #expect(out.count == 3)
        #expect(!out.contains { $0.originalGap.start == t(1400) })

        // 门槛拉到 1.5s：全部停顿都不够长 → 只清长冷场的语义成立
        let strict = PauseAnalyzer.suggest(transcript: transcript,
                                           effectiveSentences: transcript.sentences,
                                           silences: fullSilences,
                                           params: TightenParams(intensity: 0, minGapSeconds: 1.5))
        #expect(strict.isEmpty)

        // 默认 0.3s ≈ 旧版行为：四处建议不变
        #expect(TightenParams().minGap == t(300))
    }
}
