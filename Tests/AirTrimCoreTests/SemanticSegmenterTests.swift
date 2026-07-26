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
        let starts = try await SemanticSegmenter(client: OpenAIChatClient(config: config))
            .proposeSentenceStarts(for: t)
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
}
