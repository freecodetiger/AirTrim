import CoreMedia
import Testing
@testable import AirTrimCore

private func word(_ text: String, _ start: Double, _ end: Double) -> TranscriptWord {
    TranscriptWord(text: text,
                   start: CMTime(seconds: start, preferredTimescale: 600),
                   end: CMTime(seconds: end, preferredTimescale: 600))
}

private func transcript(_ words: [TranscriptWord]) -> Transcript {
    Transcript(words: words,
               sentences: SentenceSegmenter.sentences(words: words),
               sourceDuration: CMTime(seconds: words.last?.end.seconds ?? 0, preferredTimescale: 600))
}

@Suite("断句")
struct SegmenterTests {
    @Test func splitsAtTerminalPunctuation() {
        let t = transcript([
            word("今天", 0, 0.5), word("很好。", 0.5, 1.0),
            word("明天", 1.2, 1.6), word("再说？", 1.6, 2.0),
        ])
        #expect(t.sentences.count == 2)
        #expect(t.sentenceText(t.sentences[0]) == "今天很好。")
        #expect(t.sentenceText(t.sentences[1]) == "明天再说？")
    }

    @Test func fallsBackOnMaxWords() {
        let words = (0..<8).map { word("字", Double($0), Double($0) + 0.5) }
        let sentences = SentenceSegmenter.sentences(words: words, maxWords: 3)
        #expect(sentences.count == 3)
        #expect(sentences.map(\.words.count) == [3, 3, 2])
    }
}

@Suite("简繁归一化")
struct ZhNormalizerTests {
    @Test func traditionalBecomesSimplified() {
        #expect(ZhNormalizer.simplified("體驗當父親") == "体验当父亲")
        #expect(ZhNormalizer.simplified("已经是简体") == "已经是简体")
    }
}

@Suite("字幕条生成")
struct SubtitleCueTests {
    @Test func oneCuePerShortSentence() {
        let t = transcript([word("你好。", 0, 1.2), word("再见。", 2.0, 3.2)])
        let cues = Subtitles.cues(transcript: t)
        #expect(cues.count == 2)
        #expect(cues[0].text == "你好。")
    }

    @Test func longSentenceSplitsAtWordBoundary() {
        let words = (0..<10).map { word("四个字呀", Double($0), Double($0) + 0.9) }
        let t = Transcript(words: words,
                           sentences: [TranscriptSentence(id: 0, words: 0..<10)],
                           sourceDuration: CMTime(seconds: 10, preferredTimescale: 600))
        var rules = Subtitles.Rules()
        rules.maxChars = 12
        let cues = Subtitles.cues(transcript: t, rules: rules)
        #expect(cues.count == 4)
        #expect(cues.allSatisfy { $0.text.count <= 12 })
    }

    @Test func minDurationExtendsButNotPastNext() {
        let t = transcript([word("短。", 0, 0.3), word("下一句。", 0.35, 2.0)])
        let cues = Subtitles.cues(transcript: t)
        // 第一条被延展但不越过第二条的开始
        #expect(abs(cues[0].end.seconds - 0.35) < 0.01)
    }

    @Test func smallGapChains() {
        let t = transcript([word("甲乙丙丁。", 0, 1.5), word("戊己庚辛。", 1.58, 3.0)])
        let cues = Subtitles.cues(transcript: t)
        #expect(abs(cues[0].end.seconds - cues[1].start.seconds) < 0.001)
    }

    @Test func patchedSentenceUsesOverrideText() {
        let t = transcript([word("错字。", 0, 1.5)])
        let patch = TranscriptPatch(textOverrides: [0: "对字。"])
        let cues = Subtitles.cues(transcript: t, patch: patch)
        #expect(cues.count == 1)
        #expect(cues[0].text == "对字。")
    }

    @Test func srtFormat() {
        let cues = [SubtitleCue(start: CMTime(seconds: 61.5, preferredTimescale: 600),
                                end: CMTime(seconds: 63.25, preferredTimescale: 600),
                                text: "你好")]
        let srt = Subtitles.srt(cues)
        #expect(srt == "1\n00:01:01,500 --> 00:01:03,250\n你好\n")
    }
}

@Suite("TranscriptPatch")
struct PatchTests {
    // 两句：`0..<2` 与 `2..<4`
    var t: Transcript {
        transcript([
            word("今天", 0, 0.5), word("很好。", 0.5, 1.0),
            word("明天", 1.2, 1.6), word("再说？", 1.6, 2.0),
        ])
    }

    @Test func undoRestoresPreviousState() {
        var session = PatchSession()
        session.apply { $0.textOverrides[0] = "改一" }
        session.apply { $0.textOverrides[0] = "改二" }
        #expect(session.current.textOverrides[0] == "改二")
        let undo1 = session.undo()
        #expect(undo1)
        #expect(session.current.textOverrides[0] == "改一")
        let undo2 = session.undo()
        #expect(undo2)
        #expect(session.current.textOverrides.isEmpty)
        let undo3 = session.undo()
        #expect(!undo3)
    }

    @Test func splitCreatesNewSentenceAndDropsOwnerOverride() {
        var patch = TranscriptPatch(textOverrides: [0: "整句覆盖"])
        patch.split(before: 1, in: t)
        let sentences = patch.effectiveSentences(in: t)
        #expect(sentences.map(\.words) == [0..<1, 1..<2, 2..<4])
        #expect(patch.textOverrides[0] == nil, "被拆句子的覆盖作废")
    }

    @Test func mergeJoinsWithPreviousAndDropsBothOverrides() {
        var patch = TranscriptPatch(textOverrides: [0: "甲", 2: "乙"])
        patch.mergeWithPrevious(sentenceStartingAt: 2, in: t)
        let sentences = patch.effectiveSentences(in: t)
        #expect(sentences.map(\.words) == [0..<4])
        #expect(patch.textOverrides.isEmpty)
    }

    @Test func unaffectedOverrideSurvivesStructureEdit() {
        var patch = TranscriptPatch(textOverrides: [2: "后句覆盖"])
        patch.split(before: 1, in: t)
        #expect(patch.textOverrides[2] == "后句覆盖", "未波及句的键稳定")
    }

    @Test func invalidOpsAreNoOps() {
        var patch = TranscriptPatch()
        patch.split(before: 0, in: t)
        patch.split(before: 2, in: t)          // 已是句起点
        patch.mergeWithPrevious(sentenceStartingAt: 0, in: t)
        #expect(patch.sentenceStarts == nil || patch.effectiveSentences(in: t).count == 2)
    }
}
