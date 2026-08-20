import AVKit
import AirTrimCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct AirTrimApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("AirTrim") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 860, minHeight: 540)
        }
        .commands {
            CommandGroup(after: .undoRedo) {
                Button("撤销修订") { model.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!model.session.canUndo)
            }
            CommandGroup(after: .newItem) {
                Button("打开视频…") { model.chooseVideo() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("关闭视频/返回项目") { model.closeVideo() }
                    .keyboardShortcut("w", modifiers: .command)
                    .disabled(model.sourceURL == nil)
                Divider()
                Button("重新转写（忽略缓存）") { model.retranscribe() }
                    .disabled(model.sourceURL == nil)
            }
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { SettingsWindowManager.open(model: model) }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }

    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        switch model.stage {
        case .environmentSetup: EnvironmentSetupView()
        case .idle: ProjectHomeView()
        case .transcribing(let name, let start): TranscribingView(fileName: name, startedAt: start)
        case .preparing: PreparingView()
        case .editor: EditorView()
        case .failed(let message): FailedView(message: message)
        }
    }
}

/// 环境准备页：语音模型 + LLM 双就绪后才放行进入核心工作流（D-EAS-1 硬门槛）。
struct EnvironmentSetupView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("环境准备").font(.title2.bold())
                    Text("就绪后才能进入剪辑工作流。本地转写不上传任何音视频；AI 功能只上传文字稿。")
                        .font(.callout).foregroundStyle(.secondary)
                }

                // ① 语音模型
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("语音模型", systemImage: "waveform").font(.headline)
                        Spacer()
                        if model.modelFolder != nil {
                            Label("就绪", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green).font(.callout)
                        }
                    }
                    if let progress = model.installProgress {
                        VStack(spacing: 6) {
                            ProgressView(value: progress.fraction)
                            Text("\(Int(progress.fraction * 100))% · \(progress.currentFile)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    } else if model.modelFolder == nil {
                        Button("下载模型（3.1 GB）") { model.downloadModel() }
                        if let error = model.installError {
                            Text(error).font(.caption).foregroundStyle(.red)
                            Button("重试（从断点继续）") { model.downloadModel() }
                        }
                        Button("已有模型？选择目录…") { model.chooseModelFolder() }
                            .buttonStyle(.link)
                    } else {
                        Text("模型已就绪").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))

                // ② LLM（大模型 API）
                LLMSetupForm()

                // ③ 放行
                HStack {
                    Text(model.pendingProjectURL != nil ? "就绪后继续打开所选项目" : "就绪后进入项目列表")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("进入工作流") { model.finishEnvironmentSetup() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!model.environmentReady)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(28)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
    }
}

/// 环境准备页里的紧凑 LLM 表单（OpenAI 兼容；完整版在设置页，含测试连接）
struct LLMSetupForm: View {
    @EnvironmentObject var model: AppModel
    @State private var apiKey = ""
    @State private var baseURL = LLMConfig.defaultBaseURL
    @State private var llmModel = LLMConfig.defaultModel
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("AI 服务（大模型 API）", systemImage: "sparkles").font(.headline)
                Spacer()
                if LLMConfig.isConfigured {
                    Label("就绪", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.callout)
                }
            }
            LabeledContent("API Key") {
                TextField("sk-…", text: $apiKey).textFieldStyle(.roundedBorder)
            }
            LabeledContent("Base URL") {
                TextField(LLMConfig.defaultBaseURL, text: $baseURL).textFieldStyle(.roundedBorder)
            }
            LabeledContent("模型") {
                TextField(LLMConfig.defaultModel, text: $llmModel).textFieldStyle(.roundedBorder)
            }
            HStack {
                Button("保存") { save() }
                    .disabled(apiKey.isEmpty)
                if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
            Text("OpenAI 兼容格式（DeepSeek / OpenAI / Ollama…）；只上传文字稿。")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
        .onAppear {
            if let config = LLMConfig.load() {
                apiKey = config.apiKey
                baseURL = config.baseURL.absoluteString
                llmModel = config.model
            }
        }
    }

    private func save() {
        do {
            try LLMConfig.save(baseURLString: baseURL, model: llmModel, apiKey: apiKey)
            status = "已保存"
        } catch {
            status = error.localizedDescription
        }
    }
}

// MARK: - 项目管理页（M4 首屏）：顶部导入区 + 继续上次置顶卡片 + 项目列表

struct ProjectHomeView: View {
    @EnvironmentObject var model: AppModel
    @State private var dropActive = false
    @State private var pendingDelete: ProjectMetadata?
    @State private var missingSource: ProjectMetadata?

    /// 「继续上次」卡片数据源：last-opened 且缓存仍有效，才从列表里提到置顶
    private var lastOpened: ProjectMetadata? {
        guard let last = model.lastProjectURL else { return nil }
        return model.projects.first { $0.sourcePath == last.path }
    }

