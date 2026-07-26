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
                Button("关闭视频") { model.closeVideo() }
                    .disabled(model.sourceURL == nil)
                Divider()
                Button("重新转写（忽略缓存）") { model.retranscribe() }
                    .disabled(model.sourceURL == nil)
            }
        }

        Settings {
            TabView {
                LLMSettingsView()
                    .tabItem { Label("AI 服务", systemImage: "sparkles") }
                ModelSettingsView()
                    .tabItem { Label("模型", systemImage: "cpu") }
            }
            .environmentObject(model)
        }
    }
}

/// 模型管理：状态 · 磁盘占用 · 校验修复 · 删除（onboarding 之外的唯一模型入口）
struct ModelSettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmDelete = false

    var body: some View {
        Form {
            if let folder = model.modelFolder {
                Section("语音识别模型（本地，转写全程离线）") {
                    LabeledContent("状态", value: "已就绪")
                    LabeledContent("位置", value: folder.path)
                    if let bytes = model.modelDiskBytes {
                        LabeledContent("磁盘占用",
                                       value: ByteCountFormatter.string(fromByteCount: bytes,
                                                                        countStyle: .file))
                    }
                    HStack {
                        Button("在访达中显示") { model.revealModelInFinder() }
                        Button("校验并修复…") { model.repairModel() }
                            .help("按清单核对所有文件尺寸，缺损部分断点续传补齐")
                        Button("删除模型…", role: .destructive) { confirmDelete = true }
                    }
                }
            } else {
                Section("语音识别模型") {
                    if let progress = model.installProgress {
                        ProgressView(value: progress.fraction)
                        Text("\(Int(progress.fraction * 100))% · \(progress.currentFile)")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        LabeledContent("状态", value: "未安装")
                        Button("下载模型（3.1 GB）") { model.downloadModel() }
                        Button("已有模型？选择目录…") { model.chooseModelFolder() }
                            .buttonStyle(.link)
                    }
                    if let error = model.installError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        .alert("删除模型？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) { model.deleteModel() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除应用自管目录下的模型文件（约 3.1 GB），之后可随时重新下载。用户自选的外部模型目录不会被删除，仅解除引用。")
        }
    }
}

/// BYOK 设置（OpenAI 兼容端点）：Key 存 Keychain，不落任何配置文件
struct LLMSettingsView: View {
    @State private var baseURL = LLMSettings.defaultBaseURL
    @State private var modelName = LLMSettings.defaultModel
    @State private var apiKey = ""
    @State private var status: String?

    var body: some View {
        Form {
            Section("AI 服务（OpenAI 兼容格式 · 只上传文字稿，绝不上传音视频）") {
                TextField("API 地址", text: $baseURL,
                          prompt: Text("https://api.deepseek.com 或 https://api.openai.com/v1"))
                TextField("模型", text: $modelName, prompt: Text("deepseek-chat"))
                SecureField("API Key", text: $apiKey, prompt: Text("sk-…"))
                HStack {
                    Button("保存") {
                        do {
                            try LLMSettings.save(baseURLString: baseURL, model: modelName, apiKey: apiKey)
                            status = "已保存（Key 存入钥匙串）"
                        } catch {
                            status = error.localizedDescription
                        }
                    }
                    if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            if let config = LLMSettings.load() {
                baseURL = config.baseURL.absoluteString
                modelName = config.model
                apiKey = config.apiKey
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        switch model.stage {
        case .needsModel: SetupView()
        case .idle: ImportView()
        case .transcribing(let name, let start): TranscribingView(fileName: name, startedAt: start)
        case .editor: EditorView()
        case .failed(let message): FailedView(message: message)
        }
    }
}

struct SetupView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "cpu").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("首次使用：下载语音识别模型").font(.title2)
            Text("AirTrim 完全本地转写，不上传任何音视频。\n模型只需下载一次（3.1 GB，支持断点续传，国内自动走镜像源）。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            if let progress = model.installProgress {
                VStack(spacing: 6) {
                    ProgressView(value: progress.fraction)
                        .frame(width: 320)
                    Text("\(Int(progress.fraction * 100))% · \(progress.filesDone)/\(progress.filesTotal) 个文件 · \(progress.currentFile)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                Button("下载模型（3.1 GB）") { model.downloadModel() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }

            if let error = model.installError {
                Text(error).font(.caption).foregroundStyle(.red)
                Button("重试（从断点继续）") { model.downloadModel() }
            }

            Divider().frame(width: 240)
            Button("已有模型？选择目录…") { model.chooseModelFolder() }
                .buttonStyle(.link)
        }
        .padding(40)
    }
}

struct ImportView: View {
    @EnvironmentObject var model: AppModel
    @State private var dropActive = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "film").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("拖入口播视频，或").font(.title3)
            Button("打开视频…") { model.chooseVideo() }
                .keyboardShortcut(.defaultAction)
            if let last = model.lastProjectURL {
                Button("继续上次：\(last.lastPathComponent)") { model.start(url: last) }
                    .buttonStyle(.link)
            }
            Text("源文件只读，永不修改").font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

struct FailedView: View {
    @EnvironmentObject var model: AppModel
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 40))
                .foregroundStyle(.orange)
            Text(message).multilineTextAlignment(.center)
            HStack {
                Button("返回") { model.stage = .idle }
                SettingsLink { Text("打开设置") }
            }
        }
        .padding(40)
    }
}

// MARK: - 编辑器（左：句列表 · 右：预览）

struct EditorView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                SubtitleCardListView()
                    .frame(minWidth: 380)
                PreviewPane()
                    .frame(minWidth: 320)
            }
            Divider()
            TightenBar()
            TrackAreaView()
                .frame(height: 146)
        }
        .toolbar {
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
                    if model.aiSegmenting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("AI 断句", systemImage: "wand.and.stars")
                    }
                }
                .disabled(model.aiSegmenting)
                .help("按语义重新断句（需在设置里配置 API Key，⌘, 打开设置）")

                Button {
                    model.exportSRT()
                } label: {
                    Label("导出 SRT", systemImage: "square.and.arrow.up")
                }

                Button {
                    model.exportBurnedVideo()
                } label: {
                    Label("导出视频", systemImage: "film.stack")
                }
                .disabled(model.burnProgress != nil)
                .help("把字幕烧录进视频，导出 MP4")
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
        .alert("AI 断句失败", isPresented: Binding(
            get: { model.aiError != nil },
            set: { if !$0 { model.aiError = nil } }
        )) {
            Button("好") { model.aiError = nil }
        } message: {
            Text(model.aiError ?? "")
        }
        .alert("导出失败", isPresented: Binding(
            get: { model.exportError != nil },
            set: { if !$0 { model.exportError = nil } }
        )) {
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
