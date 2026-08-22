import CoreMedia
import Testing
@testable import AirTrimCore

@Suite("TranscriptAssembly：共享后处理（两引擎复用）")
struct TranscriptAssemblyTests {
    /// 构造 pcm：前 1s 静音 + 0.8s 语音（正弦）+ 尾静音
    private func pcmWithLeadingSilence() -> [Float] {
        var samples = [Float](repeating: 0, count: 16000)   // 1s 静音
        let frequency = 220.0
        for i in 0..<12800 {                                 // 0.8s 语音
            let phase = 2.0 * Double.pi * frequency * Double(i) / 16000.0
            samples.append(Float(sin(phase) * 0.4))
        }
        samples.append(contentsOf: [Float](repeating: 0, count: 8000))  // 0.5s 尾静音
        return samples
    }

    @Test func wordStartInsideSilenceSnapsToSilenceEnd() {
        let transcript = TranscriptAssembly.makeTranscript(
            rawWords: [(text: "你", start: 0.5, end: 0.6)],   // 词首落在前导静音里
            pcm: pcmWithLeadingSilence(),
            sourceDuration: CMTime(value: 36800, timescale: 16000)
        )
        #expect(transcript.words.count == 1)
        // 词首应吸附到静音终点（~1.0s），不再是 0.5s
        let snapped = transcript.words[0].start.seconds
        #expect(snapped >= 0.95 && snapped <= 1.1)
        #expect(!transcript.silences.isEmpty)
    }

    @Test func wordOutsideSilenceKeepsStart() {
        let transcript = TranscriptAssembly.makeTranscript(
            rawWords: [(text: "好", start: 1.3, end: 1.5)],   // 落在语音段内
            pcm: pcmWithLeadingSilence(),
            sourceDuration: CMTime(value: 36800, timescale: 16000)
        )
        #expect(transcript.words[0].start.seconds == 1.3)
    }

    @Test func normalizedToSimplifiedAndEndClamped() {
        let transcript = TranscriptAssembly.makeTranscript(
            rawWords: [
                (text: "這", start: 0.2, end: 0.3),          // 繁体 → 简
                (text: "壞", start: 0.5, end: 0.4),          // end < start → 不倒置
            ],
            pcm: pcmWithLeadingSilence(),
            sourceDuration: CMTime(value: 36800, timescale: 16000)
        )
        #expect(transcript.words[0].text == "这")
        #expect(transcript.words[1].text == "坏")
        #expect(transcript.words[1].end >= transcript.words[1].start)
    }
}

@Suite("CloudASRTranscriber：解析（纯函数）")
struct CloudASRParseTests {
    @Test func parseWordsExtractsPerCharTimestamps() {
        let json: [String: Any] = [
            "transcripts": [[
                "text": "你好",
                "sentences": [[
                    "begin_time": 0, "end_time": 800,
                    "words": [
                        ["begin_time": 100, "end_time": 400, "text": "你", "punctuation": ""],
                        ["begin_time": 400, "end_time": 800, "text": "好", "punctuation": ""],
                    ],
                ]],
            ]],
        ]
        let words = CloudASRTranscriber.parseWords(from: json)
        #expect(words.count == 2)
        #expect(words[0].text == "你")
        #expect(words[0].start == 0.1 && words[0].end == 0.4)   // ms → 秒
        #expect(words[1].text == "好")
        #expect(words[1].start == 0.4 && words[1].end == 0.8)
    }

    @Test func parseWordsSkipsEmptyAndPunctuationOnly() {
        let json: [String: Any] = [
            "transcripts": [[
                "text": "。",
                "sentences": [[
                    "begin_time": 0, "end_time": 100,
                    "words": [
                        ["begin_time": 0, "end_time": 100, "text": "  ", "punctuation": "。"],
                    ],
                ]],
            ]],
        ]
        #expect(CloudASRTranscriber.parseWords(from: json).isEmpty)
    }

    @Test func extractTranscriptionURLHandlesNestedPath() {
        let output: [String: Any] = [
            "task_status": "SUCCEEDED",
            "results": [[
                "output": [
                    "results": [["transcription_url": "https://example.com/result.json"]],
                ],
            ]],
        ]
        #expect(CloudASRTranscriber.extractTranscriptionURL(output)?.absoluteString == "https://example.com/result.json")
    }
}

@Suite("WAVEncoder：PCM → 16-bit 单声道 WAV")
struct WAVEncoderTests {
    @Test func producesRIFFHeaderAndRightSize() {
        let samples: [Float] = [0, 0.5, -0.5, 1.0]
        let wav = WAVEncoder.wav16(from: samples, sampleRate: 16000)
        #expect(wav.count == 44 + samples.count * 2)
        #expect(wav.prefix(4) == Data("RIFF".utf8))
        #expect(wav[8..<12] == Data("WAVE".utf8))
        #expect(wav[12..<16] == Data("fmt ".utf8))
    }
}

@Suite("CloudASRTranscriber：分段切块（任意时长）")
struct CloudASRChunkTests {
    private func sil(_ s: Double, _ e: Double) -> SilenceInterval {
        SilenceInterval(start: CMTime(seconds: s, preferredTimescale: 16000),
                        end: CMTime(seconds: e, preferredTimescale: 16000), peakEnergy: 0)
    }

    @Test func hardCutsWithoutSilences() {
        let ranges = CloudASRTranscriber.chunkRanges(
            silences: [], sampleCount: 400 * 16000, sampleRate: 16000,
            target: 180, max: 210, minTail: 30)
        #expect(ranges.count == 3)
        #expect(ranges[0].count == 180 * 16000)
        #expect(ranges[1].count == 180 * 16000)
        #expect(ranges[2].count == 40 * 16000)
    }

    @Test func cutsAtSilenceMidpointNearTarget() {
        let ranges = CloudASRTranscriber.chunkRanges(
            silences: [sil(176, 178)], sampleCount: 380 * 16000, sampleRate: 16000,
            target: 180, max: 210, minTail: 30)
        #expect(ranges[0].count == 177 * 16000)   // 切在 176–178s 静音中点，不切词
        #expect(ranges[1].lowerBound == 177 * 16000)
        #expect(ranges[1].count <= 210 * 16000)   // 并入尾段后仍不超硬上限
    }

    @Test func mergesTinyTailIntoPrevious() {
        let ranges = CloudASRTranscriber.chunkRanges(
            silences: [], sampleCount: 200 * 16000, sampleRate: 16000,
            target: 180, max: 210, minTail: 30)
        #expect(ranges.count == 1)               // 20s 尾段并入 → 单段
        #expect(ranges[0].count == 200 * 16000)
    }
}
