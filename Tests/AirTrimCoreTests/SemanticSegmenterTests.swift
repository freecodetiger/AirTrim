import Foundation
import Testing
@testable import AirTrimCore

@Suite("语义断句对齐")
struct SegmentAlignTests {
    let words = ["今天", "聊", "一个", "问题", "你", "以后", "要", "孩子", "吗"]

    @Test func perfectSplitAlignsToWordStarts() throws {
        let starts = try SemanticSegmenter.align(
            wordTexts: words,
            lines: ["今天聊一个问题", "你以后要孩子吗"])
        #expect(starts == [0, 4])
    }

    @Test func singleLineMeansOneSentence() throws {
        let starts = try SemanticSegmenter.align(
            wordTexts: words,
            lines: ["今天聊一个问题你以后要孩子吗"])
        #expect(starts == [0])
    }

    @Test func midWordBreakIsDropped() throws {
        // "一个" 被从中间断开 → 该断点丢弃，其余保留
        let starts = try SemanticSegmenter.align(
            wordTexts: words,
            lines: ["今天聊一", "个问题", "你以后要孩子吗"])
        #expect(starts == [0, 4])
    }

    @Test func whitespaceIsTolerated() throws {
        let starts = try SemanticSegmenter.align(
            wordTexts: words,
            lines: ["今天聊 一个问题 ", "", " 你以后要孩子吗"])
        #expect(starts == [0, 4])
    }

    /// 真网络冒烟（手动执行）：AIRTRIM_LLM_TEST=1 AIRTRIM_LLM_KEY=sk-… swift test --filter liveSegment
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AIRTRIM_LLM_TEST"] == "1"))
    func liveSegmentEndToEnd() async throws {
        let key = ProcessInfo.processInfo.environment["AIRTRIM_LLM_KEY"] ?? ""
        let config = LLMConfig(baseURL: URL(string: "https://api.deepseek.com")!,
                               model: "deepseek-chat", apiKey: key)
        let words = ["今天", "聊", "一个", "非常", "现", "实", "的", "问题",
                     "你", "以", "后", "会", "想", "要", "孩子", "吗",
                     "我的", "回", "答", "是", "我", "以", "后", "不会", "要", "孩子"]
        let t = Transcript(
            words: words.enumerated().map {
                TranscriptWord(text: $0.element,
                               start: .init(value: .init($0.offset * 10), timescale: 30),
                               end: .init(value: .init($0.offset * 10 + 9), timescale: 30))
            },
            sentences: [], sourceDuration: .init(value: 300, timescale: 30))
        let result = try await SemanticSegmenter(client: OpenAIChatClient(config: config))
            .proposeSentenceStarts(for: t)
        let starts = result.sentenceStarts
        print("live starts:", starts)
        #expect(starts.first == 0)
        #expect(starts.count >= 2, "26 词的三个语义句至少断成两句")
        #expect(starts.allSatisfy { $0 >= 0 && $0 < words.count })
    }

    @Test func mutatedTextThrows() {
        #expect(throws: LLMError.self) {
            try SemanticSegmenter.align(
                wordTexts: words,
                lines: ["今天聊一个问题呢", "你以后要孩子吗"])
        }
        #expect(throws: LLMError.self) {
            try SemanticSegmenter.align(
                wordTexts: words,
                lines: ["今天聊一个问题"])   // 丢了后半句
        }
    }

    /// 模拟长文本场景：LLM 常见的小改动（添字/改字/漏字）都应被捕获
    @Test func commonLLMMutationsAreRejected() throws {
        let longWords = (0..<200).map { "词\($0)" }
        let joined = longWords.joined()

        // 中间漏了一个词（LLM 长文本注意力漂移常见错误）
        var missing = longWords
        missing.remove(at: 87)
        #expect(throws: LLMError.self) {
            try SemanticSegmenter.align(wordTexts: longWords, lines: [missing.joined()])
        }

        // 中间重复一个词
        var duplicated = longWords
        duplicated.insert("词42", at: 100)
        #expect(throws: LLMError.self) {
            try SemanticSegmenter.align(wordTexts: longWords, lines: [duplicated.joined()])
        }

        // 正确文本应通过（单行 = 只一句）
        let starts = try SemanticSegmenter.align(wordTexts: longWords, lines: [joined])
        #expect(starts == [0])
    }

    /// 多块对齐：模拟分块后逐块校验（每块独立 align）
    @Test func multiChunkAlignment() throws {
        let chunk1 = ["今天", "天气", "真好"]      // 6 chars: 今天天气真好
        let chunk2 = ["我们", "去", "公园", "玩"]  // 6 chars: 我们去公园玩
        let chunk3 = ["然后", "吃", "晚饭"]        // 4 chars: 然后吃晚饭

        // 块 1：LLM 在 "天气" 后断句
        let s1 = try SemanticSegmenter.align(wordTexts: chunk1,
                                              lines: ["今天天气", "真好"])
        #expect(s1 == [0, 2])

        // 块 2：LLM 在 "公园" 后断句
        let s2 = try SemanticSegmenter.align(wordTexts: chunk2,
                                              lines: ["我们去", "公园玩"])
        #expect(s2 == [0, 2])

        // 块 3：LLM 不断句（单行）
        let s3 = try SemanticSegmenter.align(wordTexts: chunk3,
                                              lines: ["然后吃晚饭"])
        #expect(s3 == [0])
    }
}
