import AVFoundation
import AirTrimCore
import ArgumentParser
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 烧录回归：拿 App 的项目缓存 JSON（transcript+patch）出烧录 MP4，
/// 可选导出指定时刻的帧 PNG 供无头视觉验证（release 回归清单用）。
struct Burn: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "把项目缓存 JSON 的字幕烧录进视频（回归验证用）"
    )

    @Option(help: "源视频路径")
    var video: String

    @Option(help: "项目缓存 JSON（~/Library/Application Support/AirTrim/Projects/<指纹>.json）")
    var project: String

    @Option(help: "输出 MP4 路径")
    var output: String

    @Option(name: .customLong("dump-frame"), parsing: .upToNextOption,
            help: "烧录完成后按秒导出帧 PNG（可多个），写到输出同目录")
    var dumpFrames: [Double] = []

    @Flag(help: "一键紧凑耳测：接受缓存里全部 pause 建议（或 --tighten-intensity 现算）后按成片烧录")
    var tighten = false

    @Option(name: .customLong("tighten-intensity"),
            help: "忽略缓存建议，按此紧凑度（0-1）现跑 PauseAnalyzer 并全收")
    var tightenIntensity: Double?

    /// 项目缓存里只取 Core 负载；App 的信封字段（指纹等）不关心
    struct ProjectPayload: Decodable {
        let transcript: Transcript
        let patch: TranscriptPatch
        let edits: EditList?
        let suggestions: [EditSuggestion]?
    }

    func run() async throws {
        let payload = try JSONDecoder().decode(
            ProjectPayload.self, from: Data(contentsOf: URL(fileURLWithPath: project)))
        let cues = Subtitles.cues(transcript: payload.transcript, patch: payload.patch)

        var edits = payload.edits ?? EditList()
        if let intensity = tightenIntensity {
            let fresh = PauseAnalyzer.suggest(
                transcript: payload.transcript,
                effectiveSentences: payload.patch.effectiveSentences(in: payload.transcript),
                silences: payload.transcript.silences,
                params: TightenParams(intensity: intensity))
            for s in fresh { edits.add(s.cut) }
            print("紧凑度 \(intensity)：\(fresh.count) 处停顿全收")
        } else if tighten {
            let pauses = (payload.suggestions ?? []).filter { $0.kind == .pause && $0.state != .rejected }
            for s in pauses { edits.add(s.cut) }
            print("缓存建议全收：\(pauses.count) 处")
        }
        let removed = edits.removedDuration.seconds
        print("字幕 \(cues.count) 条，剪 \(edits.cuts.count) 段共 \(String(format: "%.1f", removed))s，开始烧录…")

        let outputURL = URL(fileURLWithPath: output)
        let t0 = Date()
        try await SubtitleBurner.burn(
            source: URL(fileURLWithPath: video), cues: cues, to: outputURL, edits: edits
        ) { fraction in
            FileHandle.standardError.write(Data("\r\(Int(fraction * 100))%".utf8))
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: output)[.size] as? Int64) ?? 0
        print("\n烧录完成：\(output) · \(size / 1_000_000) MB · 耗时 \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")

        for seconds in dumpFrames {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: outputURL))
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 2)
            let (image, actual) = try await generator.image(
                at: CMTime(seconds: seconds, preferredTimescale: 600))
            let frameURL = outputURL.deletingPathExtension()
                .appendingPathExtension("t\(Int(seconds)).png")
            guard let dest = CGImageDestinationCreateWithURL(
                frameURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw ValidationError("无法创建 PNG：\(frameURL.path)")
            }
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
            print("帧 @\(String(format: "%.1f", actual.seconds))s → \(frameURL.lastPathComponent)")
        }
    }
}