    private var otherProjects: [ProjectMetadata] {
        guard let last = lastOpened else { return model.projects }
        return model.projects.filter { $0.id != last.id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                importArea
                if let last = lastOpened {
                    section("继续上次") {
                        ProjectRowView(project: last, open: open,
                                       requestDelete: { pendingDelete = $0 })
                    }
                }
                if !otherProjects.isEmpty {
                    section("项目（按最后编辑倒序）") {
                        ForEach(otherProjects) { project in
                            ProjectRowView(project: project, open: open,
                                           requestDelete: { pendingDelete = $0 })
                        }
                    }
                } else if model.projects.isEmpty {
                    Text("还没有项目——从上方拖入或打开一个视频开始。")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 8)
                }
            }
            .padding(24)
        }
        .background(dropActive ? Color.accentColor.opacity(0.08) : .clear)
        .onDrop(of: [.fileURL], isTargeted: $dropActive) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    Task { @MainActor in model.start(url: url) }
                }
            }
            return true
        }
        .onAppear { model.loadProjects() }
        .navigationTitle("AirTrim")
        // 删除缓存需确认（P1）；只删 JSON，源文件永远不动
        .confirmationDialog(
            "删除「\(pendingDelete?.fileName ?? "")」的项目缓存？",
            isPresented: Binding(get: { pendingDelete != nil },
                                 set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("删除缓存", role: .destructive) {
                if let p = pendingDelete { model.deleteProjectCache(fingerprint: p.fingerprint) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("只删除转写与剪辑缓存，源视频文件不受影响；下次打开需重新转写。")
        }
        // 源文件丢失：点击不进转写，弹说明（右键仍可删缓存清理残留）
        .alert("源文件已丢失", isPresented: Binding(
            get: { missingSource != nil },
            set: { if !$0 { missingSource = nil } }
        )) {
            Button("好") { missingSource = nil }
        } message: {
            Text("找不到 \(missingSource?.sourcePath ?? "")。\n若文件已移动，请重新拖入新位置的文件；若已删除，可右键删除项目缓存。")
        }
    }

    /// 打开路径全部复用 start(url:)：缓存命中/未命中/重转分支一行不改
    private func open(_ project: ProjectMetadata) {
        guard project.sourceExists else { missingSource = project; return }
        model.start(url: project.sourceURL)
    }

    private var importArea: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "film").font(.title2).foregroundStyle(.secondary)
                Text("拖入口播视频，或").font(.title3)
                Button("打开视频…") { model.chooseVideo() }
                    .keyboardShortcut(.defaultAction)
            }
            Text("源文件只读，永不修改").font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6]))
                .foregroundStyle(.quaternary)
        )
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }
}

/// 项目列表行：图标 + 文件名 + 源路径 + 时间与缓存大小；源文件丢失灰态。
/// 单击整行打开，右键出菜单（打开 / 访达显示 / 删除缓存）。
struct ProjectRowView: View {
    let project: ProjectMetadata
    let open: (ProjectMetadata) -> Void
    let requestDelete: (ProjectMetadata) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "film").font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(project.fileName).font(.headline)
                    if !project.sourceExists {
                        Label("源文件已丢失", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Text((project.sourcePath as NSString).abbreviatingWithTildeInPath)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(project.savedAt.formatted(date: .abbreviated, time: .shortened))
                Text(ByteCountFormatter.string(fromByteCount: project.projectSizeBytes,
                                               countStyle: .file))
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .opacity(project.sourceExists ? 1 : 0.55)
        .contentShape(Rectangle())
        .onTapGesture { open(project) }
        .contextMenu {
            Button("打开") { open(project) }
            Button("在访达中显示源文件") {
                NSWorkspace.shared.activateFileViewerSelecting([project.sourceURL])
            }
            .disabled(!project.sourceExists)
            Divider()
            Button("删除项目缓存…", role: .destructive) { requestDelete(project) }
        }
    }
}

struct TranscribingView: View {
    @EnvironmentObject var model: AppModel
    let fileName: String
    let startedAt: Date

    var body: some View {
        VStack(spacing: 14) {
            if let fraction = model.transcribeFraction {
                ProgressView(value: fraction)
                    .frame(width: 320)
                Text("\(Int(fraction * 100))%")
                    .font(.system(.title3, design: .monospaced))
            } else {
                ProgressView().controlSize(.large)
            }
            Text("正在处理 \(fileName)").font(.title3)
            Text(model.transcribePhaseText)
                .font(.caption).foregroundStyle(.secondary)
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Text("已用 \(Int(context.date.timeIntervalSince(startedAt))) 秒 · 全程离线")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 进入编辑器前的自动断句准备界面（D-EAS-3 不允许跳过；失败回落原生断句后进编辑器）。
struct PreparingView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("正在准备编辑环境…").font(.title3)
            if let p = model.aiSegmentProgress {
                Text("正在语义断句 \(p.completed)/\(p.total)…")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FailedView: View {
    @EnvironmentObject var model: AppModel
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 40))
                .foregroundStyle(.orange)
            Text(message).multilineTextAlignment(.center)
            Button("返回") { model.stage = .idle }
        }
        .padding(40)
    }
}

