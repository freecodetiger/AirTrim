import AVFoundation
import AirTrimCore
import AirTrimInstaller
import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// 应用状态机（组合根）：编排 MediaEngine 抽音频 → SpeechPipeline 转写，
/// 持有 Transcript 快照与 PatchSession；播放头是派生显示值，不是第二份时间状态。
@MainActor
final class AppModel: ObservableObject {
    enum Stage {
        case needsModel
        case idle
        case transcribing(fileName: String, startedAt: Date)
        case editor
        case failed(String)
    }

    @Published var stage: Stage = .idle
    @Published private(set) var transcript: Transcript?
    @Published private(set) var patches = PatchSession()
    @Published var sourceURL: URL?

    // 预览（UI 派生状态）
    @Published private(set) var player: AVPlayer?
    @Published private(set) var currentSentenceStart: Int?
    @Published private(set) var currentCueText: String?
    @Published private(set) var isPlaying = false
    private var timeObserver: Any?
    private var stopAt: CMTime?
    private var cachedCues: [SubtitleCue] = []

    private(set) var modelFolder: URL?

    static let appSupportModels = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AirTrim/Models", isDirectory: true)

    init() {
        modelFolder = Self.discoverModel()
        if modelFolder == nil { stage = .needsModel }
    }

    static func discoverModel() -> URL? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: appSupportModels, includingPropertiesForKeys: nil) else { return nil }
        // contentsOfDirectory(at:) 不跟随软链：先解析成真实路径再探测/返回
        return entries
            .map { $0.resolvingSymlinksInPath() }
            .first { url in
                (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil))?
                    .contains { $0.pathExtension == "mlmodelc" } ?? false
            }
    }

    func chooseModelFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "选择包含 *.mlmodelc 的 WhisperKit 模型目录（如 openai_whisper-large-v3）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        modelFolder = url
        stage = .idle
    }

    // MARK: - 应用内模型下载（设计 D1；网络只在 App 层）

    @Published private(set) var installProgress: InstallProgress?
    @Published private(set) var installError: String?

    func downloadModel() {
        guard installProgress == nil else { return }
        installError = nil
        let installer = ModelInstaller(manifest: .largeV3, destination: Self.appSupportModels)
        installProgress = InstallProgress(bytesDone: 0, bytesTotal: ModelManifest.largeV3.totalBytes,
                                          filesDone: 0, filesTotal: 27, currentFile: "准备中…")
        Task {
            do {
                let modelDir = try await installer.install { progress in
                    Task { @MainActor [weak self] in self?.installProgress = progress }
                }
                self.installProgress = nil
                self.modelFolder = modelDir
                self.stage = .idle
            } catch {
                self.installProgress = nil
                self.installError = error.localizedDescription
            }
        }
    }

    func chooseVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .audio]
        panel.message = "选择要转写的口播视频"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        start(url: url)
    }

    func start(url: URL) {
        guard let modelFolder else { stage = .needsModel; return }
        sourceURL = url
        stage = .transcribing(fileName: url.lastPathComponent, startedAt: Date())
        Task {
            do {
                let pcm = try await PCMExtractor.monoPCM(url: url)
                let tokenizerDir = modelFolder.appendingPathComponent("tokenizer")
                let transcriber = WhisperKitTranscriber(
                    modelFolder: modelFolder,
                    tokenizerFolder: FileManager.default.fileExists(atPath: tokenizerDir.path)
                        ? tokenizerDir : nil)
                let result = try await transcriber.transcribe(
                    audioPath: url.path, pcm: pcm, language: "zh")
                self.transcript = result
                self.patches = PatchSession()
                self.setupPlayer(url: url)
                self.refreshDerived()
                self.stage = .editor
            } catch {
                self.stage = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - 句列表（结构编辑后的有效句）

    var sentences: [TranscriptSentence] {
        guard let transcript else { return [] }
        return patches.current.effectiveSentences(in: transcript)
    }

    func sentenceText(_ s: TranscriptSentence) -> String {
        guard let transcript else { return "" }
        return patches.current.text(for: s, in: transcript)
    }

    func updateSentence(_ s: TranscriptSentence, text: String) {
        guard let transcript else { return }
        let original = transcript.sentenceText(s)
        guard text != patches.current.text(for: s, in: transcript) else { return }
        patches.apply {
            $0.overrideText(sentenceStartingAt: s.words.lowerBound, original: original, text: text)
        }
        refreshDerived()
    }

    func splitSentence(before wordIndex: Int) {
        guard let transcript else { return }
        patches.apply { $0.split(before: wordIndex, in: transcript) }
        refreshDerived()
    }

    func mergeWithPrevious(_ s: TranscriptSentence) {
        guard let transcript else { return }
        patches.apply { $0.mergeWithPrevious(sentenceStartingAt: s.words.lowerBound, in: transcript) }
        refreshDerived()
    }

    func undo() {
        if patches.undo() { refreshDerived() }
    }

    private func refreshDerived() {
        guard let transcript else { cachedCues = []; return }
        cachedCues = Subtitles.cues(transcript: transcript, patch: patches.current)
        objectWillChange.send()
    }

    // MARK: - 预览播放（UI 层；时间只从 Transcript 派生）

    private func setupPlayer(url: URL) {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        let player = AVPlayer(url: url)
        self.player = player
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 10), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.playbackTick(time) }
        }
    }

    private func playbackTick(_ time: CMTime) {
        isPlaying = player?.rate != 0
        if let stopAt, CMTimeCompare(time, stopAt) >= 0 {
            player?.pause()
            self.stopAt = nil
        }
        guard let transcript else { return }
        let sentence = patches.current.effectiveSentences(in: transcript).last { s in
            guard let range = transcript.sentenceRange(s) else { return false }
            return CMTimeCompare(range.start, time) <= 0
        }
        currentSentenceStart = sentence?.words.lowerBound
        currentCueText = cachedCues.last {
            CMTimeCompare($0.start, time) <= 0 && CMTimeCompare(time, $0.end) <= 0
        }?.text
    }

    func seek(to s: TranscriptSentence) {
        guard let transcript, let range = transcript.sentenceRange(s) else { return }
        stopAt = nil
        player?.seek(to: range.start, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// 双击试听整句：句首播到句尾自动停
    func playSentence(_ s: TranscriptSentence) {
        guard let transcript, let range = transcript.sentenceRange(s) else { return }
        stopAt = range.end
        player?.seek(to: range.start, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.player?.play() }
        }
    }

    func togglePlayback() {
        guard let player else { return }
        stopAt = nil
        player.rate == 0 ? player.play() : player.pause()
    }

    // MARK: - 导出

    func exportSRT() {
        guard transcript != nil else { return }
        let srt = Subtitles.srt(cachedCues)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
        panel.nameFieldStringValue = (sourceURL?.deletingPathExtension().lastPathComponent ?? "subtitles") + ".srt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(srt.utf8).write(to: url)
        } catch {
            stage = .failed("SRT 写入失败：\(error.localizedDescription)")
        }
    }
}
