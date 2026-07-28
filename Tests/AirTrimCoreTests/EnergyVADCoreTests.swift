import CoreMedia
import Foundation
import Testing
@testable import AirTrimCore

/// Core 版 EnergyVAD（SpeechPipeline/EnergyVAD.swift，非 SpikeKit 副本）。
/// 重点覆盖瞬态尖峰分裂——真实素材里一声咂嘴曾让 6 秒静音整段被 peakEnergy 过滤。
@Suite("能量 VAD（Core）")
struct CoreEnergyVADTests {
    let sr: Int32 = 16000

    private func tone(_ seconds: Double, amplitude: Float = 0.5) -> [Float] {
        (0..<Int(seconds * Double(sr))).map {
            amplitude * sin(Float($0) * 2 * .pi * 440 / Float(sr))
        }
    }

    private func noise(_ seconds: Double, amplitude: Float = 0.001) -> [Float] {
        var rng = SystemRandomNumberGenerator()
        return (0..<Int(seconds * Double(sr))).map { _ in
            Float.random(in: -amplitude...amplitude, using: &rng)
        }
    }

    /// 长静音中一个瞬态尖峰（咂嘴声/碰麦）不该污染整段：劈成两段干净子段
    @Test func transientSpikeSplitsSilenceIntoCleanSegments() {
        var quiet = noise(3.0)
        let spikeStart = Int(1.5 * Double(sr))            // 正中插一个 20ms 尖峰
        for k in 0..<Int(0.02 * Double(sr)) { quiet[spikeStart + k] = 0.6 }
        let samples = tone(1.0) + quiet + tone(1.0)
        let silences = EnergyVAD.silences(samples: samples, sampleRate: sr,
                                          minDuration: 0.5, spikePeak: 0.1)
        #expect(silences.count == 2)
        #expect(silences.allSatisfy { $0.peakEnergy <= 0.1 })
        // 两段合计仍覆盖原 3s 静音的绝大部分（只挖掉尖峰帧）
        let covered = silences.reduce(CMTime.zero) {
            CMTimeAdd($0, CMTimeSubtract($1.end, $1.start))
        }
        #expect(covered.seconds > 2.5)
    }

    /// 持续低语（多数帧超尖峰线）→ 碎段全被 minDuration 丢弃，宁可少剪不变
    @Test func sustainedMurmurStillRejected() {
        var murmur = noise(3.0)
        // 每 100ms 一个超线尖峰 → 子段全部 <0.5s
        var k = 0
        while k < murmur.count {
            murmur[k] = 0.3
            k += Int(0.1 * Double(sr))
        }
        let samples = tone(1.0) + murmur + tone(1.0)
        let silences = EnergyVAD.silences(samples: samples, sampleRate: sr,
                                          minDuration: 0.5, spikePeak: 0.1)
        #expect(silences.isEmpty)
    }

    /// 无尖峰的干净静音：行为与改动前一致（单段完整识别）
    @Test func cleanSilenceUnaffected() {
        let samples = tone(1.0) + noise(1.0) + tone(1.0)
        let silences = EnergyVAD.silences(samples: samples, sampleRate: sr,
                                          minDuration: 0.5)
        #expect(silences.count == 1)
        #expect(abs(silences[0].start.seconds - 1.0) < 0.1)
        #expect(abs(silences[0].end.seconds - 2.0) < 0.1)
    }
}
