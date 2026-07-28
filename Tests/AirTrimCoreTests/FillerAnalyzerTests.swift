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

private func transcript(_ words: [TranscriptWord],
                        sentences: [Range<Int>]? = nil,
                        sourceDurationMs: Int64) -> Transcript {
    let ranges = sentences ?? [0..<words.count]
    return Transcript(words: words,
                      sentences: ranges.enumerated().map {
                          TranscriptSentence(id: $0.offset, words: $0.element)
                      },
                      sourceDuration: t(sourceDurationMs))
}

private func suggest(_ transcript: Transcript,
                     silences: [SilenceInterval] = [],
                     params: TightenParams = TightenParams(intensity: 0)) -> [EditSuggestion] {
    FillerAnalyzer.suggest(transcript: transcript,
                           effectiveSentences: transcript.sentences,
                           silences: silences, params: params)
}

@Suite("FillerAnalyzer：词表匹配、豁免与切口定形")
struct FillerAnalyzerTests {
    @Test func singleFillerHitWithMergedPause() {
        // 「嗯」左 200ms / 右 600ms：合并停顿取较长者，clamp 到句中 keep 150
        let tr = transcript([word("今天", 900, 1400),
                             word("嗯", 1600, 1800),
                             word("很好", 2400, 2900)],
                            sourceDurationMs: 3500)
        let out = suggest(tr)
        #expect(out.count == 1)
        let s = out[0]
        #expect(s.kind == .filler)
        #expect(s.detail == "嗯")
        // cutStart = 1400+50pad；merged = min(150, max(200,600)) = 150 → 右保留 150-50=100
        #expect(s.cut == CMTimeRange(start: t(1450), end: t(2300)))
        // originalGap = 词区间本身（与 pause 的 gap 键不重叠）
        #expect(s.originalGap == CMTimeRange(start: t(1600), end: t(1800)))
        #expect(s.state == .proposed)
    }

    @Test func mergedPauseTakesLongerSideNotSum() {
        // 左 120ms / 右 80ms，均短于 keep 150 → 剩余停顿 = 120（较长者），不留双倍空洞
        let tr = transcript([word("今天", 900, 1400),
                             word("嗯", 1520, 1720),
                             word("很好", 1800, 2300)],
                            sourceDurationMs: 2500)
        let out = suggest(tr)
        #expect(out.count == 1)
        // cutStart = 1400+50；merged = max(120,80)=120 → 右保留 120-50=70 → cutEnd = 1800-70
        #expect(out[0].cut == CMTimeRange(start: t(1450), end: t(1730)))
    }

    @Test func sentenceEndParticleIsExempt() {
        // 句末「啊」与前词连读（间隙 50ms < 80ms）→ 语气助词，不出建议
        let tr = transcript([word("好", 100, 300), word("啊", 350, 500)],
                            sourceDurationMs: 500)
        #expect(suggest(tr).isEmpty)

        // 同为句末「啊」但间隙 200ms ≥ 80ms → 是填充词，出建议
        let tr2 = transcript([word("好", 100, 300), word("啊", 500, 700)],
                             sourceDurationMs: 700)
        let out = suggest(tr2)
        #expect(out.count == 1)
        #expect(out[0].detail == "啊")
        // 无后词：切口到词终点为止（收尾静音归 PauseAnalyzer）
        #expect(out[0].cut == CMTimeRange(start: t(350), end: t(700)))
    }

    @Test func tinyCutBelowMinCutWorthIsDropped() {
        // 两侧间隙极小（20/30ms）：净切口 < minCutWorth 120ms → 不出建议
        let tr = transcript([word("我", 500, 980),
                             word("嗯", 1000, 1050),
                             word("说", 1080, 1500)],
                            sourceDurationMs: 1600)
        #expect(suggest(tr).isEmpty)
    }

    @Test func multiFillerRequiresIsolation() {
        // 中文管线词≈单字：「那」「个」跨词拼接匹配「那个」
        // 孤立（两侧 200ms ≥ 150ms，< 500ms 无需 VAD 佐证）→ 出建议
        let isolated = transcript([word("我", 500, 700),
                                   word("那", 900, 1000), word("个", 1010, 1110),
                                   word("东西", 1310, 1500)],
                                  sourceDurationMs: 1800)
        let out = suggest(isolated)
        #expect(out.count == 1)
        #expect(out[0].detail == "那个")
        #expect(out[0].originalGap == CMTimeRange(start: t(900), end: t(1110)))

        // 与前词连读（左 50ms < 150ms）→ 有实义可能，跳过
        let connected = transcript([word("我", 500, 850),
                                    word("那", 900, 1000), word("个", 1010, 1110),
                                    word("东西", 1310, 1500)],
                                   sourceDurationMs: 1800)
        #expect(suggest(connected).isEmpty)
    }

    @Test func longGapNeedsVADCorroboration() {
        // 左间隙 600ms ≥ 500ms（VAD 可检）：无静音佐证 → 拒；有佐证 → 收
        let tr = transcript([word("我", 100, 300),
                             word("那", 900, 1000), word("个", 1010, 1110),
                             word("东西", 1310, 1500)],
                            sourceDurationMs: 1800)
        #expect(suggest(tr).isEmpty)
        let out = suggest(tr, silences: [silence(300, 900)])
        #expect(out.count == 1)
        #expect(out[0].detail == "那个")
    }

    @Test func longestPhraseWinsOverPrefix() {
        // 「就」「是」「说」→ 最长匹配「就是说」（而非停在「就是」）
        let tr = transcript([word("好", 500, 800),
                             word("就", 1000, 1100), word("是", 1110, 1210),
                             word("说", 1220, 1320),
                             word("对", 1520, 1700)],
                            sourceDurationMs: 2000)
        let out = suggest(tr)
        #expect(out.count == 1)
        #expect(out[0].detail == "就是说")
        #expect(out[0].originalGap == CMTimeRange(start: t(1000), end: t(1320)))
    }

    @Test func multiFillerNeverCrossesSentenceBoundary() {
        // 「就」在句 1 末、「是」在句 2 首：拼接不跨句 → 无匹配
        let tr = transcript([word("好", 500, 800),
                             word("就", 1000, 1100), word("是", 1300, 1400),
                             word("对", 1600, 1700)],
                            sentences: [0..<2, 2..<4],
                            sourceDurationMs: 2000)
        #expect(suggest(tr).isEmpty)
    }

    @Test func emptyTranscriptProducesNothing() {
        let tr = transcript([], sentences: [], sourceDurationMs: 0)
        #expect(suggest(tr).isEmpty)
    }
}
