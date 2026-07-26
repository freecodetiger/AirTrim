import CoreMedia
import Foundation
import Testing
@testable import AirTrimCore

@Suite("Transcript 持久化编码")
struct TranscriptCodableTests {
    @Test func roundTripPreservesRationalTime() throws {
        // 1/3 秒这类无限小数在 Double 下必失真；有理数编码必须原样保真
        let word = TranscriptWord(text: "测",
                                  start: CMTime(value: 1, timescale: 3),
                                  end: CMTime(value: 16000 * 7 + 1, timescale: 16000))
        let t = Transcript(words: [word],
                           sentences: [TranscriptSentence(id: 0, words: 0..<1)],
                           sourceDuration: CMTime(value: 3_359_060, timescale: 16000))

        let data = try JSONEncoder().encode(t)
        let back = try JSONDecoder().decode(Transcript.self, from: data)

        #expect(back == t)
        #expect(back.words[0].start.value == 1 && back.words[0].start.timescale == 3)
        #expect(back.words[0].end.value == 112001 && back.words[0].end.timescale == 16000)
    }

    @Test func patchRoundTrips() throws {
        let patch = TranscriptPatch(sentenceStarts: [0, 5, 12],
                                    textOverrides: [5: "改过的句子。"])
        let back = try JSONDecoder().decode(
            TranscriptPatch.self, from: JSONEncoder().encode(patch))
        #expect(back == patch)
    }
}
