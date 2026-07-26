import AirTrimCore
import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// 应用状态机（组合根）：编排 MediaEngine 抽音频 → SpeechPipeline 转写，
/// 持有 Transcript 快照与 PatchSession；不复制任何剪辑/时间状态（唯一真相源不变量）。
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

    private(set) var modelFolder: URL?

    static let appSupportModels = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AirTrim/Models", isDirectory: true)

    init() {
        modelFolder = Self.discoverModel()
        if modelFolder == nil { stage = .needsModel }
    }

    /// 模型发现：App Support 下第一个含 *.mlmodelc 的目录（下载器是后续产品能力，
    /// 当前引导用户手动放置或选择目录）
    static func discoverModel() -> URL? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: appSupportModels, includingPropertiesForKeys: nil) else { return nil }
        return entries.first { url in
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
                let transcriber = WhisperKitTranscriber(modelFolder: modelFolder)
                let result = try await transcriber.transcribe(
                    audioPath: url.path, pcm: pcm, language: "zh")
                self.transcript = result
                self.patches = PatchSession()
                self.stage = .editor
            } catch {
                self.stage = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - 编辑（全部经由 PatchSession，undo 快照栈）

    func sentenceText(_ s: TranscriptSentence) -> String {
        guard let transcript else { return "" }
        return patches.current.text(for: s, in: transcript)
    }

    func updateSentence(_ s: TranscriptSentence, text: String) {
        guard let transcript else { return }
        let original = transcript.sentenceText(s)
        patches.apply { patch in
            if text == original {
                patch.sentenceTextOverrides.removeValue(forKey: s.id)
            } else {
                patch.sentenceTextOverrides[s.id] = text
            }
        }
        objectWillChange.send()
    }

    func undo() {
        if patches.undo() { objectWillChange.send() }
    }

    // MARK: - 导出

    func exportSRT() {
        guard let transcript else { return }
        let srt = Subtitles.srt(Subtitles.cues(transcript: transcript, patch: patches.current))
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
