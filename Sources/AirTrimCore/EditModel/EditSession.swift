import CoreMedia
import Foundation

/// 会话编辑状态 = 修订 + 剪辑 + 建议的整体快照 undo（edit-model skill 不变量 4）。
/// 取代 M1 的 PatchSession：全项目**唯一** undo 栈，值类型整体入栈。
public struct EditSession: Sendable, Equatable {
    public struct Snapshot: Sendable, Equatable, Codable {
        public var patch: TranscriptPatch
        public var edits: EditList
        public var suggestions: [EditSuggestion]

        public init(patch: TranscriptPatch = TranscriptPatch(),
                    edits: EditList = EditList(),
                    suggestions: [EditSuggestion] = []) {
            self.patch = patch
            self.edits = edits
            self.suggestions = suggestions
        }

        // MARK: Suggestion 生命周期（accept 是区间进 EditList 的唯一路径）

        public mutating func accept(suggestionID id: UUID) {
            guard let i = suggestions.firstIndex(where: { $0.id == id }),
                  suggestions[i].state == .proposed else { return }
            suggestions[i].state = .accepted
            edits.add(suggestions[i].cut)
        }

        public mutating func reject(suggestionID id: UUID) {
            guard let i = suggestions.firstIndex(where: { $0.id == id }),
                  suggestions[i].state == .proposed else { return }
            suggestions[i].state = .rejected
        }

        /// 一键紧凑：全收 proposed（pause/filler 可一键，verbosity 由调用方过滤——M3）
        public mutating func acceptAllProposed(of kind: EditSuggestion.Kind) {
            for s in suggestions where s.state == .proposed && s.kind == kind {
                accept(suggestionID: s.id)
            }
        }

        /// 重跑分析器：保留 accepted/rejected 记录；新 proposed 与已有记录按
        /// originalGap 重叠去重（拒绝过的不再打扰，已剪掉的不出幽灵建议）
        public mutating func replaceProposed(with fresh: [EditSuggestion], of kind: EditSuggestion.Kind) {
            let kept = suggestions.filter { $0.state != .proposed || $0.kind != kind }
            let additions = fresh.filter { candidate in
                candidate.kind == kind && !kept.contains { existing in
                    CMTimeCompare(
                        CMTimeRangeGetIntersection(existing.originalGap,
                                                   otherRange: candidate.originalGap).duration,
                        .zero) > 0
                }
            }
            suggestions = kept + additions
        }
    }

    public private(set) var current: Snapshot
    public private(set) var history: [Snapshot]

    public init(current: Snapshot = Snapshot()) {
        self.current = current
        self.history = []
    }

    /// 修改前先入栈快照
    public mutating func apply(_ mutate: (inout Snapshot) -> Void) {
        history.append(current)
        mutate(&current)
    }

    /// 不入 undo 栈的 proposed 刷新（紧凑度滑杆重跑分析属参数联动，非用户编辑；
    /// accept/reject 仍必须走 apply）
    public mutating func refreshProposed(with fresh: [EditSuggestion],
                                         of kind: EditSuggestion.Kind) {
        current.replaceProposed(with: fresh, of: kind)
    }

    @discardableResult
    public mutating func undo() -> Bool {
        guard let last = history.popLast() else { return false }
        current = last
        return true
    }

    public var canUndo: Bool { !history.isEmpty }
}
