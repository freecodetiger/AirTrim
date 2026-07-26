import Foundation

/// 能量 VAD（spike 版）：帧 RMS + 自适应噪声底估计，找 ≥ minDuration 的静音区间。
/// 纯函数、可测；产品版 VAD 属于 SpeechPipeline，届时按此思路以 CMTime 重写。
public enum EnergyVAD {
    /// - Parameters:
    ///   - samples: 单声道 PCM（任意幅度标度，内部只看相对能量）
    ///   - sampleRate: 采样率（Hz）
    ///   - frameDuration: 分析帧长（秒）
    ///   - marginDB: 语音判定阈值 = 噪声底 + margin（dB）
    ///   - minDuration: 只报告 ≥ 此时长的静音（秒）
    public static func silences(
        samples: [Float],
        sampleRate: Double,
        frameDuration: Double = 0.02,
        marginDB: Double = 10,
        minDuration: Double = 0.5
    ) -> [ClosedRange<Double>] {
        let frameLen = max(1, Int(frameDuration * sampleRate))
        guard samples.count >= frameLen, sampleRate > 0 else { return [] }

        var framesDB: [Double] = []
        framesDB.reserveCapacity(samples.count / frameLen)
        var i = 0
        while i + frameLen <= samples.count {
            var sum = 0.0
            for j in i..<(i + frameLen) {
                let s = Double(samples[j])
                sum += s * s
            }
            let rms = (sum / Double(frameLen)).squareRoot()
            framesDB.append(20 * log10(max(rms, 1e-10)))
            i += frameLen
        }

        // 噪声底 = 能量第 10 百分位
        let sorted = framesDB.sorted()
        let noiseFloor = sorted[Int(Double(sorted.count - 1) * 0.1)]
        let p90 = sorted[Int(Double(sorted.count - 1) * 0.9)]
        // 动态范围拉不开（全程说话/全程静音/恒定底噪）→ 无法可靠区分，宁可不剪
        guard p90 - noiseFloor >= marginDB else { return [] }
        let threshold = noiseFloor + marginDB

        var result: [ClosedRange<Double>] = []
        var silentStart: Int? = nil
        for (idx, db) in framesDB.enumerated() {
            if db < threshold {
                if silentStart == nil { silentStart = idx }
            } else if let s = silentStart {
                appendIfLongEnough(from: s, to: idx, into: &result)
                silentStart = nil
            }
        }
        if let s = silentStart {
            appendIfLongEnough(from: s, to: framesDB.count, into: &result)
        }
        return result

        func appendIfLongEnough(from startFrame: Int, to endFrame: Int, into out: inout [ClosedRange<Double>]) {
            let start = Double(startFrame) * frameDuration
            let end = Double(endFrame) * frameDuration
            if end - start >= minDuration { out.append(start...end) }
        }
    }
}
