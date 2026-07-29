import Foundation

/// AI 字幕纠错：LLM 逐句检查错字、同音字、专有名词，返回修正文本。
/// 只允许改文字，不允许改句编号、增删句、改变原意。
/// 返回 [(句首词下标, 修正文本)]，由本地校验后写入 TranscriptPatch（走 undo）。
public struct TranscriptCorrector: Sendable {
    public let client: OpenAIChatClient

    public init(client: OpenAIChatClient) {
        self.client = client
    }

    static let systemPrompt = """
    你是中文口播字幕校对引擎。用户提供一组编号+文本，逐句检查并修正：

    规则：
    1. 修正错别字、同音字（如"在/再"、"的/得"、"门/们"）
    2. 修正明显的专有名词错误（结合上下文推断）
    3. 修正数字格式（口语"三点五"可保留，但"3.5万"类格式统一）
    4. 不要润色、不要改变原意、不要增删内容
    5. 不要合并或拆分句子
    6. 如果某句没有错误，原样返回
    7. 只输出 JSON 数组，格式：[{"id":编号,"text":"修正文本"}, ...]

    输出示例：
    [{"id":0,"text":"今天我们来看看这个产品"},{"id":1,"text":"它的特点是非常便携"}]
    """

    /// 返回 [句首词下标: 修正文本]，仅包含实际有变化的句子
    public func correct(transcript: Transcript) async throws -> [Int: String] {
        let sentences = transcript.sentences
        guard !sentences.isEmpty else { return [:] }

        // 组装请求：句编号 + 文本
        let lines = sentences.enumerated().map { idx, s in
            "\(idx): \(transcript.sentenceText(s))"
        }.joined(separator: "\n")

        let reply = try await client.complete(system: Self.systemPrompt, user: lines)
        return try Self.parse(reply: reply, sentences: sentences)
    }

    /// 解析 LLM 返回的 JSON，校验句编号全匹配，返回有变化的条目
    static func parse(reply: String, sentences: [TranscriptSentence]) throws -> [Int: String] {
        // 从回复中提取 JSON（LLM 可能在前后加说明文字）
        guard let jsonStart = reply.firstIndex(of: "["),
              let jsonEnd = reply.lastIndex(of: "]"),
              jsonStart < jsonEnd else {
            throw LLMError.badResponse("未找到 JSON 数组")
        }
        let jsonStr = String(reply[jsonStart...jsonEnd])

        guard let data = jsonStr.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw LLMError.badResponse("JSON 解析失败")
        }

        // 校验：返回的句编号必须和原标题的子集一致（允许跳过未改的）
        let inputIDs = Set(sentences.map(\.id))
        var corrections: [Int: String] = [:]
        for item in array {
            guard let id = item["id"] as? Int,
                  let text = item["text"] as? String,
                  !text.isEmpty else {
                throw LLMError.badResponse("条目格式错误：缺少 id 或 text")
            }
            guard inputIDs.contains(id) else {
                throw LLMError.badResponse("句编号 \(id) 不在原稿范围")
            }
            corrections[id] = text
        }

        // 对比原文，只保留有实际变化的
        var changed: [Int: String] = [:]
        for s in sentences {
            if let corrected = corrections[s.id],
               corrected != "" {  // 空字符串忽略
                changed[s.words.lowerBound] = corrected
            }
        }
        return changed
    }

    /// 逐句比较，返回有变化的 [句首词下标: 修正文本]
    public static func diff(transcript: Transcript, corrections: [Int: String]) -> [Int: String] {
        var result: [Int: String] = [:]
        for s in transcript.sentences {
            guard let corrected = corrections[s.id] else { continue }
            let original = transcript.sentenceText(s)
            if corrected != original {
                result[s.words.lowerBound] = corrected
            }
        }
        return result
    }
}
