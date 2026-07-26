import Foundation

/// 人工修订（设计 D3）：Transcript 保持不可变，所有改动放 Patch。
/// **改字永不改时间戳**（时间权威在 SpeechPipeline）。
///
/// 结构模型：句 = 起点词下标的切分；`sentenceStarts` 为 nil 时沿用原始断句。
/// 文本覆盖以**句起点词下标**为键——拆/合句时未波及句的键天然稳定；
/// 被拆/合的句子其文本覆盖作废（回到原始转写，v1 策略，undo 可回退）。
public struct TranscriptPatch: Sendable, Equatable {
    /// 句起点词下标全量表（升序，首元素恒为 0）；nil = 沿用 Transcript 原始断句
    public var sentenceStarts: [Int]?
    /// 句文本覆盖，键 = 句起点词下标
    public var textOverrides: [Int: String]

    public init(sentenceStarts: [Int]? = nil, textOverrides: [Int: String] = [:]) {
        self.sentenceStarts = sentenceStarts
        self.textOverrides = textOverrides
    }

    /// 结构编辑后的有效句列表（id 为位置序号，M3 的 LLM 契约引用它）
    public func effectiveSentences(in t: Transcript) -> [TranscriptSentence] {
        guard let starts = sentenceStarts else { return t.sentences }
        let sorted = starts.sorted()
        var out: [TranscriptSentence] = []
        for (i, s) in sorted.enumerated() {
            let end = i + 1 < sorted.count ? sorted[i + 1] : t.words.count
            if s < end { out.append(TranscriptSentence(id: out.count, words: s..<end)) }
        }
        return out
    }

    public func text(for sentence: TranscriptSentence, in t: Transcript) -> String {
        textOverrides[sentence.words.lowerBound] ?? t.sentenceText(sentence)
    }

    public mutating func overrideText(sentenceStartingAt start: Int, original: String, text: String) {
        if text == original {
            textOverrides.removeValue(forKey: start)
        } else {
            textOverrides[start] = text
        }
    }

    /// 在 wordIndex 前拆句（须落在某句中部）；该句的文本覆盖作废
    public mutating func split(before wordIndex: Int, in t: Transcript) {
        var starts = sentenceStarts ?? t.sentences.map(\.words.lowerBound)
        guard wordIndex > 0, wordIndex < t.words.count, !starts.contains(wordIndex) else { return }
        if let owner = starts.filter({ $0 < wordIndex }).max() {
            textOverrides.removeValue(forKey: owner)
        }
        starts.append(wordIndex)
        sentenceStarts = starts.sorted()
    }

    /// 将起点为 wordIndex 的句并入上一句；两句的文本覆盖作废
    public mutating func mergeWithPrevious(sentenceStartingAt wordIndex: Int, in t: Transcript) {
        var starts = sentenceStarts ?? t.sentences.map(\.words.lowerBound)
        guard wordIndex != 0, let idx = starts.firstIndex(of: wordIndex), idx > 0 else { return }
        textOverrides.removeValue(forKey: starts[idx - 1])
        textOverrides.removeValue(forKey: wordIndex)
        starts.remove(at: idx)
        sentenceStarts = starts
    }
}

/// undo = 快照栈（overview §4 EditSession 同款模式；M2 的 EditList 将并入同一会话）。
public struct PatchSession: Sendable, Equatable {
    public private(set) var current: TranscriptPatch
    public private(set) var history: [TranscriptPatch]

    public init(current: TranscriptPatch = TranscriptPatch()) {
        self.current = current
        self.history = []
    }

    /// 修改前先入栈快照
    public mutating func apply(_ mutate: (inout TranscriptPatch) -> Void) {
        history.append(current)
        mutate(&current)
    }

    @discardableResult
    public mutating func undo() -> Bool {
        guard let last = history.popLast() else { return false }
        current = last
        return true
    }

    public var canUndo: Bool { !history.isEmpty }
}
