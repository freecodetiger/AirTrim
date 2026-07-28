import Foundation

/// 废话识别客户端：LLM 通读带句编号全文，只返回**句编号 + 类别 + 理由 + 置信度**。
/// 解析器只收 sentence_ids——时间戳/字符 offset 等数字字段一律丢弃（CLAUDE.md 铁律，
/// 切口由 VerbosityMapper 用本地句表反查）。产出建议永不自动接受（D-M3-2）。
public struct VerbosityClient: Sendable {
    public let client: OpenAIChatClient

    public init(client: OpenAIChatClient) {
        self.client = client
    }

    /// 长文分块阈值（句数，经验值，实测后可调）
    static let chunkSize = 200
    /// 分块时携带的全文首尾摘要长度（字符）
    static let contextChars = 300

    static let systemPrompt = """
    你是口播视频的剪辑助手。用户提供带编号的转写句子列表，找出可以整句删除的废话：
    - repetition：与其它句子重复表达同一内容（保留讲得最好的那句，标记其余）
    - falseStart：口误后重来的废弃起头
    - offTopic：与主题无关的离题内容
    - padding：无信息量的凑字（寒暄、空洞过渡）
    规则：只输出 JSON 数组，不要任何解释或 Markdown 代码块；拿不准的不要标记（宁可漏）；
    每条格式：{"sentence_ids": [句编号], "category": "类别", "reason": "一句话理由", "confidence": 0到1}
    sentence_ids 只能使用输入中出现的编号；禁止输出时间戳或字符位置。
    """

    /// 通读全文出建议原料（VerbosityFinding，无时间概念）。
    /// - Parameters:
    ///   - sentences: 句编号 → 句文本（编号 = effectiveSentences 位置序号）
    ///   - topic: 可选视频主题一句话（提升离题判定）
    /// JSON 解析失败带 schema 提醒重试 1 次，仍失败抛错（文案可行动）。
    public func analyze(sentences: [(id: Int, text: String)],
                        topic: String?) async throws -> [VerbosityFinding] {
        guard !sentences.isEmpty else { return [] }
        var findings: [VerbosityFinding] = []
        for chunk in Self.chunked(sentences) {
            let user = Self.userPrompt(chunk: chunk, all: sentences, topic: topic)
            let reply = try await client.complete(system: Self.systemPrompt, user: user)
            if let parsed = Self.parse(reply) {
                findings += parsed
            } else {
                // 重试 1 次：附 schema 提醒
                let retry = try await client.complete(
                    system: Self.systemPrompt,
                    user: user + "\n\n注意：上次输出无法解析。只输出 JSON 数组本身，格式：" +
                        #"[{"sentence_ids":[0],"category":"padding","reason":"...","confidence":0.8}]"#)
                guard let parsed = Self.parse(retry) else {
                    throw LLMError.badResponse("废话识别返回的不是有效 JSON（可重试）")
                }
                findings += parsed
            }
        }
        return Self.dedup(findings)
    }

    /// 按 chunkSize 切块（≤200 句时单块）
    static func chunked(_ sentences: [(id: Int, text: String)]) -> [[(id: Int, text: String)]] {
        guard sentences.count > chunkSize else { return [sentences] }
        return stride(from: 0, to: sentences.count, by: chunkSize).map {
            Array(sentences[$0..<min($0 + chunkSize, sentences.count)])
        }
    }

    static func userPrompt(chunk: [(id: Int, text: String)],
                           all: [(id: Int, text: String)], topic: String?) -> String {
        var parts: [String] = []
        if let topic, !topic.isEmpty {
            parts.append("视频主题：\(topic)")
        }
        if chunk.count < all.count {
            // 分块：携带全文首尾摘要做上下文（摘要句不可标记）
            let fullText = all.map(\.text).joined()
            parts.append("全文开头：\(fullText.prefix(contextChars))")
            parts.append("全文结尾：\(fullText.suffix(contextChars))")
            parts.append("以下是本段句子（只能标记这些编号）：")
        }
        parts.append(chunk.map { "[\($0.id)] \($0.text)" }.joined(separator: "\n"))
        return parts.joined(separator: "\n\n")
    }

    /// 宽容解析：剥掉 Markdown 代码围栏；逐条解析，单条非法（缺字段/类别未知）
    /// 丢弃该条不中断；整体不是 JSON 数组 → nil（触发重试）。
    static func parse(_ reply: String) -> [VerbosityFinding]? {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.split(separator: "\n").dropFirst().dropLast().joined(separator: "\n")
        }
        // 有些模型在数组前后加说明文字：截取首个 [ 到末个 ]
        if let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start < end {
            text = String(text[start...end])
        }
        guard let data = text.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        return array.compactMap { item in
            guard let rawIDs = item["sentence_ids"] as? [Any],
                  let categoryRaw = item["category"] as? String,
                  let category = EditSuggestion.VerbosityCategory(rawValue: categoryRaw),
                  let reason = item["reason"] as? String else { return nil }
            let ids = rawIDs.compactMap { $0 as? Int }
            guard !ids.isEmpty, ids.count == rawIDs.count else { return nil }
            let confidence = (item["confidence"] as? NSNumber)?.floatValue ?? 0
            // 其余字段（含任何时间戳/offset）到此为止——不进 VerbosityFinding
            return VerbosityFinding(sentenceIDs: ids, category: category,
                                    reason: reason, confidence: confidence)
        }
    }

    /// 跨块合并去重：句编号集合相同的条目保留置信度最高者
    static func dedup(_ findings: [VerbosityFinding]) -> [VerbosityFinding] {
        var byKey: [String: VerbosityFinding] = [:]
        for f in findings {
            let key = f.sentenceIDs.map(String.init).joined(separator: ",")
            if let existing = byKey[key], existing.confidence >= f.confidence { continue }
            byKey[key] = f
        }
        return byKey.values.sorted { ($0.sentenceIDs.first ?? 0) < ($1.sentenceIDs.first ?? 0) }
    }
}
