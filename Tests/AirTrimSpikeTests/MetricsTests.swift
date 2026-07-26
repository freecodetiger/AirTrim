import Testing
@testable import AirTrimSpikeKit

@Suite("边界误差")
struct BoundaryErrorTests {
    let words = [
        SpikeWord(text: "今天", start: 0.00, end: 0.40),
        SpikeWord(text: "天气", start: 0.55, end: 0.95),
        SpikeWord(text: "不错", start: 1.10, end: 1.50),
    ]

    @Test func exactMatchIsZero() {
        let stats = Metrics.boundaryErrors(annotated: [0.40, 0.55, 1.10], predictedWords: words)!
        #expect(stats.medianMs == 0)
        #expect(stats.p95Ms == 0)
    }

    @Test func nearestBoundaryIsUsed() {
        // 0.50 距离 0.40 与 0.55 中取近者 0.55 → 50ms
        let stats = Metrics.boundaryErrors(annotated: [0.50], predictedWords: words)!
        #expect(abs(stats.medianMs - 50) < 0.001)
    }

    @Test func medianAndP95() {
        let annotated = [0.40, 0.42, 0.45, 0.50, 0.75]  // 误差 0/20/50/50/200ms
        let stats = Metrics.boundaryErrors(annotated: annotated, predictedWords: words)!
        #expect(abs(stats.medianMs - 50) < 0.001)
        #expect(stats.maxMs > 100)
        #expect(stats.count == 5)
        #expect(stats.histogram.reduce(0, +) == 5)
    }

    @Test func passLineMatchesSpikeDoc() {
        let good = Metrics.boundaryErrors(annotated: [0.41, 0.56], predictedWords: words)!
        #expect(good.passes)
        let bad = Metrics.boundaryErrors(annotated: [0.85, 1.95, 2.4], predictedWords: words)!
        #expect(!bad.passes)
    }

    @Test func emptyInputsReturnNil() {
        #expect(Metrics.boundaryErrors(annotated: [], predictedWords: words) == nil)
        #expect(Metrics.boundaryErrors(annotated: [1.0], predictedWords: []) == nil)
    }
}

@Suite("字错率 CER")
struct CERTests {
    @Test func identicalIsZero() {
        #expect(Metrics.characterErrorRate(reference: "今天天气不错", hypothesis: "今天天气不错") == 0)
    }

    @Test func punctuationAndWhitespaceIgnored() {
        #expect(Metrics.characterErrorRate(
            reference: "今天，天气不错。",
            hypothesis: "今天 天气不错"
        ) == 0)
    }

    @Test func substitutionCounted() {
        // 6 个内容字，错 1 个
        let cer = Metrics.characterErrorRate(reference: "今天天气不错", hypothesis: "今天天七不错")
        #expect(abs(cer - 1.0 / 6.0) < 0.001)
    }

    @Test func caseInsensitiveLatin() {
        #expect(Metrics.characterErrorRate(reference: "OK 没问题", hypothesis: "ok没问题") == 0)
    }

    @Test func emptyHypothesisIsTotalError() {
        #expect(Metrics.characterErrorRate(reference: "今天", hypothesis: "") == 1.0)
    }
}

@Suite("百分位")
struct PercentileTests {
    @Test func interpolates() {
        let xs = [10.0, 20.0, 30.0, 40.0]
        #expect(abs(Metrics.percentile(xs, 0.5) - 25) < 0.001)
        #expect(Metrics.percentile(xs, 1.0) == 40)
        #expect(Metrics.percentile([7.0], 0.95) == 7)
    }
}
