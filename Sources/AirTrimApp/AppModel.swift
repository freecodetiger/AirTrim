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
        case environmentSetup
        case idle
        /// 新转写前选择引擎（本地 / 云端，每次必选）
        case choosingEngine(url: URL)
        case transcribing(fileName: String, startedAt: Date)
        /// 转写完成 → 进编辑器前：自动语义断句（D-EAS-2/3）
        case preparing
        case editor
        case failed(String)
    }

    @Published var stage: Stage = .idle
    /// 本次转写选中的引擎（影响阶段文案；本地默认）
    @Published private(set) var activeEngine: ASREngine = .local
    /// 环境是否就绪：ASR（本地模型 或 云端 Key 任一）且 LLM 都配置（D-EAS-1 门槛，ADR-0007 放松）
    var environmentReady: Bool { (modelFolder != nil || ASRConfig.isConfigured) && LLMConfig.isConfigured }
    /// 环境未就绪时点开的项目，就绪后继续打开（不丢意图）
    @Published var pendingProjectURL: URL?
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
    @Published private(set) var isScrubbing = false
    /// 跳听 / seek 时指定时间轴应滚动到的源秒位置（nil = 不滚动）
    @Published var navigateTimelineTo: Double?
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

    // MARK: - 多模型发现（设置页语音模型管理）

    /// 所有本地已安装的模型。
    @Published private(set) var installedModels: [InstalledModel] = []

    /// 可下载的推荐预设。
    let availablePresets = ModelPreset.available

    /// 刷新已安装模型列表（设置页 onAppear 调用）。
    func refreshInstalledModels() {
        installedModels = Self.discoverInstalledModels(active: modelFolder)
    }

    /// 将指定模型设为活跃模型（用于转写）。
    func setActiveModel(_ model: InstalledModel) {
        guard model.directory != modelFolder else { return }
        modelFolder = model.directory
        refreshInstalledModels()
    }

    /// 扫描所有本地已安装的 WhisperKit 模型。
    static func discoverInstalledModels(active activeURL: URL? = nil) -> [InstalledModel] {
        let fm = FileManager.default
        let searchDirs: [URL] = {
            var dirs: [URL] = []
            // 自管目录
            if let entries = try? fm.contentsOfDirectory(
                at: appSupportModels, includingPropertiesForKeys: nil) {
                dirs.append(contentsOf: entries.map { $0.resolvingSymlinksInPath() })
            }
            // 活跃模型如果是外部目录也加入
            if let active = activeURL,
               !dirs.contains(where: { $0.path == active.resolvingSymlinksInPath().path }) {
                dirs.append(active.resolvingSymlinksInPath())
            }
            return dirs
        }()

        let managedRoot = appSupportModels.resolvingSymlinksInPath().path
        return searchDirs.compactMap { dir -> InstalledModel? in
            let validation = ModelValidator.validate(at: dir)
            // 至少要有核心组件才认为是模型
            guard validation.hasAudioEncoder || validation.hasTextDecoder || validation.hasMelSpectrogram
            else { return nil }
            return InstalledModel(
                id: dir.lastPathComponent,
                name: dir.lastPathComponent,
                directory: dir,
                sizeBytes: ModelValidator.directorySize(at: dir),
                isValid: validation.isValid,
                isManaged: dir.path.hasPrefix(managedRoot)
            )
        }
    }

    /// 一键下载推荐模型。
    func downloadPreset(_ preset: ModelPreset) {
        guard installProgress == nil else { return }
        installError = nil
        let installer = ModelInstaller(manifest: preset.manifest, destination: Self.appSupportModels)
        installProgress = InstallProgress(bytesDone: 0, bytesTotal: preset.manifest.totalBytes,
                                          filesDone: 0, filesTotal: preset.manifest.files.count,
                                          currentFile: "准备中…")
        Task {
            do {
                let modelDir = try await installer.install { progress in
                    Task { @MainActor [weak self] in self?.installProgress = progress }
                }
                self.installProgress = nil
                self.modelFolder = modelDir
                self.refreshInstalledModels()
                // 留在环境准备页：等 LLM 也就绪后由「进入工作流」放行（D-EAS-1）
            } catch {
                self.installProgress = nil
                self.installError = error.localizedDescription
            }
        }
    }

    static let appSupportModels = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AirTrim/Models", isDirectory: true)

    init() {
        modelFolder = Self.discoverModel()
        if modelFolder == nil || !LLMConfig.isConfigured { stage = .environmentSetup }
        loadProjects()
        // 空格键全局监听：无论焦点在哪个视图（AVPlayerView / TextField / 轨道），
        // 空格一律触发播放/暂停。仅当 NSTextView 正在编辑时放行（打字需要空格）。
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // 空格键：播放/暂停（编辑中放行）
            if event.keyCode == 49 {
                if let fr = NSApp.keyWindow?.firstResponder as? NSTextView,
                   fr.isEditable { return event }
                self.togglePlayback()
                return nil
            }
            // Delete / Backspace：删选中句子（编辑中放行给 TextField）
            if event.keyCode == 51 || event.keyCode == 117 {
                if let fr = NSApp.keyWindow?.firstResponder as? NSTextView,
                   fr.isEditable { return event }
                if self.selectedSentenceStart != nil {
                    self.deleteSelectedSentence()
                    return nil
                }
            }
            // Esc：清空剪刀模式未完成的起点（编辑中放行）
            if event.keyCode == 53 {
                if self.manualCutStart != nil {
                    self.manualCutStart = nil
                    return nil
                }
            }
            return event
        }
        // 模型存在但不完整时自动续传（断点续传跳过已完成的文件）
        if modelFolder != nil {
            Task { @MainActor in
                let installer = ModelInstaller(manifest: .largeV3, destination: Self.appSupportModels)
                let (_, todo) = await installer.plan()
                if !todo.isEmpty {
                    repairModel()
                }
            }
        }
        // 冒烟/回归钩子：AIRTRIM_AUTOLOAD=<视频路径> 启动即转写直达编辑器（不走首屏）
        // 钩子固定本地引擎（D-EAS-1 已保证本地模型就绪），绕开每次必选的引擎选择页
        if let auto = ProcessInfo.processInfo.environment["AIRTRIM_AUTOLOAD"],
           modelFolder != nil {
            start(url: URL(fileURLWithPath: auto), engine: .local)
        }
        // M4 起不再自动恢复上次项目（D-M4-1）：首屏是项目管理页，
        // 上次项目降级为「继续上次」置顶卡片（lastProjectURL）
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
        // 留在环境准备页：等 LLM 也就绪后由「进入工作流」放行（D-EAS-1）
    }

    /// 环境准备页「进入工作流」：双就绪后回项目列表；有点开的项目则继续打开（不丢意图）
    func finishEnvironmentSetup() {
        guard environmentReady else { return }
        if let pending = pendingProjectURL {
            pendingProjectURL = nil
            start(url: pending)
        } else {
            stage = .idle
        }
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
                // 留在环境准备页：等 LLM 也就绪后由「进入工作流」放行（D-EAS-1）
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

    func start(url: URL, forceRetranscribe: Bool = false, engine: ASREngine? = nil) {
        // D-EAS-1 硬门槛：ASR（本地模型 或 云端 Key）且 LLM 就绪才进核心工作流；否则停环境准备页（记住意图）
        guard environmentReady else {
            pendingProjectURL = url
            stage = .environmentSetup
            return
        }
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
            if doc.aiSegmentedAt == nil {
                // 未断过句：进编辑器前先自动断句（D-EAS-3 不允许跳过；失败回落原生断句）
                segmentForEntry(url: url)
            } else {
                stage = .editor
                rerunPauseAnalysis()
            }
            backfillDerivedAudioIfNeeded(url: url)
            return
        }
        guard let engine else {
            stage = .choosingEngine(url: url)
            return
        }
        activeEngine = engine
        sourceURL = url
        stage = .transcribing(fileName: url.lastPathComponent, startedAt: Date())
        transcribePhaseText = "抽取音频…"
        transcribeFraction = nil
        Task {
            do {
                let pcm = try await PCMExtractor.monoPCM(url: url)
                self.warnIfLong(pcmSampleCount: pcm.count)
                let transcriber: any Transcriber
                switch engine {
                case .local:
                    guard let modelFolder else {
                        self.stage = .failed("本地模型未就绪。可在「设置 → 语音模型」下载，或改选云端转写。")
                        return
                    }
                    let tokenizerDir = modelFolder.appendingPathComponent("tokenizer")
                    transcriber = WhisperKitTranscriber(
                        modelFolder: modelFolder,
                        tokenizerFolder: FileManager.default.fileExists(atPath: tokenizerDir.path)
                            ? tokenizerDir : nil)
                case .cloud:
                    guard let config = ASRConfig.load() else {
                        self.stage = .failed("未配置云端转写。可在「设置 → AI 服务」填写 DashScope API Key。")
                        return
                    }
                    transcriber = CloudASRTranscriber(config: config)
                }
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
                // 进编辑器前自动断句（.preparing → .editor），由 segmentForEntry/finishEntry 收尾并存盘
                self.segmentForEntry(url: url)
            } catch let error as MediaEngineError {
                self.stage = .failed(error.localizedDescription)
            } catch {
                // 非媒体错误大概率是引擎/网络失败——给出可行动的出路
                let hint = engine == .cloud
                    ? "请检查网络与 API Key；也可改选本地转写。"
                    : "若模型文件不完整，可在「设置 → 模型」重新下载校验。"
                self.stage = .failed("转写失败：\(error.localizedDescription)\n\(hint)")
            }
        }
    }

    /// 进入编辑器前的自动断句（D-EAS-2 不入 undo；D-EAS-3 不允许跳过，失败回落原生断句）。
    /// `.preparing` → 断句 → `finishEntry`（.editor + 存盘 + 停顿分析）。
    private func segmentForEntry(url: URL) {
        guard let transcript, let config = LLMConfig.load() else {
            finishEntry(url: url)   // 环境门槛保证理论到不了这里；防御兜底
            return
        }
        stage = .preparing
        aiSegmenting = true
        aiSegmentProgress = nil
        lastSegmentationResult = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let segmenter = SemanticSegmenter(client: OpenAIChatClient(config: config))
                let result = try await segmenter.proposeSentenceStarts(for: transcript) { completed, total, _ in
                    Task { @MainActor [weak self] in
                        self?.aiSegmentProgress = (completed, total)
                    }
                }
                await MainActor.run {
                    self.session.applyWithoutUndo { $0.patch.sentenceStarts = result.sentenceStarts }
                    self.lastSegmentationResult = result.hasFailures ? result : nil
                    self.aiSegmentProgress = nil
                    self.aiSegmenting = false
                    self.refreshDerived()
                    self.finishEntry(url: url, aiSegmentedAt: Date())
                }
            } catch {
                await MainActor.run {
                    self.aiSegmenting = false
                    self.aiSegmentProgress = nil
                    self.aiError = error.localizedDescription   // 进编辑器后非阻断提示
                    self.finishEntry(url: url)                  // 失败不硬阻塞，回落原生断句
                }
            }
        }
    }

    /// 进入编辑器收尾：stage 置 .editor + 停顿分析 + 存盘（含断句标记）。
    private func finishEntry(url: URL, aiSegmentedAt: Date? = nil) {
        guard let transcript else {
            stage = .failed("缺少转写结果")
            return
        }
        stage = .editor
        rerunPauseAnalysis()
        ProjectStore.save(source: url, transcript: transcript,
                          snapshot: session.current,
                          waveformPeaks: waveformPeaks,
                          aiSegmentedAt: aiSegmentedAt)
    }

    /// v1 缓存补挂派生音频数据：silences（M2 分析输入）+ 波形峰值。
    /// 后台补算一次并回写；期间编辑不受阻（建议延迟出现，设计 m2 §7）。
    private func backfillDerivedAudioIfNeeded(url: URL) {
        guard let current = transcript else { return }
        // 旧版 VAD 不分裂瞬态尖峰，会留下 peak>0.1 的段（新算法永远 ≤0.1）；
        // 命中即重算，否则长静音里一声咀嘴会让整段被 maxSilencePeak 过滤掉
        let staleVAD = current.silences.contains { $0.peakEnergy > 0.1 }
        guard current.silences.isEmpty || staleVAD || waveformPeaks == nil else { return }
        Task {
            guard let pcm = try? await PCMExtractor.monoPCM(url: url) else { return }
            let (silences, peaks) = await Task.detached {
                (EnergyVAD.silences(samples: pcm, sampleRate: PCMExtractor.sampleRate),
                 WaveformPeaks.compute(samples: pcm))
            }.value
            guard self.sourceURL == url, let t = self.transcript else { return }
            if t.silences.isEmpty || staleVAD { self.transcript = t.withSilences(silences) }
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
        switch (activeEngine, phase) {
        case (.cloud, .loadingModel):
            transcribePhaseText = "连接云端转写…"
            transcribeFraction = nil
        case (.cloud, .uploading):
            transcribePhaseText = "上传音频，云端转写中…"
            transcribeFraction = nil
        case (.cloud, .transcribing):
            transcribePhaseText = "云端转写完成"
            transcribeFraction = nil
        case (_, .loadingModel):
            transcribePhaseText = "加载模型…（约十几秒）"
            transcribeFraction = nil
        case (_, .uploading):
            transcribePhaseText = "转写中…"
            transcribeFraction = nil
        case (_, .transcribing(let fraction)):
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

    /// 手动删句：把整句时间区间加入 EditList（走 undo，⌘Z 可回退）
    func deleteSentence(_ s: TranscriptSentence) {
        guard let transcript, let range = transcript.sentenceRange(s) else { return }
        session.apply { $0.edits.add(CMTimeRange(start: range.start, end: range.end)) }
        selectedSentenceStart = nil
        refreshDerived()
    }

    /// 删当前选中的句子
    func deleteSelectedSentence() {
        guard let start = selectedSentenceStart,
              let transcript,
              let s = transcript.sentences.first(where: { $0.words.lowerBound == start }) else { return }
        deleteSentence(s)
    }

    func undo() {
        if session.undo() { refreshDerived() }
    }

    // MARK: - 手动精确剪（剪刀模式，spec: docs/design/manual-cut.md）

    @Published var isManualCutMode = false
    /// 剪起点（源时间轴）。瞬态 UI 状态：不进 EditList、不持久化、不进 undo
    @Published var manualCutStart: CMTime?

    func toggleManualCutMode() {
        isManualCutMode.toggle()
        if !isManualCutMode { manualCutStart = nil }   // 退出时清残留起点，避免下次第一击误剪
    }

    /// 剪刀模式下轨道点击：第一击设起点，第二击执行 cut（每次 cut 恰好一步 undo）。
    /// 落点经 ManualCutSnap 磁吸到词界/静音沿（±250ms 内），起点存吸附后的值供 UI 对齐。
    func manualCut(at seconds: Double) {
        guard isManualCutMode else { return }
        let raw = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        let t = transcript.map { ManualCutSnap.snap(raw, transcript: $0) } ?? raw
        guard let start = manualCutStart else {
            manualCutStart = t
            return
        }
        manualCutStart = nil
        let lo = CMTimeMinimum(start, t)
        let hi = CMTimeMaximum(start, t)
        guard CMTimeCompare(hi, lo) > 0 else { return }   // 同位置连点：忽略
        session.apply { $0.edits.add(CMTimeRange(start: lo, end: hi)) }
        refreshDerived()
    }

    // MARK: - AI 语义断句（LLMProvider · 只上传文字稿 · 结果走 EditSession 可 undo）

    @Published var aiSegmenting = false
    @Published var aiError: String?
    /// 分块进度：(已完成, 总数)，nil = 无进行中的分块任务
    @Published var aiSegmentProgress: (completed: Int, total: Int)?
    /// 上次断句结果（nil = 未运行或全部成功）
    @Published private(set) var lastSegmentationResult: SegmentationResult?
    /// 完成后弹出部分失败提示
    @Published var showPartialResultAlert = false

    /// 失败块覆盖的句下标集合（用于 UI 高亮）
    var failedSentenceIndices: Set<Int> {
        guard let result = lastSegmentationResult else { return [] }
        var indices = Set<Int>()
        for chunk in result.chunks where !chunk.succeeded {
            indices.formUnion(chunk.sentenceRange)
        }
        return indices
    }

    /// 是否有失败块可重试
    var hasFailedChunks: Bool {
        lastSegmentationResult?.hasFailures ?? false
    }

    func aiResegment() {
        guard let transcript, !aiSegmenting else { return }
        guard let config = LLMConfig.load() else {
            aiError = LLMError.notConfigured.localizedDescription
            return
        }
        aiSegmenting = true
        aiSegmentProgress = nil
        lastSegmentationResult = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let segmenter = SemanticSegmenter(client: OpenAIChatClient(config: config))
                let result = try await segmenter.proposeSentenceStarts(for: transcript) { completed, total, _ in
                    Task { @MainActor [weak self] in
                        self?.aiSegmentProgress = (completed, total)
                    }
                }
                await MainActor.run {
                    self.session.apply { $0.patch.sentenceStarts = result.sentenceStarts }
                    self.lastSegmentationResult = result.hasFailures ? result : nil
                    self.aiSegmentProgress = nil
                    self.refreshDerived()
                    self.aiSegmenting = false
                    if result.hasFailures {
                        self.showPartialResultAlert = true
                    }
                }
            } catch {
                await MainActor.run {
                    self.aiError = error.localizedDescription
                    self.aiSegmentProgress = nil
                    self.lastSegmentationResult = nil
                    self.aiSegmenting = false
                }
            }
        }
    }

    /// 重试所有失败块
    func retryFailedChunks() {
        guard let transcript, let result = lastSegmentationResult, !aiSegmenting else { return }
        guard let config = LLMConfig.load() else {
            aiError = LLMError.notConfigured.localizedDescription
            return
        }
        let failedIndices = result.failedChunkIndices
        guard !failedIndices.isEmpty else { return }

        aiSegmenting = true
        aiSegmentProgress = (0, failedIndices.count)
        lastSegmentationResult = nil
        Task { [weak self] in
            guard let self else { return }
            let segmenter = SemanticSegmenter(client: OpenAIChatClient(config: config))
            var current = result
            for (i, chunkIndex) in failedIndices.enumerated() {
                do {
                    let newChunk = try await segmenter.retryChunk(
                        for: transcript, chunkIndex: chunkIndex, previousResult: current)
                    current = SemanticSegmenter.mergeRetriedChunk(
                        newChunk, at: chunkIndex, into: current, transcript: transcript)
                } catch {
                    // 重试仍失败：保持原失败状态
                }
                await MainActor.run {
                    self.aiSegmentProgress = (i + 1, failedIndices.count)
                }
            }
            await MainActor.run {
                self.session.apply { $0.patch.sentenceStarts = current.sentenceStarts }
                self.lastSegmentationResult = current.hasFailures ? current : nil
                self.aiSegmentProgress = nil
                self.refreshDerived()
                self.aiSegmenting = false
                if current.hasFailures {
                    self.showPartialResultAlert = true
                }
            }
        }
    }

    /// 清空分块结果（用户手动编辑后 chunk 边界失效）
    func clearSegmentationResult() {
        lastSegmentationResult = nil
    }

    private func refreshDerived() {
        guard let transcript else { cachedCues = []; return }
        cachedCues = Subtitles.cues(transcript: transcript, patch: session.current.patch,
                                    edits: session.current.edits)
        // 每次修订即持久化（~100KB JSON，原子写）；关闭/崩溃零丢失
        if let sourceURL {
            ProjectStore.save(source: sourceURL, transcript: transcript, snapshot: session.current)
        }
        if previewTightened { schedulePreviewRebuild() }
        objectWillChange.send()
    }

    // MARK: - 一键紧凑（M2）：分析 → 审阅 → 成片预览

    @Published var tightenIntensity: Double = 0.5
    /// 门槛滑杆（秒）：只剪 ≥ 此时长的停顿；0.3 ≈ 旧版单滑杆行为
    @Published var tightenMinGap: Double = 0.3
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
    /// 参数变化时重置旧决策，让用户在新参数下重新评估所有停顿。
    func rerunPauseAnalysis() {
        guard let transcript, !transcript.silences.isEmpty else { return }
        session.apply { $0.resetKind(.pause) }
        let fresh = PauseAnalyzer.suggest(
            transcript: transcript,
            effectiveSentences: session.current.patch.effectiveSentences(in: transcript),
            silences: transcript.silences,
            params: TightenParams(intensity: tightenIntensity, minGapSeconds: tightenMinGap))
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

    /// 一键紧凑：全收 proposed（走 accept 路径，一次 undo 可整体回退）。
    /// 收完自动切到成片预览——用户点「一键紧凑」就是想立刻听到结果，
    /// 原片模式下播放器不跳剪辑段，会误以为没生效。
    func acceptAllPauses() {
        guard !proposedPauses.isEmpty else { return }
        session.apply { $0.acceptAllProposed(of: .pause) }
        refreshDerived()
        previewTightened = true
    }

    // MARK: - M3 AI 建议：识别废话（LLM）

    @Published private(set) var verbosityRunning = false
    @Published var verbosityError: String?
    /// 可选「视频主题」一句话输入（提升离题判定）
    @Published var showVerbosityTopicPrompt = false
    @Published var verbosityTopic = ""
    private var verbosityTask: Task<Void, Never>?

    var proposedVerbosity: [EditSuggestion] {
        session.current.suggestions.filter { $0.state == .proposed && $0.kind == .verbosity }
    }

    /// 轨道绘制用：全部 proposed 建议（按 kind 着色）
    var proposedSuggestions: [EditSuggestion] {
        session.current.suggestions.filter { $0.state == .proposed }
    }

    /// 识别废话入口：先查配置（可行动报错，与 AI 断句同文案），再弹主题输入
    func requestVerbosityAnalysis() {
        guard !verbosityRunning else { return }
        guard LLMConfig.isConfigured else {
            verbosityError = LLMError.notConfigured.localizedDescription
            return
        }
        showVerbosityTopicPrompt = true
    }

    /// 发起 LLM 废话识别（async，可取消）。发起时快照句表指纹，
    /// 返回后由 VerbosityMapper 校验——期间拆/合句则整批作废提示重跑。
    /// 建议只在成功返回后写入（中途崩溃/取消不留脏状态）。
    func runVerbosityAnalysis() {
        guard let transcript, !verbosityRunning else { return }
        guard let config = LLMConfig.load() else {
            verbosityError = LLMError.notConfigured.localizedDescription
            return
        }
        let patch = session.current.patch
        let sentences = patch.effectiveSentences(in: transcript)
        let numbered = sentences.map { (id: $0.id, text: patch.text(for: $0, in: transcript)) }
        let fingerprint = VerbosityMapper.fingerprint(of: sentences)
        let topic = verbosityTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        let params = TightenParams(intensity: tightenIntensity, minGapSeconds: tightenMinGap)
        verbosityRunning = true
        verbosityTask = Task {
            do {
                let client = VerbosityClient(client: OpenAIChatClient(config: config))
                let findings = try await client.analyze(sentences: numbered,
                                                        topic: topic.isEmpty ? nil : topic)
                guard !Task.isCancelled else { verbosityRunning = false; return }
                let currentSentences = session.current.patch.effectiveSentences(in: transcript)
                if let fresh = VerbosityMapper.suggestions(findings: findings,
                                                           transcript: transcript,
                                                           effectiveSentences: currentSentences,
                                                           requestFingerprint: fingerprint,
                                                           params: params) {
                    session.refreshProposed(with: fresh, of: .verbosity)
                    refreshDerived()
                } else {
                    verbosityError = "分析期间句子结构有改动，结果已作废——请重新识别。"
                }
            } catch is CancellationError {
                // 用户取消：UI 复位，无半成品状态
            } catch {
                if !Task.isCancelled { verbosityError = error.localizedDescription }
            }
            verbosityRunning = false
        }
    }

    func cancelVerbosityAnalysis() {
        verbosityTask?.cancel()
        verbosityTask = nil
        verbosityRunning = false
    }

    /// 按类批量接受（一次 apply = 一步 undo）。
    /// 没有全部一键收下的入口——verbosity 永不自动接受（D-M3-2，
    /// 模型层 acceptAllProposed 也硬性拒绝）。
    func acceptVerbosity(category: EditSuggestion.VerbosityCategory) {
        let ids = proposedVerbosity.filter { $0.category == category }.map(\.id)
        guard !ids.isEmpty else { return }
        session.apply { snapshot in ids.forEach { snapshot.accept(suggestionID: $0) } }
        refreshDerived()
    }

    // MARK: - AI 社交媒体文案（标题 + 配文 + 标签）

    @Published var socialCopyRunning = false
    @Published var socialCopyError: String?
    @Published var socialCopyResult: String?
    @Published var showSocialPanel = false
    /// 当前人设（UserDefaults 持久化；Persona 是纯值类型，见 SocialCopyPersona）
    @Published var socialCopyPersona: SocialCopyPersona = AppModel.loadSavedPersona()

    private static let personaKey = "socialCopyPersona"

    private static func loadSavedPersona() -> SocialCopyPersona {
        let saved = UserDefaults.standard.string(forKey: personaKey)
        return SocialCopyPersona.all.first { $0.id == saved } ?? .general
    }

    func setPersona(_ persona: SocialCopyPersona) {
        socialCopyPersona = persona
        UserDefaults.standard.set(persona.id, forKey: Self.personaKey)
    }

    /// 本地关键词粗扫文字稿，给出「推荐人设」（命中最多者胜，平手取 `all` 序）。
    /// 只用于 Picker 默认值与推荐角标，不覆盖用户已保存的选择。零 LLM 成本。
    func suggestedPersona() -> SocialCopyPersona {
        guard let transcript else { return .general }
        let sample = String(transcript.sentences.prefix(20)
            .map { sentenceText($0) }
            .joined().prefix(500)).lowercased()
        var best: (persona: SocialCopyPersona, hits: Int)?
        for persona in SocialCopyPersona.all {
            let words = Self.personaKeywords[persona.id] ?? []
            let hits = words.reduce(0) { $0 + (sample.contains($1) ? 1 : 0) }
            if hits > (best?.hits ?? 0) { best = (persona, hits) }
        }
        guard let best, best.hits > 0 else { return .general }
        return best.persona
    }

    private static let personaKeywords: [String: [String]] = [
        "tech-growth": ["代码", "编程", "程序员", "架构", "算法", "框架", "bug", "重构", "开发", "上线", "模型", "ai", "接口", "调试"],
        "career": ["职场", "上班", "加班", "领导", "同事", "晋升", "绩效", "面试", "简历", "副业", "跳槽", "打工人", "会议"],
        "beauty": ["护肤", "底妆", "化妆", "粉底", "卡粉", "口红", "精华", "面膜", "成分", "皮肤", "妆容", "防晒"],
        "fitness": ["健身", "训练", "减脂", "增肌", "深蹲", "跑步", "动作", "体态", "热量", "蛋白", "腹肌", "拉伸", "瘦"],
        "parenting": ["孩子", "宝宝", "育儿", "幼儿园", "小孩", "家长", "情绪", "辅食", "学校", "绘本", "习惯", "哭"],
    ]

    func requestSocialCopy() {
        guard let transcript, !socialCopyRunning else { return }
        guard LLMConfig.isConfigured else {
            socialCopyError = LLMError.notConfigured.localizedDescription
            return
        }
        socialCopyRunning = true
        socialCopyError = nil
        // 只取剪辑后保留的有效句子
        let effectiveText = session.current.patch
            .effectiveSentences(in: transcript)
            .map { transcript.sentenceText($0) }
            .joined(separator: "\n")
        guard !effectiveText.isEmpty else {
            socialCopyError = "没有有效字幕内容"
            socialCopyRunning = false
            return
        }
        Task {
            do {
                let config = LLMConfig.load()!
                let writer = SocialCopywriter(client: OpenAIChatClient(config: config))
                let result = try await writer.generate(from: effectiveText, persona: socialCopyPersona)
                await MainActor.run {
                    self.socialCopyResult = result
                    self.showSocialPanel = true
                    self.socialCopyRunning = false
                }
            } catch {
                await MainActor.run {
                    self.socialCopyError = error.localizedDescription
                    self.socialCopyRunning = false
                }
            }
        }
    }

    /// 跳听：只应用这一个切口的拼接结果，切点前后各 1.5s（cut-quality 审阅原则）。
    /// 同时把时间轴定位到建议位置，方便看上下文。
    func audition(suggestionID id: UUID) {
        guard let sourceURL, let player,
              let suggestion = session.current.suggestions.first(where: { $0.id == id }) else { return }
        // 先定位时间轴（切换 player item 前）
        currentSourceSeconds = suggestion.originalGap.start.seconds
        navigateTimelineTo = suggestion.originalGap.start.seconds
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

    /// 时间轴 scrub（输入是 UI 像素换算出的源轴秒）。
    /// 拖动中暂停播放 + 屏蔽 playbackTick，避免异步 seek 未完成时旧时间覆写位置。
    func scrub(toSourceSeconds seconds: Double) {
        if !isScrubbing {
            wasPlayingBeforeScrub = isPlaying
            player?.pause()
        }
        isScrubbing = true
        stopAt = nil
        NSApp.keyWindow?.makeFirstResponder(nil)   // 轨道交互时解除字幕编辑焦点
        let t = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        lastSourceTime = t
        currentSourceSeconds = t.seconds
        let target = previewTightened ? session.current.edits.outputTime(forSource: t) : t
        player?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// 松手后保持 isScrubbing 一小段时间（等 seak 落地 + 排空残留回调），
    /// 然后恢复播放状态。不再重复 seek——scrub() 已设置位置。
    func endScrub() {
        let resume = wasPlayingBeforeScrub
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000) // 150ms
            isScrubbing = false
            if resume { player?.play() }
        }
    }

    private var wasPlayingBeforeScrub = false

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
        loadProjects()   // 回项目页：刚保存的项目按 savedAt 自然置顶（D-M4-4）
    }

    var lastProjectURL: URL? { ProjectStore.lastOpenedURL() }

    // MARK: - 项目管理页（M4）：列表状态归 AppModel，Store 只管 I/O（D-M4-3）

    @Published private(set) var projects: [ProjectMetadata] = []

    func loadProjects() {
        projects = ProjectStore.listAllProjects()
    }

    func deleteProjectCache(fingerprint: String) {
        ProjectStore.deleteProject(fingerprint: fingerprint)
        loadProjects()
    }

    // MARK: - 模型管理（设置窗口）

    /// 模型目录磁盘占用（字节，nil = 未安装）。
    var modelDiskBytes: Int64? {
        guard let folder = modelFolder,
              let files = FileManager.default.enumerator(
                  at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return nil }
        var total: Int64 = 0
        for case let url as URL in files {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    /// 模型是否在应用自管目录下。
    var isModelManaged: Bool {
        guard let folder = modelFolder else { return false }
        return folder.resolvingSymlinksInPath().path
            .hasPrefix(Self.appSupportModels.resolvingSymlinksInPath().path)
    }

    func revealModelInFinder() {
        guard let folder = modelFolder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    /// 校验并修复模型：按清单对比文件尺寸，缺损部分断点续传补齐。
    func repairModel() {
        guard let folder = modelFolder else { return }
        installError = nil
        let destination = folder.deletingLastPathComponent()
        let installer = ModelInstaller(manifest: .largeV3, destination: destination)
        installProgress = InstallProgress(bytesDone: 0, bytesTotal: ModelManifest.largeV3.totalBytes,
                                          filesDone: 0, filesTotal: 27, currentFile: "校验中…")
        Task {
            do {
                let repairedDir = try await installer.install { progress in
                    Task { @MainActor [weak self] in self?.installProgress = progress }
                }
                self.installProgress = nil
                self.modelFolder = repairedDir
            } catch {
                self.installProgress = nil
                self.installError = error.localizedDescription
            }
        }
    }

    /// 删除模型文件并重新扫描可用模型。自管 / 外部目录均删除。
    func deleteModel() {
        guard let folder = modelFolder else { return }
        try? FileManager.default.removeItem(at: folder)
        modelFolder = Self.discoverModel()
        refreshInstalledModels()
        if modelFolder == nil && transcript == nil { stage = .environmentSetup }
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
        // 用户拖动时间轴时，播放回调不覆写位置（已由 scrub 设置）
        guard !isScrubbing else { return }
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
        player?.pause()
        isScrubbing = true
        NSApp.keyWindow?.makeFirstResponder(nil)
        currentSourceSeconds = range.start.seconds
        navigateTimelineTo = range.start.seconds
        lastSourceTime = range.start
        let target = previewTightened ? session.current.edits.outputTime(forSource: range.start) : range.start
        player?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in self?.isScrubbing = false }
        }
    }

    /// 试听整句：句首播到句尾自动停（stopAt 存 item 轴，成片模式先映射）
    func playSentence(_ s: TranscriptSentence) {
        guard let transcript, let range = transcript.sentenceRange(s) else { return }
        NSApp.keyWindow?.makeFirstResponder(nil)
        currentSourceSeconds = range.start.seconds
        navigateTimelineTo = range.start.seconds
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
        if player.rate == 0 {
            player.play()
        } else {
            player.pause()
        }
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

    /// 导出无字幕视频：仅应用剪辑，不烧录字幕
    func exportVideo() {
        guard let sourceURL, transcript != nil, burnProgress == nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = sourceURL.deletingPathExtension().lastPathComponent + "-剪辑.mp4"
        guard panel.runModal() == .OK, let outputURL = panel.url else { return }
        burnProgress = 0
        let edits = session.current.edits
        burnTask = Task {
            do {
                try await SubtitleBurner.burn(source: sourceURL, cues: [], to: outputURL,
                                              edits: edits) { fraction in
                    Task { @MainActor [weak self] in self?.burnProgress = fraction }
                }
                NSWorkspace.shared.activateFileViewerSelecting([outputURL])
            } catch is CancellationError { }
            catch { self.exportError = error.localizedDescription }
            self.burnProgress = nil
            self.burnTask = nil
        }
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
