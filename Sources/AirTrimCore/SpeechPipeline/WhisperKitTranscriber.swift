import CoreMedia
import Foundation
import WhisperKit

/// 转写阶段（真实进度，供 UI 展示；分数只用于显示，非权威时间）
public enum TranscribePhase: Sendable, Equatable {
    case loadingModel
    /// 云端：音频上传 / 任务提交 / 轮询中（无确定分数）
    case uploading
    case transcribing(Double)  // 0...1
}

/// 转写引擎协议：面向协议便于测试与将来换引擎（ADR-0006 备选 FunASR）。
public protocol Transcriber: Sendable {
    /// - Parameters:
    ///   - audioPath: 源媒体路径（引擎自行解码）
    ///   - pcm: 16kHz 单声道 PCM（VAD 融合用，由 MediaEngine 抽取，组合根传入）
    ///   - onProgress: 阶段/进度回调（任意线程调用）
    func transcribe(audioPath: String, pcm: [Float], language: String,
                    onProgress: (@Sendable (TranscribePhase) -> Void)?) async throws -> Transcript
}

public extension Transcriber {
    func transcribe(audioPath: String, pcm: [Float], language: String) async throws -> Transcript {
        try await transcribe(audioPath: audioPath, pcm: pcm, language: language, onProgress: nil)
    }
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

    /// Foundation.Progress 非 Sendable 但 fractionCompleted 线程安全（内部加锁），
    /// 只为跨 Task 轮询展示进度而包装
    private final class ProgressBox: @unchecked Sendable {
        let progress: Progress
        init(_ progress: Progress) { self.progress = progress }
    }

    public func transcribe(audioPath: String, pcm: [Float], language: String = "zh",
                           onProgress: (@Sendable (TranscribePhase) -> Void)? = nil) async throws -> Transcript {
        let config = WhisperKitConfig(
            model: modelFolder.lastPathComponent,
            modelFolder: modelFolder.path,
            tokenizerFolder: tokenizerFolder,
            download: false
        )
        onProgress?(.loadingModel)
        let pipe = try await WhisperKit(config)
        if language.hasPrefix("zh"), let tok = pipe.tokenizer {
            pipe.tokenizer = ZhWordSplitTokenizer(wrapping: tok)
        }

        let options = DecodingOptions(task: .transcribe, language: language, wordTimestamps: true)
        onProgress?(.transcribing(0))
        let box = ProgressBox(pipe.progress)
        let poller = Task {
            while !Task.isCancelled {
                onProgress?(.transcribing(min(1, max(0, box.progress.fractionCompleted))))
                try await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        defer { poller.cancel() }
        let results = try await pipe.transcribe(audioPath: audioPath, decodeOptions: options)
        poller.cancel()
        onProgress?(.transcribing(1))

        let duration = CMTime(value: CMTimeValue(pcm.count), timescale: Self.sampleRate)
        let rawWords = results.flatMap(\.allWords).map { timing in
            (text: timing.word, start: Double(timing.start), end: Double(timing.end))
        }
        // 归一化 / VAD 融合 / 断句 → 两引擎共用（TranscriptAssembly）
        return TranscriptAssembly.makeTranscript(rawWords: rawWords, pcm: pcm, sourceDuration: duration)
    }
}
