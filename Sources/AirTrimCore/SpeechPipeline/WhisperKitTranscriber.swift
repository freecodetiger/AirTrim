import CoreMedia
import Foundation
import WhisperKit

/// 转写引擎协议：面向协议便于测试与将来换引擎（ADR-0006 备选 FunASR）。
public protocol Transcriber: Sendable {
    /// - Parameters:
    ///   - audioPath: 源媒体路径（引擎自行解码）
    ///   - pcm: 16kHz 单声道 PCM（VAD 融合用，由 MediaEngine 抽取，组合根传入）
    func transcribe(audioPath: String, pcm: [Float], language: String) async throws -> Transcript
}

/// WhisperKit 适配（ADR-0006）。职责：
/// 1. 只加载本地模型目录，**永不下载**（设计 D1；下载归 App 层 ModelInstaller）
/// 2. 中文逐字切词（上游 PR #511 合并前用 ZhWordSplitTokenizer 注入）
/// 3. VAD 融合：词首落入静音的吸附到静音终点（词首漂早中位 -230ms，M0 实测）
/// 4. 简繁归一化 + 断句 → 不可变 Transcript
public struct WhisperKitTranscriber: Transcriber {
    public let modelFolder: URL
    /// 本地 tokenizer 目录（含 tokenizer.json）；nil 时 WhisperKit 会回退到
    /// 其 Hub 缓存（可能触网），ModelInstaller 装机后应始终提供
    public let tokenizerFolder: URL?
    /// PCM 采样率（AudioLoader/PCMExtractor 约定 16kHz）
    public static let sampleRate: Int32 = 16000

    public init(modelFolder: URL, tokenizerFolder: URL? = nil) {
        self.modelFolder = modelFolder
        self.tokenizerFolder = tokenizerFolder
    }

    public func transcribe(audioPath: String, pcm: [Float], language: String = "zh") async throws -> Transcript {
        let config = WhisperKitConfig(
            model: modelFolder.lastPathComponent,
            modelFolder: modelFolder.path,
            tokenizerFolder: tokenizerFolder,
            download: false
        )
        let pipe = try await WhisperKit(config)
        if language.hasPrefix("zh"), let tok = pipe.tokenizer {
            pipe.tokenizer = ZhWordSplitTokenizer(wrapping: tok)
        }

        let options = DecodingOptions(task: .transcribe, language: language, wordTimestamps: true)
        let results = try await pipe.transcribe(audioPath: audioPath, decodeOptions: options)

        let silences = EnergyVAD.silences(samples: pcm, sampleRate: Self.sampleRate)
        let duration = CMTime(value: CMTimeValue(pcm.count), timescale: Self.sampleRate)

        var words: [TranscriptWord] = []
        for timing in results.flatMap(\.allWords) {
            let text = ZhNormalizer.simplified(timing.word.trimmingCharacters(in: .whitespaces))
            guard !text.isEmpty else { continue }
            var start = CMTime(seconds: Double(timing.start), preferredTimescale: Self.sampleRate)
            var end = CMTime(seconds: Double(timing.end), preferredTimescale: Self.sampleRate)
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
            sourceDuration: duration
        )
    }
}
