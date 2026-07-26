import AVFoundation
import AirTrimSpikeKit
import ArgumentParser
import Foundation
import WhisperKit

struct Transcribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "用 WhisperKit 转写音/视频，输出词级时间戳 JSON"
    )

    @Option(help: "音频或视频文件路径")
    var audio: String

    @Option(help: "WhisperKit 模型名（如 tiny / base / small / large-v3）")
    var model: String = "large-v3"

    @Option(help: "语言代码")
    var language: String = "zh"

    @Option(help: "输出 JSON 路径")
    var output: String

    func run() async throws {
        let audioURL = URL(fileURLWithPath: audio)
        guard FileManager.default.fileExists(atPath: audio) else {
            throw ValidationError("找不到文件：\(audio)")
        }

        FileHandle.standardError.write(Data("加载模型 \(model)（首次运行会自动下载）…\n".utf8))
        let config = WhisperKitConfig(model: model, prewarm: true)
        let pipe = try await WhisperKit(config)

        let duration = try await AVURLAsset(url: audioURL).load(.duration).seconds
        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            wordTimestamps: true
        )

        let t0 = Date()
        let results = try await pipe.transcribe(audioPath: audio, decodeOptions: options)
        let elapsed = Date().timeIntervalSince(t0)

        let words = results
            .flatMap { $0.allWords }
            .map {
                SpikeWord(
                    text: $0.word.trimmingCharacters(in: .whitespaces),
                    start: Double($0.start),
                    end: Double($0.end)
                )
            }
            .filter { !$0.text.isEmpty }

        let transcript = SpikeTranscript(
            engine: "whisperkit/\(model)",
            audioFile: audioURL.lastPathComponent,
            audioDuration: duration,
            transcribeSeconds: elapsed,
            text: results.map(\.text).joined(),
            words: words
        )
        try SpikeJSON.encode(transcript).write(to: URL(fileURLWithPath: output))

        print("转写完成：\(words.count) 词 · \(String(format: "%.1f", duration))s 素材 · "
            + "耗时 \(String(format: "%.1f", elapsed))s · RTF \(String(format: "%.2f", transcript.rtf))")
        print("已写入 \(output)")
    }
}