// MARK: - 编辑器（左：句列表 · 右：预览）

struct EditorView: View {
    @EnvironmentObject var model: AppModel

    private var showSegmentError: Binding<Bool> {
        Binding(get: { model.aiError != nil },
                set: { if !$0 { model.aiError = nil } })
    }
    private var showExportError: Binding<Bool> {
        Binding(get: { model.exportError != nil },
                set: { if !$0 { model.exportError = nil } })
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                SubtitleCardListView()
                    .frame(minWidth: 320)
                PreviewPane()
                    .frame(minWidth: 300)
                if model.showSocialPanel {
                    SocialCopyPanel()
                        .frame(minWidth: 280, idealWidth: 340)
                }
            }
            Divider()
            TightenBar()
            TrackAreaView()
                .frame(height: 146)
        }
        .toolbar {
            // 左侧导航：返回项目管理页
            ToolbarItem(placement: .navigation) {
                Button {
                    model.closeVideo()
                } label: {
                    Label("返回项目", systemImage: "chevron.backward")
                }
                .help("关闭视频，返回项目管理页（修订已自动保存）")
            }
            // 右侧操作：撤销 · AI 断句 · 导出 · 设置
            ToolbarItemGroup {
                Button {
                    model.undo()
                } label: {
                    Label("撤销", systemImage: "arrow.uturn.backward")
                }
                .disabled(!model.session.canUndo)

                Button {
                    model.aiResegment()
                } label: {
                    if model.aiSegmenting, let p = model.aiSegmentProgress {
                        Label("断句 \(p.completed)/\(p.total)", systemImage: "wand.and.stars")
                    } else if model.aiSegmenting {
                        Label("断句中…", systemImage: "wand.and.stars")
                    } else {
                        Label("AI 断句", systemImage: "wand.and.stars")
                    }
                }
                .disabled(model.aiSegmenting)
                .help("按语义重新断句（需配置 LLM）")

                Menu {
                    Button {
                        model.exportSRT()
                    } label: {
                        Label("导出 SRT 字幕", systemImage: "doc.plaintext")
                    }
                    Divider()
                    Button {
                        model.exportVideo()
                    } label: {
                        Label("导出视频（仅剪辑，无字幕）", systemImage: "film")
                    }
                    .disabled(model.burnProgress != nil)
                    Button {
                        model.exportBurnedVideo()
                    } label: {
                        Label("导出视频（烧录字幕）", systemImage: "film.stack")
                    }
                    .disabled(model.burnProgress != nil)
                } label: {
                    Label("导出", systemImage: "square.and.arrow.up")
                }
                .help("导出 SRT 字幕、无字幕剪辑视频或烧录字幕的视频")

                Button {
                    SettingsWindowManager.open(model: model)
                } label: {
                    Label("设置", systemImage: "gearshape")
                }
                .help("AI 服务配置 · 模型管理")
            }
        }
        .sheet(isPresented: Binding(
            get: { model.burnProgress != nil },
            set: { _ in }
        )) {
            VStack(spacing: 14) {
                Text("正在烧录字幕…").font(.headline)
                ProgressView(value: model.burnProgress ?? 0)
                    .frame(width: 300)
                Text("\(Int((model.burnProgress ?? 0) * 100))% · 源文件保持只读，输出为新文件")
                    .font(.caption).foregroundStyle(.secondary)
                Button("取消") { model.cancelBurn() }
            }
            .padding(28)
        }
        .alert("AI 断句失败", isPresented: showSegmentError) {
            Button("好") { model.aiError = nil }
        } message: {
            Text(model.aiError ?? "")
        }
        .alert("导出失败", isPresented: showExportError) {
            Button("好") { model.exportError = nil }
        } message: {
            Text(model.exportError ?? "")
        }
        .navigationTitle(model.sourceURL?.lastPathComponent ?? "AirTrim")
    }
}

/// 直接承载 AVKit 的 AVPlayerView。
/// 不用 SwiftUI 的 VideoPlayer：那是 _AVKit_SwiftUI 的包装类，release 死代码
/// 剥离会裁掉未被直接引用的 AVKit 链接，运行时按名字解析父类 AVPlayerView
/// 失败直接 abort（M1 实测崩溃）。强引用 AVPlayerView 从根上消除该问题。
struct PlayerHostView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = false
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

struct PreviewPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if let player = model.player {
                PlayerHostView(player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.black
            }
            // 软字幕预览：导出/烧录前所见即所得
            Text(model.currentCueText ?? " ")
                .font(.system(size: 15, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(.black.opacity(0.85))
                .foregroundStyle(.white)
        }
        .background(.black)
    }
}
