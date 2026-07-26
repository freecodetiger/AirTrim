import Foundation

/// AI 语义断句：LLM 只返回**分行文本**（其擅长的形态），断点词下标由本地
/// 对齐算法反推——遵守"LLM 永不产生数字入库"的铁律；任何增删改字都会被
/// 对齐校验拒绝。产出作为 `TranscriptPatch.sentenceStarts` 走 PatchSession，
/// 与手动拆/合句同一状态机制，一步可 undo。
public struct SemanticSegmenter: Sendable {
    public let client: OpenAIChatClient

    public init(client: OpenAIChatClient) {
        self.client = client
    }

    static let systemPrompt = """
    你是字幕断句引擎。把用户提供的口播转写文本按语义断成适合字幕的短句。
    规则：每句一行；必须完整保留原文的每一个字符，不得增删、修改或重排；
    不得添加标点、序号或任何解释；只输出断行后的文本。
    """

    public func proposeSentenceStarts(for transcript: Transcript) async throws -> [Int] {
        let fullText = transcript.words.map(\.text).joined()
        let reply = try await client.complete(system: Self.systemPrompt, user: fullText)
        return try Self.align(wordTexts: transcript.words.map(\.text),
                              lines: reply.split(separator: "\n").map(String.init))
    }

    /// 把 LLM 的分行文本对齐回词序列，返回句起点词下标。
    /// - 去除全部空白后逐字比对，任何不一致 → `LLMError.textMismatch`
    /// - 行边界若落在词中间（LLM 在词内断行），该断点丢弃（保守策略）
    static func align(wordTexts: [String], lines: [String]) throws -> [Int] {
        let normalizedLines = lines
            .map { $0.filter { !$0.isWhitespace } }
            .filter { !$0.isEmpty }
        let joinedWords = wordTexts.joined()
        guard normalizedLines.joined() == joinedWords else {
            throw LLMError.textMismatch
        }

        // 词起点的字符偏移表
        var wordStartAtOffset: [Int: Int] = [:]   // 字符偏移 → 词下标
        var offset = 0
        for (i, w) in wordTexts.enumerated() {
            wordStartAtOffset[offset] = i
            offset += w.count
        }

        var starts: [Int] = [0]
        var lineOffset = 0
        for line in normalizedLines.dropLast() {
            lineOffset += line.count
            if let wordIndex = wordStartAtOffset[lineOffset] {
                starts.append(wordIndex)
            }
            // 落在词中间：跳过该断点
        }
        return Array(Set(starts)).sorted()
    }
}
