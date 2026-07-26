import Foundation

/// 评测报告（Markdown），附到 docs/spikes/results/。
public enum Report {
    public static func markdown(
        transcript: SpikeTranscript,
        boundary: BoundaryErrorStats?,
        cer: Double?
    ) -> String {
        var out = "# Spike 评测报告 · \(transcript.engine)\n\n"
        out += "- 素材：`\(transcript.audioFile)`（\(format(transcript.audioDuration))s）\n"
        out += "- 转写耗时：\(format(transcript.transcribeSeconds))s · RTF **\(format(transcript.rtf))**"
        out += transcript.rtf <= 0.5 ? " ✅（≤0.5）\n" : " ❌（通过线 ≤0.5）\n"
        out += "- 词数：\(transcript.words.count)\n\n"

        if let b = boundary {
            out += "## 词边界误差（\(b.count) 个标注点）\n\n"
            out += "| 指标 | 值 | 通过线 |\n|---|---|---|\n"
            out += "| 中位数 | \(format(b.medianMs))ms | ≤80ms \(b.medianMs <= 80 ? "✅" : "❌") |\n"
            out += "| P95 | \(format(b.p95Ms))ms | ≤200ms \(b.p95Ms <= 200 ? "✅" : "❌") |\n"
            out += "| 最大 | \(format(b.maxMs))ms | — |\n\n"
            out += "误差分布（每桶 20ms，最后一桶 ≥200ms）：\n\n```\n"
            let maxCount = max(b.histogram.max() ?? 1, 1)
            for (i, n) in b.histogram.enumerated() {
                let label = i < 10 ? String(format: "%3d–%3dms", i * 20, (i + 1) * 20) : "  ≥200ms "
                let bar = String(repeating: "█", count: Int((Double(n) / Double(maxCount) * 30).rounded()))
                out += "\(label) |\(bar) \(n)\n"
            }
            out += "```\n\n"
        } else {
            out += "## 词边界误差\n\n（未提供标注，跳过）\n\n"
        }

        if let cer {
            out += "## 字错率 CER\n\n"
            out += "\(format(cer * 100))%（通过线 ≤8%，正常语速段）"
            out += cer <= 0.08 ? " ✅\n" : " ❌\n"
        }
        return out
    }

    static func format(_ v: Double) -> String {
        String(format: "%.1f", v)
    }
}
