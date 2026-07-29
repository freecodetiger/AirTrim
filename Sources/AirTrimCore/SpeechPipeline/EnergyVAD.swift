import CoreMedia
import Foundation

/// 能量 VAD 正式版（spike 验证毕业）：帧 RMS + 噪声底自适应 + 动态范围守卫。
/// 输出 CMTime 用采样数做分子（有理数精确，无浮点漂移）。
public enum EnergyVAD {
    public static func silences(
        samples: [Float],
        sampleRate: Int32,
        frameDuration: Double = 0.02,
        marginDB: Double = 8,
        minDuration: Double = 0.3,
        spikePeak: Float = 0.1
    ) -> [SilenceInterval] {
        let frameLen = max(1, Int(frameDuration * Double(sampleRate)))
        guard samples.count >= frameLen, sampleRate > 0 else { return [] }

        var framesDB: [Double] = []
        var framePeak: [Float] = []
        framesDB.reserveCapacity(samples.count / frameLen)
        var i = 0
        while i + frameLen <= samples.count {
            var sum = 0.0
            var peak: Float = 0
            for j in i..<(i + frameLen) {
                let s = samples[j]
                sum += Double(s) * Double(s)
                peak = max(peak, abs(s))
            }
            framesDB.append(20 * log10(max((sum / Double(frameLen)).squareRoot(), 1e-10)))
            framePeak.append(peak)
            i += frameLen
        }

        let sorted = framesDB.sorted()
        let noiseFloor = sorted[Int(Double(sorted.count - 1) * 0.1)]
        let p90 = sorted[Int(Double(sorted.count - 1) * 0.9)]
        // 动态范围拉不开（全程说话/全程静音/恒定底噪）→ 无法可靠区分，宁可不剪
        guard p90 - noiseFloor >= marginDB else { return [] }
        let threshold = noiseFloor + marginDB

        var result: [SilenceInterval] = []
        var silentStart: Int? = nil
        // 瞬态尖峰帧（RMS 低但 peak 超线，如咀嘴声/碰麦）分裂静音段而非污染整段：
        // 孤立喀嗒 → 两侧干净子段保留；持续低语 → 碎段被 minDuration 丢弃（宁可少剪不变）
        func emit(from s: Int, to e: Int) {
            var subStart = s
            for idx in s..<e where framePeak[idx] > spikePeak {
                emitClean(from: subStart, to: idx)
                subStart = idx + 1
            }
            emitClean(from: subStart, to: e)
        }
        func emitClean(from s: Int, to e: Int) {
            guard Double(e - s) * frameDuration >= minDuration else { return }
            result.append(SilenceInterval(
                start: CMTime(value: CMTimeValue(s * frameLen), timescale: sampleRate),
                end: CMTime(value: CMTimeValue(e * frameLen), timescale: sampleRate),
                peakEnergy: framePeak[s..<e].max() ?? 0
            ))
        }
        for (idx, db) in framesDB.enumerated() {
            if db < threshold {
                if silentStart == nil { silentStart = idx }
            } else if let s = silentStart {
                emit(from: s, to: idx)
                silentStart = nil
            }
        }
        if let s = silentStart { emit(from: s, to: framesDB.count) }
        return result
    }
}
