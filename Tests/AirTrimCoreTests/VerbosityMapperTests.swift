import CoreMedia
import Foundation
import Testing
@testable import AirTrimCore

private func t(_ ms: Int64) -> CMTime { CMTime(value: ms, timescale: 1000) }

private func word(_ text: String, _ fromMs: Int64, _ toMs: Int64) -> TranscriptWord {
    TranscriptWord(text: text, start: t(fromMs), end: t(toMs))
}

@Suite("VerbosityMapper：句编号 → 本地切口反查")
struct VerbosityMapperTests {
    /// 三句六词：s0[0,2) s1[2,4) s2[4,6)
    private var transcript: Transcript {
        Transcript(
            words: [
                word("大家", 500, 900), word("好", 950, 1200),
                word("这里", 1500, 1900), word("重复", 1950, 2200),
                word("结尾", 2600, 3000), word("词", 3050, 3300),
            ],
            sentences: [
                TranscriptSentence(id: 0, words: 0..<2),
                TranscriptSentence(id: 1, words: 2..<4),
                TranscriptSentence(id: 2, words: 4..<6),
            ],
            sourceDuration: t(4000)
        )
    }

    private func finding(_ ids: [Int],
                         category: EditSuggestion.VerbosityCategory = .repetition,
                         reason: String = "与前文重复",
                         confidence: Float = 0.9) -> VerbosityFinding {
        VerbosityFinding(sentenceIDs: ids, category: category,
                         reason: reason, confidence: confidence)
    }

    private func map(_ findings: [VerbosityFinding],
                     fingerprint: String? = nil) -> [EditSuggestion]? {
        let tr = transcript
        return VerbosityMapper.suggestions(
            findings: findings, transcript: tr,
            effectiveSentences: tr.sentences,
            requestFingerprint: fingerprint ?? VerbosityMapper.fingerprint(of: tr.sentences),
            params: TightenParams(intensity: 0))
    }

    @Test func sentenceIDMapsToShapedCut() {
        let out = map([finding([1])])!
        #expect(out.count == 1)
        let s = out[0]
        #expect(s.kind == .verbosity)
        #expect(s.detail == "与前文重复")
        #expect(s.confidence == 0.9)
        #expect(s.category == .repetition)
        #expect(s.state == .proposed)
        // 词区间 [1500,2200]：左 pad 50 → 1250；merged = min(250, max(300,400)) = 250
        // → 右保留 200 → cutEnd = 2600-200 = 2400
        #expect(s.cut == CMTimeRange(start: t(1250), end: t(2400)))
        #expect(s.originalGap == CMTimeRange(start: t(1500), end: t(2200)))
    }

    @Test func invalidSentenceIDsAreDroppedSilently() {
        // 越界编号条目整条丢弃；合法条目不受影响
        let out = map([finding([5]), finding([-1]), finding([2])])!
        #expect(out.count == 1)
        #expect(out[0].originalGap.start == t(2600))
    }

    @Test func fingerprintMismatchDiscardsAll() {
        // 请求期间拆/合句 → 指纹失配 → 整批作废（调用方提示重跑）
        #expect(map([finding([1])], fingerprint: "0..3,3..6") == nil)
    }

    @Test func contiguousSentencesMergeIntoOneCut() {
        // [0,1] 连续 → 一个切口跨两句；[0,2] 不连续 → 拆两条（共享理由）
        let merged = map([finding([0, 1])])!
        #expect(merged.count == 1)
        #expect(merged[0].originalGap == CMTimeRange(start: t(500), end: t(2200)))

        let split = map([finding([0, 2])])!
        #expect(split.count == 2)
        #expect(split.allSatisfy { $0.detail == "与前文重复" })
        #expect(split[0].originalGap == CMTimeRange(start: t(500), end: t(1200)))
        #expect(split[1].originalGap == CMTimeRange(start: t(2600), end: t(3300)))
    }

    @Test func edgeSentencesClampToSourceBounds() {
        // 开篇句：无前词 → 切口从句首词起；收尾句：无后词 → 切口到句末词止
        let head = map([finding([0])])![0]
        #expect(head.cut.start == t(500))
        let tail = map([finding([2])])![0]
        #expect(tail.cut.end == t(3300))
    }
}

