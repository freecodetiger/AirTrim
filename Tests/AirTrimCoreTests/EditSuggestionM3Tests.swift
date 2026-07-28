import CoreMedia
import Foundation
import Testing
@testable import AirTrimCore

private func t(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 600)
}

private func r(_ from: Double, _ to: Double) -> CMTimeRange {
    CMTimeRange(start: t(from), end: t(to))
}

@Suite("EditSuggestion 生命周期（M3 扩展）")
struct EditSuggestionM3Tests {
    private func suggestion(_ kind: EditSuggestion.Kind,
                            _ from: Double, _ to: Double) -> EditSuggestion {
        EditSuggestion(kind: kind, cut: r(from, to), originalGap: r(from, to))
    }

    @Test("verbosity 永不进 acceptAllProposed（D-M3-2 模型层防线）")
    func acceptAllRejectsVerbosity() {
        var snapshot = EditSession.Snapshot()
        snapshot.suggestions = [suggestion(.verbosity, 1, 2),
                                suggestion(.verbosity, 3, 4)]
        snapshot.acceptAllProposed(of: .verbosity)
        #expect(snapshot.suggestions.allSatisfy { $0.state == .proposed })
        #expect(snapshot.edits.cuts.isEmpty)
    }

    @Test("pause/filler 一键全收正常工作")
    func acceptAllWorksForPauseAndFiller() {
        var snapshot = EditSession.Snapshot()
        snapshot.suggestions = [suggestion(.pause, 1, 2),
                                suggestion(.filler, 3, 4),
                                suggestion(.verbosity, 5, 6)]
        snapshot.acceptAllProposed(of: .pause)
        snapshot.acceptAllProposed(of: .filler)
        #expect(snapshot.edits.cuts == [r(1, 2), r(3, 4)])
        // verbosity 不受同批操作波及
        #expect(snapshot.suggestions.first { $0.kind == .verbosity }?.state == .proposed)
    }

    @Test("verbosity 逐条 accept 仍是合法路径")
    func verbosityIndividualAcceptAllowed() {
        var snapshot = EditSession.Snapshot()
        let s = suggestion(.verbosity, 1, 2)
        snapshot.suggestions = [s]
        snapshot.accept(suggestionID: s.id)
        #expect(snapshot.suggestions[0].state == .accepted)
        #expect(snapshot.edits.cuts == [r(1, 2)])
    }

    @Test("replaceProposed 按 kind 隔离，不动其他类别")
    func replaceProposedIsolatesKinds() {
        var snapshot = EditSession.Snapshot()
        snapshot.suggestions = [suggestion(.pause, 1, 2),
                                suggestion(.filler, 3, 4)]
        snapshot.replaceProposed(with: [suggestion(.filler, 5, 6)], of: .filler)
        #expect(snapshot.suggestions.filter { $0.kind == .pause }.count == 1)
        #expect(snapshot.suggestions.filter { $0.kind == .filler }.map(\.cut) == [r(5, 6)])
    }

    @Test("M3 新字段编解码往返；缺省字段解码为 nil（M2 档兼容）")
    func codableRoundTripAndBackwardCompat() throws {
        let full = EditSuggestion(kind: .verbosity, cut: r(1, 2), originalGap: r(1, 2),
                                  detail: "重复了开头的观点", confidence: 0.83,
                                  category: .repetition)
        let data = try JSONEncoder().encode(full)
        let decoded = try JSONDecoder().decode(EditSuggestion.self, from: data)
        #expect(decoded == full)

        // M2 时代的 JSON（无 detail/confidence/category）必须能解码
        let legacy = EditSuggestion(kind: .pause, cut: r(1, 2), originalGap: r(1, 2))
        var json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(legacy)) as! [String: Any]
        json.removeValue(forKey: "detail")
        json.removeValue(forKey: "confidence")
        json.removeValue(forKey: "category")
        let legacyData = try JSONSerialization.data(withJSONObject: json)
        let legacyDecoded = try JSONDecoder().decode(EditSuggestion.self, from: legacyData)
        #expect(legacyDecoded.detail == nil)
        #expect(legacyDecoded.confidence == nil)
        #expect(legacyDecoded.category == nil)
    }
}
