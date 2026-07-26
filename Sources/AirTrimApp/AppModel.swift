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
    /// 轨道波形背景（显示值，随项目文档持久化）
    @Published private(set) var waveformPeaks: [Float]?
    @Published var sourceURL: URL?

    // 预览（UI 派生状态）
    @Published private(set) var player: AVPlayer?
    @Published private(set) var currentSentenceStart: Int?
    @Published private(set) var currentCueText: String?
    @Published private(set) var isPlaying = false
    /// 时间轴/卡片联动的选中句（UI 状态，非剪辑状态）
    @Published var selectedSentenceStart: Int?
    /// 播放头在源时间轴上的显示值（秒，仅供 UI 绘制）
    @Published private(set) var currentSourceSeconds: Double = 0
    private var timeObserver: Any?
    private var stopAt: CMTime?
    /// 播放头的权威位置（源时间轴 CMTime；模式切换/重建 item 后据此复位）
    private var lastSourceTime: CMTime = .zero
    private var cachedCues: [SubtitleCue] = []
    var cues: [SubtitleCue] { cachedCues }

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
        // 视觉冒烟钩子：AIRTRIM_SNAPSHOT=<png路径> 启动 8s 后窗口自截图
        // （应用截自己的窗口无需屏幕录制权限；release 回归清单用）
        if let snapshotPath = ProcessInfo.processInfo.environment["AIRTRIM_SNAPSHOT"] {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if let view = NSApp.windows.first(where: { $0.isVisible })?.contentView,
                   let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: snapshotPath))
                }
            }
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
            waveformPeaks = doc.waveformPeaks
            setupPlayer(url: url)
            refreshDerived()
            stage = .editor
            rerunPauseAnalysis()
            backfillDerivedAudioIfNeeded(url: url)
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
                self.waveformPeaks = WaveformPeaks.compute(samples: pcm)
                self.setupPlayer(url: url)
                self.refreshDerived()
                self.stage = .editor
                self.rerunPauseAnalysis()
                ProjectStore.save(source: url, transcript: result, snapshot: self.session.current,
                                  waveformPeaks: self.waveformPeaks)
            } catch let error as MediaEngineError {
                self.stage = .failed(error.localizedDescription)
            } catch {
                // 非媒体错误大概率是模型加载/推理失败——给出可行动的出路
                self.stage = .failed("转写失败：\(error.localizedDescription)\n若模型文件不完整，可在「设置 → 模型」重新下载校验。")
            }
        }
    }

    /// v1 缓存补挂派生音频数据：silences（M2 分析输入）+ 波形峰值。
    /// 后台补算一次并回写；期间编辑不受阻（建议延迟出现，设计 m2 §7）。
    private func backfillDerivedAudioIfNeeded(url: URL) {
        guard let current = transcript,
              current.silences.isEmpty || waveformPeaks == nil else { return }
        Task {
            guard let pcm = try? await PCMExtractor.monoPCM(url: url) else { return }
            let (silences, peaks) = await Task.detached {
                (EnergyVAD.silences(samples: pcm, sampleRate: PCMExtractor.sampleRate),
                 WaveformPeaks.compute(samples: pcm))
            }.value
            guard self.sourceURL == url, let t = self.transcript else { return }
            if t.silences.isEmpty { self.transcript = t.withSilences(silences) }
            if self.waveformPeaks == nil { self.waveformPeaks = peaks }
            if let updated = self.transcript {
                ProjectStore.save(source: url, transcript: updated,
                                  snapshot: self.session.current,
                                  waveformPeaks: self.waveformPeaks)
            }
            self.rerunPauseAnalysis()   // silences 到位，建议此刻才可能出现
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
        if previewTightened { schedulePreviewRebuild() }
        objectWillChange.send()
    }

    // MARK: - 一键紧凑（M2）：分析 → 审阅 → 成片预览

    @Published var tightenIntensity: Double = 0.5
    @Published var previewTightened = false {
        didSet { if previewTightened != oldValue { refreshPlayerItem() } }
    }
    @Published var selectedSuggestionID: UUID?
    private var previewRebuild: Task<Void, Never>?
    private var auditioning = false

    var proposedPauses: [EditSuggestion] {
        session.current.suggestions.filter { $0.state == .proposed && $0.kind == .pause }
    }

    /// 建议可省的总时长（proposed，秒，显示值）
    var proposedSavings: Double {
        proposedPauses.reduce(CMTime.zero) { CMTimeAdd($0, $1.cut.duration) }.seconds
    }

    var removedSeconds: Double { session.current.edits.removedDuration.seconds }

    /// 重跑停顿分析（紧凑度滑杆松手 / 进入编辑器 / silences 补算完成时）。
    /// proposed 刷新不入 undo 栈；rejected/accepted 由 EditSession 保护不被打扰。
    func rerunPauseAnalysis() {
        guard let transcript, !transcript.silences.isEmpty else { return }
        let fresh = PauseAnalyzer.suggest(
            transcript: transcript,
            effectiveSentences: session.current.patch.effectiveSentences(in: transcript),
            silences: transcript.silences,
            params: TightenParams(intensity: tightenIntensity))
        session.refreshProposed(with: fresh, of: .pause)
        refreshDerived()
    }

    func accept(suggestionID id: UUID) {
        session.apply { $0.accept(suggestionID: id) }
        selectedSuggestionID = nil
        refreshDerived()
    }

    func reject(suggestionID id: UUID) {
        session.apply { $0.reject(suggestionID: id) }
        selectedSuggestionID = nil
        refreshDerived()
    }

    /// 一键紧凑：全收 proposed（走 accept 路径，一次 undo 可整体回退）
    func acceptAllPauses() {
        guard !proposedPauses.isEmpty else { return }
        session.apply { $0.acceptAllProposed(of: .pause) }
        refreshDerived()
    }

    /// 跳听：只应用这一个切口的拼接结果，切点前后各 1.5s（cut-quality 审阅原则）
    func audition(suggestionID id: UUID) {
        guard let sourceURL, let player,
              let suggestion = session.current.suggestions.first(where: { $0.id == id }) else { return }
        var solo = EditList()
        solo.add(suggestion.cut)
        Task {
            guard let item = try? await PreviewComposer.playerItem(url: sourceURL, edits: solo) else { return }
            let junction = solo.outputTime(forSource: suggestion.cut.start)
            let margin = CMTime(value: 1500, timescale: 1000)
            auditioning = true
            player.replaceCurrentItem(with: item)
            stopAt = CMTimeAdd(junction, margin)
            await player.seek(to: CMTimeMaximum(.zero, CMTimeSubtract(junction, margin)),
                              toleranceBefore: .zero, toleranceAfter: .zero)
            player.play()
        }
    }

    /// 播放器 item 与当前模式对齐（原片 / 成片），并把播放头复位到对应位置
    private func refreshPlayerItem() {
        guard let sourceURL, let player else { return }
        let edits = session.current.edits
        let resumeSource = lastSourceTime
        auditioning = false
        Task {
            if previewTightened {
                guard let item = try? await PreviewComposer.playerItem(url: sourceURL, edits: edits) else { return }
                player.replaceCurrentItem(with: item)
                await player.seek(to: edits.outputTime(forSource: resumeSource),
                                  toleranceBefore: .zero, toleranceAfter: .zero)
            } else {
                player.replaceCurrentItem(with: AVPlayerItem(url: sourceURL))
                await player.seek(to: resumeSource, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
    }

    /// 剪辑变化后重建成片预览（去抖 300ms，设计 m2 §7 风险对策）
    private func schedulePreviewRebuild() {
        previewRebuild?.cancel()
        previewRebuild = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self.refreshPlayerItem()
        }
    }

    /// 时间轴 scrub（输入是 UI 像素换算出的源轴秒）
    func scrub(toSourceSeconds seconds: Double) {
        stopAt = nil
        seekPlayer(toSource: CMTime(seconds: max(0, seconds), preferredTimescale: 600))
    }

    private func seekPlayer(toSource t: CMTime) {
        lastSourceTime = t
        currentSourceSeconds = t.seconds
        let target = previewTightened ? session.current.edits.outputTime(forSource: t) : t
        player?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
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
        waveformPeaks = nil
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
            forInterval: CMTime(value: 1, timescale: 30), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.playbackTick(time) }
        }
    }

    private func playbackTick(_ time: CMTime) {
        isPlaying = player?.rate != 0
        if let stopAt, CMTimeCompare(time, stopAt) >= 0 {
            player?.pause()
            self.stopAt = nil
            if auditioning { refreshPlayerItem(); return }   // 跳听结束回到正常预览
        }
        guard let transcript, !auditioning else { return }
        // item 时间轴 → 源时间轴（成片模式经 EditList 映射；唯一真相仍是 EditList）
        let sourceT = previewTightened
            ? session.current.edits.sourceTime(forOutput: time,
                                               sourceDuration: transcript.sourceDuration)
            : time
        lastSourceTime = sourceT
        currentSourceSeconds = sourceT.seconds
        let sentence = session.current.patch.effectiveSentences(in: transcript).last { s in
            guard let range = transcript.sentenceRange(s) else { return false }
            return CMTimeCompare(range.start, sourceT) <= 0
        }
        currentSentenceStart = sentence?.words.lowerBound
        currentCueText = cachedCues.last {
            CMTimeCompare($0.start, sourceT) <= 0 && CMTimeCompare(sourceT, $0.end) <= 0
        }?.text
    }

    func seek(to s: TranscriptSentence) {
        guard let transcript, let range = transcript.sentenceRange(s) else { return }
        stopAt = nil
        seekPlayer(toSource: range.start)
    }

    /// 试听整句：句首播到句尾自动停（stopAt 存 item 轴，成片模式先映射）
    func playSentence(_ s: TranscriptSentence) {
        guard let transcript, let range = transcript.sentenceRange(s) else { return }
        let edits = session.current.edits
        stopAt = previewTightened ? edits.outputTime(forSource: range.end) : range.end
        lastSourceTime = range.start
        let target = previewTightened ? edits.outputTime(forSource: range.start) : range.start
        player?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
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
        let edits = session.current.edits
        burnTask = Task {
            do {
                try await SubtitleBurner.burn(source: sourceURL, cues: cues, to: outputURL,
                                              edits: edits) { fraction in
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
        // SRT 时间要的是成片轴（edit-model skill）；无剪辑时 retime 恒等
        let srt = Subtitles.srt(Subtitles.retime(cachedCues, through: session.current.edits))
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
