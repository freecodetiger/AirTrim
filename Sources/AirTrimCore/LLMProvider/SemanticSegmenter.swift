import Foundation

// MARK: - 结果类型

/// 单块 LLM 断句的详细结果。
public struct ChunkResult: Sendable, Equatable {
    /// 该块覆盖的句范围（在 `transcript.sentences` 中的下标）。
    public let sentenceRange: Range<Int>
    /// 词下标范围。
    public let wordRange: Range<Int>
    /// LLM 对齐是否成功。
    public let succeeded: Bool
    /// 成功时的句起点词下标（相对该块首词的偏移）；失败时为 nil。
    public let localStarts: [Int]?
    /// 失败原因（succeeded == false 时有值）。
    public let errorDescription: String?

    public init(sentenceRange: Range<Int>, wordRange: Range<Int>,
                succeeded: Bool, localStarts: [Int]?, errorDescription: String?) {
        self.sentenceRange = sentenceRange
        self.wordRange = wordRange
        self.succeeded = succeeded
        self.localStarts = succeeded ? (localStarts ?? [0]) : nil
        self.errorDescription = (!succeeded) ? errorDescription : nil
    }

    /// 该块在全局词空间中的句起点（失败时为空）。
    public var globalStarts: [Int] {
        guard succeeded, let starts = localStarts else { return [] }
        return starts.map { wordRange.lowerBound + $0 }
    }

    /// 该块回退用的原始句起点（来自 transcript 原句边界）。
    public func fallbackStarts(sentences: [TranscriptSentence]) -> [Int] {
        guard sentenceRange.count > 0 else { return [] }
        var s: [Int] = [sentences[sentenceRange.lowerBound].words.lowerBound]
        for i in sentenceRange.dropFirst() {
            s.append(sentences[i].words.lowerBound)
        }
        return s
    }
}

/// 完整断句结果：合并后的句起点 + 逐块详情。
public struct SegmentationResult: Sendable {
    /// 合并后的句起点词下标（升序，首元素恒为 0）。
    public let sentenceStarts: [Int]
    /// 逐块详情（按句顺序排列）。
    public let chunks: [ChunkResult]

    public init(sentenceStarts: [Int], chunks: [ChunkResult]) {
        self.sentenceStarts = sentenceStarts
        self.chunks = chunks
    }

    /// 是否有失败块。
    public var hasFailures: Bool { chunks.contains { !$0.succeeded } }
    /// 失败块数量。
    public var failureCount: Int { chunks.filter { !$0.succeeded }.count }
    /// 失败块索引列表。
    public var failedChunkIndices: [Int] {
        chunks.enumerated().compactMap { $0.element.succeeded ? nil : $0.offset }
    }
}

// MARK: - 断句引擎

