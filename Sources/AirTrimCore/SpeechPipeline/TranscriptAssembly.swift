import CoreMedia
import Foundation

/// 转写后处理（本地 WhisperKit / 云端 paraformer 共用）：
/// 简繁归一化 → VAD 融合（词首吸附静音终点）→ 断句 → 不可变 `Transcript`。
/// 时间戳权威值仍产自本模块（ASR 词边界 + VAD），`TranscriptAssembly` 只做统一的归一/融合/断句。
public enum TranscriptAssembly {
    /// PCM 采样率（与 PCMExtractor / WhisperKitTranscriber 约定 16kHz）
    public static let sampleRate: Int32 = 16000

    /// - Parameters:
    ///   - rawWords: 引擎原始词（text + 秒起止，未归一化、未融合）
    ///   - pcm: 16kHz 单声道 PCM（VAD 融合用，由 MediaEngine 抽取）
    ///   - sourceDuration: 源媒体时长
    public static func makeTranscript(
        rawWords: [(text: String, start: Double, end: Double)],
        pcm: [Float],
        sourceDuration: CMTime
    ) -> Transcript {
        let silences = EnergyVAD.silences(samples: pcm, sampleRate: sampleRate)

        var words: [TranscriptWord] = []
        for raw in rawWords {
            let text = ZhNormalizer.simplified(raw.text.trimmingCharacters(in: .whitespaces))
            guard !text.isEmpty else { continue }
            var start = CMTime(seconds: raw.start, preferredTimescale: sampleRate)
            var end = CMTime(seconds: raw.end, preferredTimescale: sampleRate)
            // VAD 融合：词首在静音里 → 吸附到起音点；并保证区间不倒置
            if let s = silences.first(where: { CMTimeCompare(start, $0.start) >= 0 && CMTimeCompare(start, $0.end) <= 0 }) {
                start = s.end
            }
            if CMTimeCompare(end, start) < 0 { end = start }
            words.append(TranscriptWord(text: text, start: start, end: end))
        }

        return Transcript(
            words: words,
            sentences: SentenceSegmenter.sentences(words: words),
            silences: silences,
            sourceDuration: sourceDuration
        )
    }
}
