import AirTrimCore
import AirTrimInstaller
import SwiftUI

// MARK: - 设置窗口（顶部导航 + 内容区）

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedPage: Page = .aiService

    private enum Page: String, CaseIterable, Identifiable {
        case aiService
        case voiceModel

        var id: String { rawValue }

        var label: String {
            switch self {
            case .aiService: "AI 服务"
            case .voiceModel: "语音模型"
            }
        }

        var icon: String {
            switch self {
            case .aiService: "sparkles"
            case .voiceModel: "cpu"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部导航
            Picker("", selection: $selectedPage) {
                ForEach(Page.allCases) { page in
                    Label(page.label, systemImage: page.icon).tag(page)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            // 内容区
            Group {
                switch selectedPage {
                case .aiService:
                    AIServiceSettingsView()
                case .voiceModel:
                    VoiceModelSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 500, minHeight: 440)
        .onAppear { model.refreshInstalledModels() }
    }
}

// MARK: - AI 服务页

struct AIServiceSettingsView: View {
    @EnvironmentObject private var model: AppModel

    @State private var apiKey: String = ""
    @State private var baseURL: String = ""
    @State private var llmModel: String = ""
    @State private var connectionStatus: String? = nil
    @State private var testingConnection = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case apiKey, baseURL, model }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("AI 服务").font(.headline)
                Text("OpenAI 兼容格式 · 只上传文字稿，绝不上传音视频")
                    .font(.caption).foregroundStyle(.secondary)

                // 状态
                if LLMConfig.isConfigured {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("已配置").font(.callout)
                    }
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "circle").foregroundStyle(.secondary)
                        Text("未配置").font(.callout).foregroundStyle(.secondary)
                    }
                }

                // 编辑字段
                LabeledContent("API Key") {
                    TextField("sk-…", text: $apiKey)
                        .focused($focusedField, equals: .apiKey)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Base URL") {
                    TextField("https://api.deepseek.com", text: $baseURL)
                        .focused($focusedField, equals: .baseURL)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("模型") {
                    TextField("deepseek-chat", text: $llmModel)
                        .focused($focusedField, equals: .model)
                        .textFieldStyle(.roundedBorder)
                }

                HStack(spacing: 8) {
                    Button("测试连接") {
                        testingConnection = true
                        connectionStatus = "测试中…"
                        let (u, m, k) = (baseURL, llmModel, apiKey)
                        Task {
                            do {
                                connectionStatus = try await testConnection(baseURLString: u, model: m, apiKey: k)
                            } catch {
                                connectionStatus = error.localizedDescription
                            }
                            testingConnection = false
                        }
                    }
                    .disabled(testingConnection || apiKey.isEmpty)

                    Button("保存") {
                        guard !apiKey.isEmpty else {
                            connectionStatus = "API Key 不能为空"
                            return
                        }
                        do {
                            try LLMConfig.save(baseURLString: baseURL, model: llmModel, apiKey: apiKey)
                            connectionStatus = "已保存"
                        } catch {
                            connectionStatus = error.localizedDescription
                        }
                    }
                }

                if let status = connectionStatus {
                    Text(status).font(.caption)
                        .foregroundStyle(status.hasPrefix("连接成功") || status == "已保存" ? .green : .secondary)
                }

                Text("配置保存在本地 JSON 文件，绝不上传。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .onAppear { loadCurrentConfig() }
    }

    private func loadCurrentConfig() {
        if let config = LLMConfig.load() {
            apiKey = config.apiKey
            baseURL = config.baseURL.absoluteString
            llmModel = config.model
        } else {
            apiKey = ""
            baseURL = LLMConfig.defaultBaseURL
            llmModel = LLMConfig.defaultModel
        }
    }

    private func testConnection(baseURLString: String, model _: String, apiKey: String) async throws -> String {
        guard let url = URL(string: baseURLString.trimmingCharacters(in: CharacterSet(charactersIn: "/")))?
                .appendingPathComponent("v1").appendingPathComponent("models") else {
            throw TestError.badURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TestError.badResponse("非 HTTP 响应")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw TestError.badResponse("HTTP \(http.statusCode)：\(body.prefix(200))")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["data"] as? [[String: Any]] else {
            throw TestError.badResponse("响应格式不符")
        }
        let names = models.compactMap { $0["id"] as? String }.prefix(5).joined(separator: ", ")
        return "连接成功，\(models.count) 个模型可用（\(names)…）"
    }

    private enum TestError: Error, LocalizedError {
        case badURL
        case badResponse(String)
        var errorDescription: String? {
            switch self {
            case .badURL: "API 地址格式错误"
            case .badResponse(let detail): "请求失败：\(detail)"
            }
        }
    }
}

// MARK: - 语音模型页

struct VoiceModelSettingsView: View {
    @EnvironmentObject private var model: AppModel

    @State private var confirmDeleteModel = false
    @State private var confirmSwitchModel: InstalledModel?
    @State private var modelToDelete: InstalledModel?
    @State private var showManualAdd = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // ── 已安装模型 ──
                installedModelsSection

                Divider()

                // ── 获取新模型 ──
                presetModelsSection

                Divider()

                // ── 手动添加 ──
                manualAddSection
            }
            .padding(24)
        }
        .onAppear { model.refreshInstalledModels() }
        // 删除确认
        .alert("删除模型？", isPresented: $confirmDeleteModel) {
            Button("删除", role: .destructive) {
                if let target = modelToDelete {
                    if target.directory == model.modelFolder {
                        model.deleteModel()
                    } else {
                        try? FileManager.default.removeItem(at: target.directory)
                        model.refreshInstalledModels()
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            if let target = modelToDelete {
                let activeNote = target.directory == model.modelFolder
                    ? "「\(target.name)」是当前正在使用的模型。\n删除后将无法转写，需重新下载或选择本地模型。\n"
                    : ""
                let sizeNote = "将删除约 \(target.formattedSize) 的模型文件。"
                let locationNote = target.isManaged
                    ? ""
                    : "\n模型位于自管目录之外：\(target.directory.path)"
                Text(activeNote + sizeNote + locationNote)
            }
        }
        // 切换活跃模型确认
        .alert("切换语音模型？", isPresented: Binding(
            get: { confirmSwitchModel != nil },
            set: { if !$0 { confirmSwitchModel = nil } }
        )) {
            Button("切换") {
                if let target = confirmSwitchModel {
                    model.setActiveModel(target)
                }
                confirmSwitchModel = nil
            }
            Button("取消", role: .cancel) { confirmSwitchModel = nil }
        } message: {
            if let target = confirmSwitchModel {
                Text("切换至「\(target.name)」后，当前视频需重新转写。\n是否继续？")
            }
        }
    }

    // MARK: - 已安装模型 Section

    @ViewBuilder
    private var installedModelsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("已安装的模型").font(.headline)

            // 活跃模型损坏警告（P0 提示）
            if let active = model.installedModels.first(where: {
                $0.directory.resolvingSymlinksInPath().path
                    == model.modelFolder?.resolvingSymlinksInPath().path
            }), let valid = active.isValid, !valid {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("当前模型文件不完整，转写将失败。请重新下载或删除后重新获取。")
                        .font(.callout)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.1))
                .cornerRadius(8)
            }

            if model.installedModels.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "circle").foregroundStyle(.secondary)
                    Text("未安装任何模型").font(.callout).foregroundStyle(.secondary)
                }
                Text("下载下方推荐模型或选择本地已有模型目录。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(model.installedModels) { installed in
                    installedModelCard(installed)
                }
            }

            // 下载进度（全局）
            if let progress = model.installProgress {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress.fraction)
                    Text("\(Int(progress.fraction * 100))% · \(progress.filesDone)/\(progress.filesTotal) 个文件 · \(progress.currentFile)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = model.installError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func installedModelCard(_ installed: InstalledModel) -> some View {
        let isActive = installed.directory.resolvingSymlinksInPath().path
            == model.modelFolder?.resolvingSymlinksInPath().path
        let isBroken = installed.isValid.map { !$0 } ?? false

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if isActive {
                    Image(systemName: isBroken
                        ? "exclamationmark.circle.fill"
                        : "checkmark.circle.fill")
                        .foregroundStyle(isBroken ? .orange : .green)
                    Text(installed.name).font(.callout).bold()
                    Text(isBroken ? "· 不完整" : "· 使用中")
                        .font(.caption)
                        .foregroundStyle(isBroken ? .orange : .green)
                } else {
                    Image(systemName: "circle").foregroundStyle(.secondary)
                    Text(installed.name).font(.callout)
                    Text("· \(installed.formattedSize)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let valid = installed.isValid {
                    if valid {
                        Text("完整").font(.caption)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.green.opacity(0.15)).cornerRadius(4)
                    } else {
                        Text("不完整").font(.caption)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.orange.opacity(0.15)).cornerRadius(4)
                    }
                }
            }

            Text(installed.directory.path)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 8) {
                Button("在访达中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([installed.directory])
                }

                if !isActive {
                    Button("使用此模型") {
                        confirmSwitchModel = installed
                    }
                }

                if installed.isManaged {
                    if isBroken {
                        Button("重新下载") {
                            model.repairModel()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(model.installProgress != nil)
                    } else {
                        Button("校验修复…") {
                            model.repairModel()
                        }
                        .disabled(model.installProgress != nil)
                    }
                }

                Button("删除…", role: .destructive) {
                    modelToDelete = installed
                    confirmDeleteModel = true
                }
            }
        }
        .padding(10)
        .background(isBroken && isActive
            ? Color.orange.opacity(0.06)
            : Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isBroken && isActive ? Color.orange.opacity(0.3) : .clear, lineWidth: 1)
        )
        .cornerRadius(8)
    }

    // MARK: - 推荐模型 Section

    @ViewBuilder
    private var presetModelsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("获取新模型").font(.headline)
            Text("选择适合你需求的档位：").font(.caption).foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 12) {
                // 轻量卡片（占位）
                presetCard(
                    icon: "hare", tier: "轻量", name: "Whisper tiny",
                    size: "~150 MB", desc: "速度最快，精度一般\n适合快速草剪",
                    recommended: false, available: false
                )

                // 均衡卡片（占位）
                presetCard(
                    icon: "scalemass", tier: "均衡", name: "Whisper turbo",
                    size: "~1.2 GB", desc: "速度与精度兼顾\n适合日常剪辑",
                    recommended: false, available: false
                )

                // 高精度卡片（可用）
                presetCard(
                    icon: "sparkles", tier: "高精度", name: "Whisper large-v3",
                    size: "~3.1 GB", desc: "中文口播精度最高\n推荐用于精剪",
                    recommended: true, available: true
                )
            }
        }
    }

    @ViewBuilder
    private func presetCard(icon: String, tier: String, name: String, size: String,
                            desc: String, recommended: Bool, available: Bool) -> some View {
        let isInstalled = model.installedModels.contains {
            $0.id == "openai_whisper-\(name.replacingOccurrences(of: "Whisper ", with: ""))"
        }

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon).font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tier).font(.subheadline).bold()
                    if recommended {
                        Text("⭐ 推荐").font(.caption).foregroundStyle(.orange)
                    }
                }
                Spacer()
            }

            Text(name).font(.caption).bold()
            Text(size).font(.caption).foregroundStyle(.secondary)
            Text(desc).font(.caption2).foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer()

            if isInstalled {
                Label("已安装", systemImage: "checkmark")
                    .font(.caption).foregroundStyle(.green)
                    .frame(maxWidth: .infinity)
            } else if model.installProgress != nil {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity)
            } else if available {
                Button("获取") {
                    if let preset = ModelPreset.available.first(where: { $0.id.contains("large-v3") }) {
                        model.downloadPreset(preset)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .frame(maxWidth: .infinity)
            } else {
                Button("即将推出") {}
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(true)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(12)
        .frame(width: 140, height: 200)
        .background(.background.secondary.opacity(0.4))
        .cornerRadius(10)
    }

    // MARK: - 手动添加 Section

    @ViewBuilder
    private var manualAddSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("手动添加").font(.headline)
            Text("选择本地已下载的 WhisperKit CoreML 模型目录。")
                .font(.caption).foregroundStyle(.secondary)
            Button("选择本地模型目录…") {
                model.chooseModelFolder()
                // 延迟刷新，等 NSOpenPanel 返回
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    model.refreshInstalledModels()
                }
            }
        }
    }
}
