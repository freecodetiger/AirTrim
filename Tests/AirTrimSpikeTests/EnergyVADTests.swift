import Foundation
import Testing
@testable import AirTrimSpikeKit

@Suite("能量 VAD")
struct EnergyVADTests {
    let sr = 16000.0

    func tone(_ seconds: Double, amplitude: Float = 0.5) -> [Float] {
        (0..<Int(seconds * sr)).map { amplitude * sin(Float($0) * 2 * .pi * 440 / Float(sr)) }
    }

    func noise(_ seconds: Double, amplitude: Float = 0.001) -> [Float] {
        var rng = SystemRandomNumberGenerator()
        return (0..<Int(seconds * sr)).map { _ in Float.random(in: -amplitude...amplitude, using: &rng) }
    }

    @Test func findsSilenceBetweenSpeech() {
        let samples = tone(1.0) + noise(1.0) + tone(1.0)
        let silences = EnergyVAD.silences(samples: samples, sampleRate: sr, minDuration: 0.5)
        #expect(silences.count == 1)
        let s = silences[0]
        #expect(abs(s.lowerBound - 1.0) < 0.1)
        #expect(abs(s.upperBound - 2.0) < 0.1)
    }

    @Test func shortSilenceIgnored() {
        let samples = tone(1.0) + noise(0.3) + tone(1.0)
        #expect(EnergyVAD.silences(samples: samples, sampleRate: sr, minDuration: 0.5).isEmpty)
    }

    @Test func trailingSilenceDetected() {
        let samples = tone(1.0) + noise(0.8)
        let silences = EnergyVAD.silences(samples: samples, sampleRate: sr, minDuration: 0.5)
        #expect(silences.count == 1)
        #expect(abs(silences[0].upperBound - 1.8) < 0.1)
    }

    @Test func allSpeechHasNoSilence() {
        #expect(EnergyVAD.silences(samples: tone(2.0), sampleRate: sr, minDuration: 0.5).isEmpty)
    }

    @Test func emptyInputIsSafe() {
        #expect(EnergyVAD.silences(samples: [], sampleRate: sr).isEmpty)
    }
}
