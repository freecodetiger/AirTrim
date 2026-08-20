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

        // MARK: Suggestion 生命周期（accept 与手动精确剪是区间进 EditList 的两个入口）

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

        /// 一键全收 proposed。verbosity 在模型层硬性拒绝（D-M3-2，防线不只靠 UI）：
        /// 废话建议必须人工逐条/按类确认（CLAUDE.md 禁止事项）
        public mutating func acceptAllProposed(of kind: EditSuggestion.Kind) {
            guard kind != .verbosity else { return }
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

        /// 重置某类建议的全部记录（含 accepted/rejected），并移除已应用的剪辑区间。
        /// 用于参数驱动重分析（如紧凑度滑杆），让用户在新参数下重新决策。
        public mutating func resetKind(_ kind: EditSuggestion.Kind) {
            for s in suggestions where s.kind == kind && s.state == .accepted {
                edits.remove(overlapping: s.cut)
            }
            suggestions.removeAll { $0.kind == kind }
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

    /// 不入 undo 栈的直接修改（D-EAS-2：自动断句属"环境准备"，非用户编辑）。
    /// 用户手动「AI 断句」仍必须走 apply（可撤销）。
    public mutating func applyWithoutUndo(_ mutate: (inout Snapshot) -> Void) {
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
