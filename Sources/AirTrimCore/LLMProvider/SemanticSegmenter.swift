import Foundation

/// AI 语义断句：LLM 只返回**分行文本**（其擅长的形态），断点词下标由本地
/// 对齐算法反推——遵守"LLM 永不产生数字入库"的铁律；任何增删改字都会被
/// 对齐校验拒绝。产出作为 `TranscriptPatch.sentenceStarts` 走 PatchSession，
/// 与手动拆/合句同一状态机制，一步可 undo。
///
/// 长视频策略：按句分块（默认 ~25 句/块），每块独立发 LLM。
/// - 短文本（≤25 句）走单请求快路径
/// - 任一块 LLM 改动文字 → 该块退回原始断句，其余块正常
/// - 避免"长文本注意力漂移导致整批作废"
public struct SemanticSegmenter: Sendable {
    public let client: OpenAIChatClient

    /// 每块最多包含的句数。块越小 LLM 越不容易改动文字，但请求次数越多。
    public let chunkSize: Int

    public init(client: OpenAIChatClient, chunkSize: Int = 25) {
        self.client = client
        self.chunkSize = max(1, chunkSize)
    }

    static let systemPrompt = """
    你是字幕断句引擎。把用户提供的口播转写文本按语义断成适合字幕的短句。
    规则：每句一行；必须完整保留原文的每一个字符，不得增删、修改或重排；
    不得添加标点、序号或任何解释；只输出断行后的文本。
    """

    /// 返回句起点词下标（升序，首元素恒为 0）。
    public func proposeSentenceStarts(for transcript: Transcript) async throws -> [Int] {
        let sentences = transcript.sentences
        guard !sentences.isEmpty else { return [0] }

        // 短文本：单请求快路径（避免分块开销）
        if sentences.count <= chunkSize {
            return try await singleRequest(for: transcript)
        }

        // 长文本：分块处理，逐块回退
        return try await chunkedRequests(for: transcript)
    }

    // MARK: - 单请求（短文本快路径）

    private func singleRequest(for transcript: Transcript) async throws -> [Int] {
        let fullText = transcript.words.map(\.text).joined()
        let reply = try await client.complete(system: Self.systemPrompt, user: fullText)
        return try Self.align(wordTexts: transcript.words.map(\.text),
                              lines: reply.split(separator: "\n").map(String.init))
    }

    // MARK: - 分块处理（长文本）

    /// 按句分块 → 逐块 LLM → 逐块 align → 合并。单块失败则该块退回原断句。
    private func chunkedRequests(for transcript: Transcript) async throws -> [Int] {
        let sentences = transcript.sentences
        let words = transcript.words
        var allStarts: Set<Int> = [0]
        var chunkErrors: [Int: Error] = [:]  // 块索引 → 错误（诊断用）

        var chunkStart = 0
        while chunkStart < sentences.count {
            let chunkEnd = min(chunkStart + chunkSize, sentences.count)
            let chunkSentences = sentences[chunkStart..<chunkEnd]
            let wordRange = chunkSentences.first!.words.lowerBound
                           ..< chunkSentences.last!.words.upperBound
            let chunkWords = Array(words[wordRange])

            do {
                let fullText = chunkWords.map(\.text).joined()
                let reply = try await client.complete(system: Self.systemPrompt, user: fullText)
                let localStarts = try Self.align(
                    wordTexts: chunkWords.map(\.text),
                    lines: reply.split(separator: "\n").map(String.init))
                // 偏移到全局词下标（首元素 0 已在 allStarts 中）
                for s in localStarts.dropFirst() {
                    allStarts.insert(wordRange.lowerBound + s)
                }
            } catch {
                // 该块回退：保留原始句边界
                chunkErrors[chunkStart / chunkSize] = error
                for s in chunkSentences.dropFirst() {
                    allStarts.insert(s.words.lowerBound)
                }
            }

            chunkStart = chunkEnd
        }

        // 所有块都失败 → 抛出最后一个错误（让 UI 展示）
        if allStarts == [0] && chunkErrors.count == (sentences.count + chunkSize - 1) / chunkSize {
            throw chunkErrors.values.first ?? LLMError.textMismatch
        }

        return allStarts.sorted()
    }

    // MARK: - 对齐校验

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