@Suite("VerbosityClient：LLM 契约解析（离线）")
struct VerbosityClientContractTests {
    @Test func validJSONParsesAndClampsConfidence() {
        let reply = """
        [{"sentence_ids": [3, 1], "category": "falseStart", "reason": "口误重来", "confidence": 1.7}]
        """
        let out = VerbosityClient.parse(reply)!
        #expect(out.count == 1)
        #expect(out[0].sentenceIDs == [1, 3])          // 入库前排序
        #expect(out[0].category == .falseStart)
        #expect(out[0].confidence == 1.0)              // clamp 到 [0,1]
    }

    @Test func timestampAndOffsetFieldsAreRejected() {
        // LLM 夹带时间戳/offset 字段 → 忽略不入库（VerbosityFinding 无时间概念）
        let reply = """
        [{"sentence_ids": [0], "category": "padding", "reason": "凑字",
          "confidence": 0.6, "start_time": 12.5, "end_time": 15.0, "char_offset": 88}]
        """
        let out = VerbosityClient.parse(reply)!
        #expect(out.count == 1)
        #expect(out[0] == VerbosityFinding(sentenceIDs: [0], category: .padding,
                                           reason: "凑字", confidence: 0.6))
        // 非整数句编号（时间戳伪装成 id）→ 整条丢弃
        let bogus = #"[{"sentence_ids": [12.5], "category": "padding", "reason": "x", "confidence": 0.5}]"#
        #expect(VerbosityClient.parse(bogus)!.isEmpty)
    }

    @Test func markdownFenceAndProseAreTolerated() {
        let fenced = """
        ```json
        [{"sentence_ids": [2], "category": "offTopic", "reason": "离题", "confidence": 0.8}]
        ```
        """
        #expect(VerbosityClient.parse(fenced)?.count == 1)
        let prose = """
        分析结果如下：
        [{"sentence_ids": [2], "category": "offTopic", "reason": "离题", "confidence": 0.8}]
        以上。
        """
        #expect(VerbosityClient.parse(prose)?.count == 1)
    }

    @Test func malformedRepliesTriggerRetryPath() {
        // 整体不是 JSON 数组 → nil（analyze 据此重试 1 次）
        #expect(VerbosityClient.parse("我觉得都挺好的") == nil)
        #expect(VerbosityClient.parse("{\"sentence_ids\": [1]}") == nil)
        // 数组合法但单条缺字段/类别未知 → 丢弃该条不中断
        let partial = """
        [{"sentence_ids": [1], "category": "unknown", "reason": "x", "confidence": 0.5},
         {"sentence_ids": [2], "category": "padding", "confidence": 0.5},
         {"sentence_ids": [3], "category": "padding", "reason": "凑字", "confidence": 0.5}]
        """
        let out = VerbosityClient.parse(partial)!
        #expect(out.count == 1)
        #expect(out[0].sentenceIDs == [3])
    }

    @Test func chunkingAndCrossChunkDedup() {
        // 401 句 → 200/200/1 三块
        let sentences = (0..<401).map { (id: $0, text: "句\($0)") }
        let chunks = VerbosityClient.chunked(sentences)
        #expect(chunks.map(\.count) == [200, 200, 1])
        #expect(VerbosityClient.chunked(Array(sentences.prefix(200))).count == 1)

        // 跨块重复条目（句编号集合相同）→ 保留置信度最高者
        let dup = [
            VerbosityFinding(sentenceIDs: [7], category: .padding, reason: "a", confidence: 0.4),
            VerbosityFinding(sentenceIDs: [7], category: .repetition, reason: "b", confidence: 0.9),
            VerbosityFinding(sentenceIDs: [3], category: .padding, reason: "c", confidence: 0.5),
        ]
        let merged = VerbosityClient.dedup(dup)
        #expect(merged.count == 2)
        #expect(merged[0].sentenceIDs == [3])                  // 按首句编号排序
        #expect(merged[1].reason == "b" && merged[1].confidence == 0.9)
    }

    @Test func chunkPromptCarriesContextSummary() {
        let sentences = (0..<401).map { (id: $0, text: "句\($0)。") }
        let chunk = VerbosityClient.chunked(sentences)[1]
        let prompt = VerbosityClient.userPrompt(chunk: chunk, all: sentences, topic: "测试主题")
        #expect(prompt.contains("视频主题：测试主题"))
        #expect(prompt.contains("全文开头："))
        #expect(prompt.contains("全文结尾："))
        #expect(prompt.contains("[200] 句200。"))
        // 单块（不分块）不带摘要
        let single = VerbosityClient.userPrompt(chunk: Array(sentences.prefix(3)),
                                                all: Array(sentences.prefix(3)), topic: nil)
        #expect(!single.contains("全文开头"))
    }
}