/// AI 语义断句：LLM 只返回**分行文本**（其擅长的形态），断点词下标由本地
/// 对齐算法反推——遵守"LLM 永不产生数字入库"的铁律；任何增删改字都会被
/// 对齐校验拒绝。产出作为 `TranscriptPatch.sentenceStarts` 走 PatchSession，
/// 与手动拆/合句同一状态机制，一步可 undo。
///
/// 长视频策略：按句分块（默认 ~25 句/块），每块独立发 LLM。
/// - 短文本（≤25 句）走单请求快路径
/// - 任一块 LLM 改动文字 → 该块退回原始断句，其余块正常
/// - 通过 `onChunkComplete` 回调逐块报告进度
/// - 失败块可通过 `retryChunk` 精确重试
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

    // MARK: - 公共 API

    /// 全文断句，返回逐块结果。
    /// - Parameter onChunkComplete: 每块完成时的回调 (已完成数, 总数, 该块是否成功)。
    ///   在任意队列上调用；UI 层应自行调度到主 actor。
    public func proposeSentenceStarts(
        for transcript: Transcript,
        onChunkComplete: (@Sendable (Int, Int, Bool) -> Void)? = nil
    ) async throws -> SegmentationResult {
        let sentences = transcript.sentences
        guard !sentences.isEmpty else {
            return SegmentationResult(sentenceStarts: [0], chunks: [])
        }

        // 短文本：单请求快路径
        if sentences.count <= chunkSize {
            return try await singleRequestWithResult(for: transcript, onChunkComplete: onChunkComplete)
        }

        // 长文本：分块处理
        return try await chunkedRequestsWithResult(for: transcript, onChunkComplete: onChunkComplete)
    }

    /// 重试单个失败的块。传入上次结果的 `chunkIndex`。
    /// 返回新的 ChunkResult 可直接替换到 `SegmentationResult` 中。
    public func retryChunk(
        for transcript: Transcript,
        chunkIndex: Int,
        previousResult: SegmentationResult
    ) async throws -> ChunkResult {
        guard chunkIndex < previousResult.chunks.count else {
            throw LLMError.badResponse("块索引 \(chunkIndex) 超出范围")
        }
        let chunk = previousResult.chunks[chunkIndex]
        let words = transcript.words
        let chunkWords = Array(words[chunk.wordRange])

        do {
            let fullText = chunkWords.map(\.text).joined()
            let reply = try await client.complete(system: Self.systemPrompt, user: fullText)
            let localStarts = try Self.align(
                wordTexts: chunkWords.map(\.text),
                lines: reply.split(separator: "\n").map(String.init))
            return ChunkResult(
                sentenceRange: chunk.sentenceRange,
                wordRange: chunk.wordRange,
                succeeded: true,
                localStarts: localStarts,
                errorDescription: nil)
        } catch {
            return ChunkResult(
                sentenceRange: chunk.sentenceRange,
                wordRange: chunk.wordRange,
                succeeded: false,
                localStarts: nil,
                errorDescription: error.localizedDescription)
        }
    }

    /// 将重试后的块合并回完整结果。
    public static func mergeRetriedChunk(
        _ newChunk: ChunkResult,
        at chunkIndex: Int,
        into result: SegmentationResult,
        transcript: Transcript
    ) -> SegmentationResult {
        var newChunks = result.chunks
        newChunks[chunkIndex] = newChunk

        // 重新合并：成功块用 LLM 结果，失败块用原始断句
        let sentences = transcript.sentences
        var allStarts: Set<Int> = [0]
        for chunk in newChunks {
            if chunk.succeeded, let starts = chunk.localStarts {
                for s in starts.dropFirst() {
                    allStarts.insert(chunk.wordRange.lowerBound + s)
                }
            } else {
                for s in chunk.fallbackStarts(sentences: sentences).dropFirst() {
                    allStarts.insert(s)
                }
            }
        }
        return SegmentationResult(sentenceStarts: allStarts.sorted(), chunks: newChunks)
    }

    // MARK: - 单请求

    private func singleRequestWithResult(
        for transcript: Transcript,
        onChunkComplete: (@Sendable (Int, Int, Bool) -> Void)?
    ) async throws -> SegmentationResult {
        let words = transcript.words
        let sentenceRange = 0..<transcript.sentences.count
        let wordRange = 0..<words.count

        do {
            let fullText = words.map(\.text).joined()
            let reply = try await client.complete(system: Self.systemPrompt, user: fullText)
            let starts = try Self.align(wordTexts: words.map(\.text),
                                        lines: reply.split(separator: "\n").map(String.init))
            let chunk = ChunkResult(sentenceRange: sentenceRange, wordRange: wordRange,
                                    succeeded: true, localStarts: starts, errorDescription: nil)
            onChunkComplete?(1, 1, true)
            return SegmentationResult(sentenceStarts: starts, chunks: [chunk])
        } catch {
            let chunk = ChunkResult(sentenceRange: sentenceRange, wordRange: wordRange,
                                    succeeded: false, localStarts: nil,
                                    errorDescription: error.localizedDescription)
            onChunkComplete?(1, 1, false)
            // 单块失败 → 回退到原始断句
            return SegmentationResult(
                sentenceStarts: transcript.sentences.map(\.words.lowerBound),
                chunks: [chunk])
        }
    }

    // MARK: - 分块处理

    private func chunkedRequestsWithResult(
        for transcript: Transcript,
        onChunkComplete: (@Sendable (Int, Int, Bool) -> Void)?
    ) async throws -> SegmentationResult {
        let sentences = transcript.sentences
        let words = transcript.words
        let totalChunks = (sentences.count + chunkSize - 1) / chunkSize
        var chunks: [ChunkResult] = []
        var allStarts: Set<Int> = [0]

        var chunkStart = 0
        while chunkStart < sentences.count {
            let chunkEnd = min(chunkStart + chunkSize, sentences.count)
            let chunkSentences = sentences[chunkStart..<chunkEnd]
            let sentenceRange = chunkStart..<chunkEnd
            let wordRange = (chunkSentences.first!.words.lowerBound
                             ..< chunkSentences.last!.words.upperBound)
            let chunkWords = Array(words[wordRange])
            let chunkIndex = chunks.count

            let chunkResult: ChunkResult
            do {
                let fullText = chunkWords.map(\.text).joined()
                let reply = try await client.complete(system: Self.systemPrompt, user: fullText)
                let localStarts = try Self.align(
                    wordTexts: chunkWords.map(\.text),
                    lines: reply.split(separator: "\n").map(String.init))
                chunkResult = ChunkResult(sentenceRange: sentenceRange, wordRange: wordRange,
                                          succeeded: true, localStarts: localStarts,
                                          errorDescription: nil)
                for s in localStarts.dropFirst() {
                    allStarts.insert(wordRange.lowerBound + s)
                }
            } catch {
                chunkResult = ChunkResult(sentenceRange: sentenceRange, wordRange: wordRange,
                                          succeeded: false, localStarts: nil,
                                          errorDescription: error.localizedDescription)
                for s in chunkSentences.dropFirst() {
                    allStarts.insert(s.words.lowerBound)
                }
            }

            chunks.append(chunkResult)
            onChunkComplete?(chunkIndex + 1, totalChunks, chunkResult.succeeded)
            chunkStart = chunkEnd
        }

        // 所有块都失败 → 抛出最后一个块的错误
        let allFailed = chunks.allSatisfy { !$0.succeeded }
        if allFailed {
            let firstError = chunks.compactMap(\.errorDescription).first ?? "未知错误"
            throw LLMError.badResponse("所有段落断句均失败：\(firstError)")
        }

        return SegmentationResult(sentenceStarts: allStarts.sorted(), chunks: chunks)
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
