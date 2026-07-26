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
                .frame(minWidth: 640, minHeight: 480)
        }
        .commands {
            CommandGroup(after: .undoRedo) {
                Button("撤销修订") { model.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!model.patches.canUndo)
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
        VStack(spacing: 14) {
            Image(systemName: "cpu").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("需要本地 ASR 模型").font(.title2)
            Text("AirTrim 完全本地转写，不上传任何音视频。\n请选择 WhisperKit 模型目录（内含 *.mlmodelc），\n或将模型放入 ~/Library/Application Support/AirTrim/Models/")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("选择模型目录…") { model.chooseModelFolder() }
                .keyboardShortcut(.defaultAction)
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
    let fileName: String
    let startedAt: Date

    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("正在本地转写 \(fileName)…").font(.title3)
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
            Button("返回") { model.stage = .idle }
        }
        .padding(40)
    }
}

struct EditorView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if let transcript = model.transcript {
                List(transcript.sentences, id: \.id) { sentence in
                    SentenceRow(sentence: sentence, transcript: transcript)
                }
                .listStyle(.inset)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.undo()
                } label: {
                    Label("撤销", systemImage: "arrow.uturn.backward")
                }
                .disabled(!model.patches.canUndo)

                Button {
                    model.exportSRT()
                } label: {
                    Label("导出 SRT", systemImage: "square.and.arrow.up")
                }
            }
        }
        .navigationTitle(model.sourceURL?.lastPathComponent ?? "AirTrim")
    }
}

struct SentenceRow: View {
    @EnvironmentObject var model: AppModel
    let sentence: TranscriptSentence
    let transcript: Transcript
    @State private var draft = ""
    @FocusState private var focused: Bool

    var timeLabel: String {
        guard let range = transcript.sentenceRange(sentence) else { return "--:--" }
        let s = Int(range.start.seconds)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    var edited: Bool {
        model.patches.current.sentenceTextOverrides[sentence.id] != nil
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(timeLabel)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(edited ? Color.accentColor : .secondary)
                .frame(width: 44, alignment: .trailing)
            TextField("", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .focused($focused)
                .onAppear { draft = model.sentenceText(sentence) }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { model.updateSentence(sentence, text: draft) }
                }
                .onSubmit { model.updateSentence(sentence, text: draft) }
        }
        .padding(.vertical, 2)
    }
}
