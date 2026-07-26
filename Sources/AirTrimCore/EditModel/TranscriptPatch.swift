import Foundation

/// 人工修订（设计 D3）：Transcript 保持不可变，所有改动放 Patch。
/// v1 以句为粒度（字幕不需要词级覆盖）；**改字永不改时间戳**（时间权威在 SpeechPipeline）。
public struct TranscriptPatch: Sendable, Equatable {
    /// 句 id → 修正后全文
    public var sentenceTextOverrides: [Int: String]

    public init(sentenceTextOverrides: [Int: String] = [:]) {
        self.sentenceTextOverrides = sentenceTextOverrides
    }

    public func text(for sentence: TranscriptSentence, in transcript: Transcript) -> String {
        sentenceTextOverrides[sentence.id] ?? transcript.sentenceText(sentence)
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
