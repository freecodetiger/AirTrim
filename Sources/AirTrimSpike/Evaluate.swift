import AirTrimSpikeKit
import ArgumentParser
import Foundation

struct Evaluate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "对照人工标注评测转写结果（边界误差 / CER / RTF）"
    )

    @Option(help: "transcribe 输出的 JSON")
    var transcript: String

    @Option(help: "人工标注 ground truth JSON（gen-truth 生成模板）")
    var truth: String

    @Option(help: "Markdown 报告输出路径（缺省只打印摘要）")
    var report: String?

    func run() async throws {
        let t = try SpikeJSON.decode(
            SpikeTranscript.self,
            from: try Data(contentsOf: URL(fileURLWithPath: transcript))
        )
        let gt = try SpikeJSON.decode(
            GroundTruth.self,
            from: try Data(contentsOf: URL(fileURLWithPath: truth))
        )

        let boundary = Metrics.boundaryErrors(annotated: gt.boundaries, predictedWords: t.words)
        let cer = gt.referenceText.map { Metrics.characterErrorRate(reference: $0, hypothesis: t.text) }

        let md = Report.markdown(transcript: t, boundary: boundary, cer: cer)
        if let report {
            try Data(md.utf8).write(to: URL(fileURLWithPath: report))
            print("报告已写入 \(report)\n")
        }
        print(md)

        if let boundary {
            print(boundary.passes ? "== 边界精度：通过 ✅" : "== 边界精度：未达标 ❌")
        } else {
            print("== 标注为空，未评测边界（先跑 gen-truth 并人工标注）")
        }
    }
}

struct GenTruth: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gen-truth",
        abstract: "从转写结果生成人工标注模板（参考文本预填，边界可选预填供修正）"
    )

    @Option(help: "transcribe 输出的 JSON")
    var transcript: String

    @Option(help: "标注模板输出路径")
    var output: String

    @Option(name: .customLong("prefill-every"), help: "每 N 个词预填一个预测边界作起点（0 = 不预填）")
    var prefillEvery: Int = 0

    func run() async throws {
        let t = try SpikeJSON.decode(
            SpikeTranscript.self,
            from: try Data(contentsOf: URL(fileURLWithPath: transcript))
        )
        var boundaries: [Double] = []
        if prefillEvery > 0 {
            boundaries = stride(from: 0, to: t.words.count, by: prefillEvery)
                .map { t.words[$0].start }
        }
        let template = GroundTruth(referenceText: t.text, boundaries: boundaries)
        try SpikeJSON.encode(template).write(to: URL(fileURLWithPath: output))
        print("""
        模板已写入 \(output)
        标注流程（Audacity/Praat 逐帧看波形 + 听）：
          1. 校对 referenceText 为真实说的内容（CER 的分母）
          2. 在 boundaries 里填 ~100 个人工确认的词边界时刻（秒，小数）
             \(prefillEvery > 0 ? "已按每 \(prefillEvery) 词预填预测值，逐个修正即可" : "可加 --prefill-every 5 预填预测值作起点")
          3. 跑 evaluate --transcript … --truth …
        """)
    }
}
