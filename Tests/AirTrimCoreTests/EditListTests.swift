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

@Suite("EditList：区间归并与时间轴换算")
struct EditListTests {
    @Test func addKeepsSortedAndMergesOverlaps() {
        var list = EditList()
        list.add(r(5, 6))
        list.add(r(1, 2))
        list.add(r(1.5, 3))     // 与 [1,2] 重叠 → 并成 [1,3]
        list.add(r(3, 4))       // 与 [1,3] 首尾相接 → 并成 [1,4]
        #expect(list.cuts == [r(1, 4), r(5, 6)])
    }

    @Test func zeroLengthCutIgnored() {
        var list = EditList()
        list.add(r(2, 2))
        #expect(list.cuts.isEmpty)
    }

    @Test func removeSplitsCut() {
        var list = EditList()
        list.add(r(1, 5))
        list.remove(overlapping: r(2, 3))
        #expect(list.cuts == [r(1, 2), r(3, 5)])
    }

    @Test func keepSegmentsAreComplement() {
        var list = EditList()
        list.add(r(1, 2))
        list.add(r(8, 9))
        let keeps = list.keepSegments(sourceDuration: t(10))
        #expect(keeps == [r(0, 1), r(2, 8), r(9, 10)])
    }

    @Test func keepSegmentsWithCutAtStart() {
        var list = EditList()
        list.add(r(0, 1))
        #expect(list.keepSegments(sourceDuration: t(3)) == [r(1, 3)])
    }

    @Test func outputTimeSubtractsPriorCuts() {
        var list = EditList()
        list.add(r(1, 2))
        list.add(r(4, 6))
        #expect(list.outputTime(forSource: t(0.5)) == t(0.5))
        #expect(list.outputTime(forSource: t(3)) == t(2))     // 扣掉 [1,2]
        #expect(list.outputTime(forSource: t(5)) == t(3))     // 剪切区间内 → 映射到切点
        #expect(list.outputTime(forSource: t(8)) == t(5))     // 扣掉共 3s
        #expect(list.outputDuration(sourceDuration: t(10)) == t(7))
    }

    @Test func sourceTimeIsInverseOnKeptRegions() {
        var list = EditList()
        list.add(r(1, 2))
        list.add(r(4, 6))
        for sourceSeconds in [0.0, 0.5, 2.5, 3.9, 6.1, 9.9] {
            let src = t(sourceSeconds)
            let roundTrip = list.sourceTime(forOutput: list.outputTime(forSource: src),
                                            sourceDuration: t(10))
            #expect(roundTrip == src, "往返失真 @\(sourceSeconds)s")
        }
        // 越界钳到源末尾
        #expect(list.sourceTime(forOutput: t(99), sourceDuration: t(10)) == t(10))
    }

    @Test func codableRoundTripPreservesRationalTime() throws {
        var list = EditList()
        list.add(CMTimeRange(start: CMTime(value: 1, timescale: 3),
                             duration: CMTime(value: 1, timescale: 7)))
        let back = try JSONDecoder().decode(EditList.self, from: JSONEncoder().encode(list))
        #expect(back == list)
        #expect(back.cuts[0].start.timescale == 3 && back.cuts[0].duration.timescale == 7)
    }
}

@Suite("EditSession：建议生命周期与唯一 undo 栈")
struct EditSessionTests {
    private func pauseSuggestion(_ from: Double, _ to: Double,
                                 gapFrom: Double? = nil, gapTo: Double? = nil) -> EditSuggestion {
        EditSuggestion(kind: .pause, cut: r(from, to),
                       originalGap: r(gapFrom ?? from, gapTo ?? to))
    }

    @Test func acceptIsTheOnlyPathIntoEditList() {
        var session = EditSession()
        let s = pauseSuggestion(1, 2)
        session.apply { $0.suggestions = [s] }
        #expect(session.current.edits.cuts.isEmpty)

        session.apply { $0.accept(suggestionID: s.id) }
        #expect(session.current.edits.cuts == [r(1, 2)])
        #expect(session.current.suggestions[0].state == .accepted)

        // 二次 accept 无效果（状态门卫）
        session.apply { $0.accept(suggestionID: s.id) }
        #expect(session.current.edits.cuts == [r(1, 2)])
    }

    @Test func acceptAllOnlyTouchesProposed() {
        var session = EditSession()
        let a = pauseSuggestion(1, 2)
        var b = pauseSuggestion(3, 4)
        b.state = .rejected
        session.apply { $0.suggestions = [a, b] }
        session.apply { $0.acceptAllProposed(of: .pause) }
        #expect(session.current.edits.cuts == [r(1, 2)])
        #expect(session.current.suggestions[1].state == .rejected)
    }

    @Test func replaceProposedDedupsAgainstRejectedAndAccepted() {
        var session = EditSession()
        let rejected = pauseSuggestion(1, 2)
        let accepted = pauseSuggestion(5, 6)
        session.apply { $0.suggestions = [rejected, accepted] }
        session.apply { $0.reject(suggestionID: rejected.id) }
        session.apply { $0.accept(suggestionID: accepted.id) }

        // 重跑：与 rejected 重叠的不再打扰；与 accepted 重叠的不出幽灵建议；新的保留
        let overlapRejected = pauseSuggestion(1.5, 2.5)
        let overlapAccepted = pauseSuggestion(5.5, 6.5)
        let fresh = pauseSuggestion(8, 9)
        session.apply { $0.replaceProposed(with: [overlapRejected, overlapAccepted, fresh],
                                           of: .pause) }
        let proposed = session.current.suggestions.filter { $0.state == .proposed }
        #expect(proposed.map(\.cut) == [r(8, 9)])
        #expect(session.current.suggestions.count == 3)   // rejected + accepted + fresh
    }

    @Test func undoRestoresWholeSnapshot() {
        var session = EditSession()
        let s = pauseSuggestion(1, 2)
        session.apply {
            $0.patch.textOverrides[0] = "改字"
            $0.suggestions = [s]
        }
        session.apply { $0.accept(suggestionID: s.id) }
        #expect(!session.current.edits.cuts.isEmpty)

        // 一次 undo 同时回退剪辑与建议状态（同一快照）
        let ok = session.undo()
        #expect(ok)
        #expect(session.current.edits.cuts.isEmpty)
        #expect(session.current.suggestions[0].state == .proposed)
        #expect(session.current.patch.textOverrides[0] == "改字")
    }

    @Test func snapshotCodableRoundTrips() throws {
        var snapshot = EditSession.Snapshot()
        snapshot.suggestions = [pauseSuggestion(1, 2)]
        snapshot.accept(suggestionID: snapshot.suggestions[0].id)
        snapshot.patch.textOverrides[3] = "x"
        let back = try JSONDecoder().decode(EditSession.Snapshot.self,
                                            from: JSONEncoder().encode(snapshot))
        #expect(back == snapshot)
    }
}
