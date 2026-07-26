import Foundation

/// 波形峰值降采样（轨道背景显示用；持久化进项目文档，缓存命中免重抽 PCM）。
/// 纯函数：每 bin 取绝对峰值，输出 0…1。显示端可再做 sqrt 等视觉缩放。
public enum WaveformPeaks {
    public static func compute(samples: [Float], bins: Int = 2000) -> [Float] {
        guard !samples.isEmpty, bins > 0 else { return [] }
        let binCount = min(bins, samples.count)
        var peaks = [Float](repeating: 0, count: binCount)
        let step = Double(samples.count) / Double(binCount)
        for bin in 0..<binCount {
            let lo = Int(Double(bin) * step)
            let hi = min(samples.count, max(lo + 1, Int(Double(bin + 1) * step)))
            var peak: Float = 0
            for i in lo..<hi { peak = max(peak, abs(samples[i])) }
            peaks[bin] = min(1, peak)
        }
        return peaks
    }
}
