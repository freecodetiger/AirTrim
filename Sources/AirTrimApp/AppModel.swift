import AVFoundation
import AirTrimCore
import AirTrimInstaller
import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// 应用状态机（组合根）：编排 MediaEngine 抽音频 → SpeechPipeline 转写，
/// 持有 Transcript 快照与 EditSession（修订+剪辑+建议的唯一 undo 栈）；
/// 播放头是派生显示值，不是第二份时间状态。
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
    // 转写真实进度（显示值；权威时间永远在 Transcript）
    @Published private(set) var transcribePhaseText = ""
    @Published private(set) var transcribeFraction: Double?
    @Published private(set) var transcript: Transcript?
    @Published private(set) var session = EditSession()
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
        // 冒烟/回归钩子：AIRTRIM_AUTOLOAD=<视频路径> 启动即转写直达编辑器
        if let auto = ProcessInfo.processInfo.environment["AIRTRIM_AUTOLOAD"],
           modelFolder != nil {
            start(url: URL(fileURLWithPath: auto))
        } else if let last = ProjectStore.lastOpenedURL() {
            // 恢复上次会话（缓存命中秒开；不满足条件则停在导入页）
            start(url: last)
        }
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

    func start(url: URL, forceRetranscribe: Bool = false) {
        // 缓存命中：转写 + 修订全部恢复，秒开（持久化设计 D7）
        if !forceRetranscribe, let doc = ProjectStore.load(for: url) {
            sourceURL = url
            transcript = doc.transcript
            session = EditSession(current: .init(patch: doc.patch,
                                                 edits: doc.edits ?? EditList(),
                                                 suggestions: doc.suggestions ?? []))
            setupPlayer(url: url)
            refreshDerived()
            stage = .editor
            return
        }
        guard let modelFolder else { stage = .needsModel; return }
        sourceURL = url
        stage = .transcribing(fileName: url.lastPathComponent, startedAt: Date())
        transcribePhaseText = "抽取音频…"
        transcribeFraction = nil
        Task {
            do {
                let pcm = try await PCMExtractor.monoPCM(url: url)
                self.warnIfLong(pcmSampleCount: pcm.count)
                let tokenizerDir = modelFolder.appendingPathComponent("tokenizer")
                let transcriber = WhisperKitTranscriber(
                    modelFolder: modelFolder,
                    tokenizerFolder: FileManager.default.fileExists(atPath: tokenizerDir.path)
                        ? tokenizerDir : nil)
                let result = try await transcriber.transcribe(
                    audioPath: url.path, pcm: pcm, language: "zh"
                ) { phase in
                    Task { @MainActor [weak self] in self?.apply(phase) }
                }
                self.transcript = result
                self.session = EditSession()
                self.setupPlayer(url: url)
                self.refreshDerived()
                self.stage = .editor
                ProjectStore.save(source: url, transcript: result, snapshot: self.session.current)
            } catch let error as MediaEngineError {
                self.stage = .failed(error.localizedDescription)
            } catch {
                // 非媒体错误大概率是模型加载/推理失败——给出可行动的出路
                self.stage = .failed("转写失败：\(error.localizedDescription)\n若模型文件不完整，可在「设置 → 模型」重新下载校验。")
            }
        }
    }

    private func apply(_ phase: TranscribePhase) {
        switch phase {
        case .loadingModel:
            transcribePhaseText = "加载模型…（约十几秒）"
            transcribeFraction = nil
        case .transcribing(let fraction):
            transcribePhaseText = "本地转写中…"
            transcribeFraction = fraction
        }
    }

    /// M1 建议 ≤30 分钟（长素材内存/耗时优化留 M2，见设计文档风险表）
    private func warnIfLong(pcmSampleCount: Int) {
        let minutes = Double(pcmSampleCount) / Double(PCMExtractor.sampleRate) / 60
        if minutes > 30 {
            transcribePhaseText = "素材长约 \(Int(minutes)) 分钟——M1 建议 30 分钟以内，转写会比较慢"
        }
    }

    // MARK: - 句列表（结构编辑后的有效句）

    var sentences: [TranscriptSentence] {
        guard let transcript else { return [] }
        return session.current.patch.effectiveSentences(in: transcript)
    }

    func sentenceText(_ s: TranscriptSentence) -> String {
        guard let transcript else { return "" }
        return session.current.patch.text(for: s, in: transcript)
    }

    func updateSentence(_ s: TranscriptSentence, text: String) {
        guard let transcript else { return }
        let original = transcript.sentenceText(s)
        guard text != session.current.patch.text(for: s, in: transcript) else { return }
        session.apply {
            $0.patch.overrideText(sentenceStartingAt: s.words.lowerBound, original: original, text: text)
        }
        refreshDerived()
    }

    func splitSentence(before wordIndex: Int) {
        guard let transcript else { return }
        session.apply { $0.patch.split(before: wordIndex, in: transcript) }
        refreshDerived()
    }

    func mergeWithPrevious(_ s: TranscriptSentence) {
        guard let transcript else { return }
        session.apply { $0.patch.mergeWithPrevious(sentenceStartingAt: s.words.lowerBound, in: transcript) }
        refreshDerived()
    }

    func undo() {
        if session.undo() { refreshDerived() }
    }

    // MARK: - AI 语义断句（LLMProvider · 只上传文字稿 · 结果走 EditSession 可 undo）

    @Published var aiSegmenting = false
    @Published var aiError: String?

    func aiResegment() {
        guard let transcript, !aiSegmenting else { return }
        guard let config = LLMSettings.load() else {
            aiError = LLMError.notConfigured.localizedDescription
            return
        }
        aiSegmenting = true
        Task {
            do {
                let segmenter = SemanticSegmenter(client: OpenAIChatClient(config: config))
                let starts = try await segmenter.proposeSentenceStarts(for: transcript)
                session.apply { $0.patch.sentenceStarts = starts }
                refreshDerived()
            } catch {
                aiError = error.localizedDescription
            }
            aiSegmenting = false
        }
    }

    private func refreshDerived() {
        guard let transcript else { cachedCues = []; return }
        cachedCues = Subtitles.cues(transcript: transcript, patch: session.current.patch)
        // 每次修订即持久化（~100KB JSON，原子写）；关闭/崩溃零丢失
        if let sourceURL {
            ProjectStore.save(source: sourceURL, transcript: transcript, snapshot: session.current)
        }
        objectWillChange.send()
    }

    func retranscribe() {
        guard let sourceURL else { return }
        ProjectStore.discard(for: sourceURL)
        start(url: sourceURL, forceRetranscribe: true)
    }

    func closeVideo() {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player = nil
        transcript = nil
        session = EditSession()
        sourceURL = nil
        currentSentenceStart = nil
        currentCueText = nil
        stage = .idle
    }

    var lastProjectURL: URL? { ProjectStore.lastOpenedURL() }

    // MARK: - 模型管理（设置页）

    var modelDiskBytes: Int64? {
        guard let modelFolder,
              let files = FileManager.default.enumerator(
                  at: modelFolder, includingPropertiesForKeys: [.fileSizeKey]) else { return nil }
        var total: Int64 = 0
        for case let url as URL in files {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    func revealModelInFinder() {
        guard let modelFolder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([modelFolder])
    }

    /// 只删应用自管目录里的模型（用户自选的外部目录只解除引用，不动文件）
    func deleteModel() {
        guard let modelFolder else { return }
        let managedRoot = Self.appSupportModels.resolvingSymlinksInPath().path
        if modelFolder.resolvingSymlinksInPath().path.hasPrefix(managedRoot) {
            try? FileManager.default.removeItem(at: modelFolder)
        }
        self.modelFolder = nil
        if transcript == nil { stage = .needsModel }
    }

    /// 重新下载 = 清单校验 + 缺损补齐（installer 自动跳过完整文件）
    func repairModel() {
        stage = .needsModel
        downloadModel()
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
        let sentence = session.current.patch.effectiveSentences(in: transcript).last { s in
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

    @Published private(set) var burnProgress: Double?
    @Published var exportError: String?
    private var burnTask: Task<Void, Never>?

    /// 烧录字幕导出：整段直通 + CATextLayer 合成（MediaEngine 执行，设计 D4）
    func exportBurnedVideo() {
        guard let sourceURL, transcript != nil, burnProgress == nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = sourceURL.deletingPathExtension().lastPathComponent + "-字幕.mp4"
        guard panel.runModal() == .OK, let outputURL = panel.url else { return }
        burnProgress = 0
        let cues = cachedCues
        burnTask = Task {
            do {
                try await SubtitleBurner.burn(source: sourceURL, cues: cues, to: outputURL) { fraction in
                    Task { @MainActor [weak self] in self?.burnProgress = fraction }
                }
                NSWorkspace.shared.activateFileViewerSelecting([outputURL])
            } catch is CancellationError {
                // 用户取消：静默收场
            } catch {
                self.exportError = error.localizedDescription
            }
            self.burnProgress = nil
            self.burnTask = nil
        }
    }

    func cancelBurn() {
        burnTask?.cancel()
    }

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
            // 写入失败不该把整个编辑器打回 failed 死路，弹窗即可
            exportError = "SRT 写入失败：\(error.localizedDescription)"
        }
    }
}
