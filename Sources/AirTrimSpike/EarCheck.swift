import AVFoundation
import AirTrimSpikeKit
import ArgumentParser
import Foundation

struct EarCheck: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "earcheck",
        abstract: "按词级时间戳剪除长停顿并导出成片，用耳朵验收切点是否自然"
    )

    @Option(help: "源视频/音频文件")
    var source: String

    @Option(help: "transcribe 输出的 JSON（--vad 模式下可省略）")
    var transcript: String?

    @Flag(name: .customLong("vad"), help: "用能量 VAD 检测停顿（不依赖 ASR 词时间戳）")
    var useVAD = false

    @Option(name: .customLong("min-gap"), help: "剪除 ≥ 此时长的停顿（秒）")
    var minGap: Double = 0.5

    @Option(name: .customLong("min-pause-keep"), help: "切口保留的最小自然停顿（秒）")
    var minPauseKeep: Double = 0.15

    @Option(help: "词边界外扩 padding（秒）")
    var padding: Double = 0.05

    @Option(help: "输出文件路径（.mov / .m4a）")
    var output: String

    func run() async throws {
        let sourceURL = URL(fileURLWithPath: source)
        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration).seconds

        let gaps: [ClosedRange<Double>]
        if useVAD {
            let samples = try await AudioLoader.loadMonoPCM(url: sourceURL)
            gaps = EnergyVAD.silences(samples: samples, sampleRate: AudioLoader.sampleRate,
                                      minDuration: minGap)
            print("停顿检测：能量 VAD")
        } else {
            guard let transcript else {
                throw ValidationError("需要 --transcript，或改用 --vad")
            }
            let t = try SpikeJSON.decode(
                SpikeTranscript.self,
                from: try Data(contentsOf: URL(fileURLWithPath: transcript))
            )
            gaps = CutPlan.silenceGaps(words: t.words, minGap: minGap)
            print("停顿检测：ASR 词间隙")
        }
        let cuts = CutPlan.cutRegions(gaps: gaps, minPauseKeep: minPauseKeep, padding: padding)
        let keeps = CutPlan.keepRanges(duration: duration, cuts: cuts)
        guard !keeps.isEmpty else { throw ValidationError("保留区间为空——检查转写与参数") }

        let removed = CutPlan.removedSeconds(cuts)
        print("停顿 \(gaps.count) 处 · 剪除 \(cuts.count) 段 · "
            + "\(String(format: "%.1f", duration))s → \(String(format: "%.1f", duration - removed))s")

        // 源永远只读：所有"剪辑"只发生在 composition 里，导出产生新文件（ADR-0004 同款路径）
        let comp = AVMutableComposition()
        for keep in keeps {
            let range = CMTimeRange(
                start: CMTime(seconds: keep.lowerBound, preferredTimescale: 600),
                end: CMTime(seconds: keep.upperBound, preferredTimescale: 600)
            )
            try await comp.insertTimeRange(range, of: asset, at: comp.duration)
        }

        // 切口 equal-power 近似：每个拼接点前后 30ms 音量 ramp，避免爆音（cut-quality 规则的简化版）
        var audioMix: AVAudioMix?
        if let audioTrack = comp.tracks(withMediaType: .audio).first {
            let params = AVMutableAudioMixInputParameters(track: audioTrack)
            let fade = CMTime(seconds: 0.03, preferredTimescale: 600)
            var junction = CMTime.zero
            for keep in keeps.dropLast() {
                junction = junction + CMTime(seconds: keep.upperBound - keep.lowerBound, preferredTimescale: 600)
                params.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0.3,
                                     timeRange: CMTimeRange(start: junction - fade, duration: fade))
                params.setVolumeRamp(fromStartVolume: 0.3, toEndVolume: 1,
                                     timeRange: CMTimeRange(start: junction, duration: fade))
            }
            let mix = AVMutableAudioMix()
            mix.inputParameters = [params]
            audioMix = mix
        }

        let hasVideo = !comp.tracks(withMediaType: .video).isEmpty
        guard let session = AVAssetExportSession(
            asset: comp,
            presetName: hasVideo ? AVAssetExportPresetHighestQuality : AVAssetExportPresetAppleM4A
        ) else {
            throw ValidationError("无法创建导出会话")
        }
        session.audioMix = audioMix
        let outURL = URL(fileURLWithPath: output)
        try? FileManager.default.removeItem(at: outURL)
        let fileType: AVFileType = hasVideo ? .mov : .m4a
        if #available(macOS 15.0, *) {
            try await session.export(to: outURL, as: fileType)
        } else {
            session.outputURL = outURL
            session.outputFileType = fileType
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                session.exportAsynchronously { cont.resume() }
            }
            if session.status != .completed {
                throw session.error ?? ValidationError("导出失败（status \(session.status.rawValue)）")
            }
        }

        print("已导出 \(output) —— 戴耳机听切点：不吞字、不跳变、停顿自然即为通过")
    }
}
