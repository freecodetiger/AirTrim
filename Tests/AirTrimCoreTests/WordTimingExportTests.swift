import CoreMedia
import Foundation
import Testing
@testable import AirTrimCore

private func word(_ text: String, _ start: Double, _ end: Double) -> TranscriptWord {
    TranscriptWord(text: text,
                   start: CMTime(seconds: start, preferredTimescale: 600),
                   end: CMTime(seconds: end, preferredTimescale: 600))
}

private func transcript(_ words: [TranscriptWord], sourceDuration: Double? = nil) -> Transcript {
    Transcript(words: words,
               sentences: SentenceSegmenter.sentences(words: words),
               sourceDuration: CMTime(seconds: sourceDuration ?? words.last?.end.seconds ?? 0,
                                      preferredTimescale: 600))
}

private func hr(_ from: Double, _ to: Double) -> CMTimeRange {
    CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 600),
                end: CMTime(seconds: to, preferredTimescale: 600))
}

/// hyperframes 侧的线上形状（字段名照抄其 transcript.json 契约）
private struct RawDocument: Decodable {
    struct RawWord: Decodable {
        let id: String
        let text: String
        let start: Double
        let end: Double
        let type: String
    }
    let text: String
    let languageCode: String
    let engine: String
    let words: [RawWord]

    enum CodingKeys: String, CodingKey {
        case text, engine, words
        case languageCode = "language_code"
    }
}

@Suite("词级时间轴导出：成片轴与切口")
struct WordTimingExportTests {
    /// 一句三词：中间「嗯」可被 filler 切口覆盖
    var t: Transcript {
        transcript([word("今天", 0, 0.5), word("嗯", 0.7, 0.9), word("很好。", 1.2, 2.0)])
    }

    @Test func noEditsKeepsSourceAxis() {
        let words = WordTimingExport.words(transcript: t)
        #expect(words.map(\.text) == ["今天", "嗯", "很好。"])
        #expect(words.map(\.start) == [0, 0.7, 1.2])
        #expect(words.map(\.end) == [0.5, 0.9, 2.0])
        // w0、w1…稳定引用键
        #expect(words.map(\.id) == ["w0", "w1", "w2"])
    }

    @Test func fullyCutWordIsDroppedAndLaterWordsShift() {
        var edits = EditList()
        edits.add(hr(0.55, 1.1))          // 完全覆盖「嗯」（0.7–0.9）
        let words = WordTimingExport.words(transcript: t, edits: edits)
        #expect(words.map(\.text) == ["今天", "很好。"])
        // 切掉 0.55s，「很好。」从 1.2 前移到 0.65
        #expect(words.map(\.start) == [0, 0.65])
        // id 按导出顺序重排，不留空洞
        #expect(words.map(\.id) == ["w0", "w1"])
    }

    @Test func partiallyOverlappedWordIsKept() {
        // 切口只擦到「嗯」前半 → 词保留（宁可多留字，与 Subtitles 同口径）
        var edits = EditList()
        edits.add(hr(0.55, 0.8))
        let words = WordTimingExport.words(transcript: t, edits: edits)
        #expect(words.map(\.text) == ["今天", "嗯", "很好。"])
    }

    @Test func everyWordHasPositiveDurationAndIsOrdered() {
        // 多切口：词区间可被切点压缩，但绝不允许零长/倒置/乱序
        var edits = EditList()
        edits.add(hr(0.2, 0.4))
        edits.add(hr(0.6, 1.0))
        edits.add(hr(1.4, 1.6))
        let words = WordTimingExport.words(transcript: t, edits: edits)
        #expect(!words.isEmpty)
        for w in words {
            #expect(w.end > w.start)
            #expect(w.type == "word")
        }
        #expect(words.map(\.start) == words.map(\.start).sorted())
    }

    @Test func tailOvershootingCutUsesCompositionDuration() {
        // 切口越过源片尾：keepSegments 夹住了，成片只有 1.5s。
        // outputDuration(sourceDuration:) 在这里会算成 1.0（用未夹取的 cuts 前缀和），是错的。
        let t2 = transcript([word("甲", 0, 0.5), word("乙", 0.6, 1.0), word("丙", 1.2, 2.0)],
                            sourceDuration: 2.0)
        var edits = EditList()
        edits.add(hr(1.5, 2.5))
        let words = WordTimingExport.words(transcript: t2, edits: edits)
        #expect(words.map(\.text) == ["甲", "乙", "丙"])
        #expect(words.last?.end == 1.5)          // 夹到成片时长，不是 1.0
        for w in words { #expect(w.end > w.start) }
    }

    @Test func wordPastDeclaredSourceDurationIsClamped() {
        // Whisper 末词常比实际片长多探一点；成片里那段不存在，夹掉
        let t2 = transcript([word("正文", 1.0, 2.2)], sourceDuration: 1.8)
        let words = WordTimingExport.words(transcript: t2)
        #expect(words.first?.end == 1.8)
        #expect(words.first?.start == 1.0)
    }

    @Test func emptyTranscriptYieldsEmptyDocument() {
        let doc = WordTimingExport.document(transcript: transcript([]))
        #expect(doc.words.isEmpty)
        #expect(doc.text.isEmpty)
        #expect(doc.languageCode == "zh")
    }

    @Test func jsonMatchesHyperframesContract() throws {
        let json = WordTimingExport.json(WordTimingExport.document(transcript: t))
        let raw = try JSONDecoder().decode(RawDocument.self, from: json)
        // /embedded-captions 的 transcribe.cjs 靠这两条决定"跳过 WhisperX、用这份词级数据"
        #expect(!raw.words.isEmpty)
        #expect(!raw.languageCode.isEmpty)
        #expect(raw.engine == "airtrim")
        #expect(raw.text == "今天嗯很好。")
        // 时间是秒不是毫秒：transcribe.cjs 用 end < 36000 判秒；毫秒会越界
        #expect(raw.words.allSatisfy { $0.end < 36000 })
        #expect(raw.words.allSatisfy { $0.type == "word" })
        #expect(raw.words.map(\.id) == ["w0", "w1", "w2"])
    }

    @Test func millisecondsRoundsToThreeDecimals() {
        // 1/3 秒这类无限小数：取到毫秒，且不吐 0.3333333333333333
        #expect(WordTimingExport.milliseconds(CMTime(value: 1, timescale: 3)) == 0.333)
    }
}
