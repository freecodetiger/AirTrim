import AVFoundation
import CoreMedia
import Foundation

/// EditList → 可播放/可导出的合成（MediaEngine 唯一 owner）。
/// keep 段依次拼接：视频跳切（口播成熟语言），音频切点 30ms 淡出淡入
/// 消除爆音（cut-quality skill；v1 单轨 ramp，耳测不过再上双轨 equal-power）。
public enum PreviewComposer {
    /// 音频切点淡化时长
    public static let fade = CMTime(value: 30, timescale: 1000)

    /// AVMutableComposition/AVAudioMix 非 Sendable；此处构建后单向移交给
    /// 播放器或导出会话，不再共享可变访问，故 @unchecked 是诚实的
    public struct Output: @unchecked Sendable {
        public let composition: AVMutableComposition
        public let audioMix: AVAudioMix?
    }

    public static func compose(url: URL, edits: EditList) async throws -> Output {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let segments = edits.keepSegments(sourceDuration: duration)
        guard !segments.isEmpty else { throw MediaEngineError.compositionFailed }

        let composition = AVMutableComposition()
        let videoTrack = try await asset.loadTracks(withMediaType: .video).first
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        guard videoTrack != nil || audioTrack != nil else {
            throw MediaEngineError.compositionFailed
        }

        var compVideo: AVMutableCompositionTrack?
        if let videoTrack {
            compVideo = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            compVideo?.preferredTransform = try await videoTrack.load(.preferredTransform)
        }
        var compAudio: AVMutableCompositionTrack?
        if audioTrack != nil {
            compAudio = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        }

        var cursor = CMTime.zero
        for segment in segments {
            if let videoTrack, let compVideo {
                try compVideo.insertTimeRange(segment, of: videoTrack, at: cursor)
            }
            if let audioTrack, let compAudio {
                try compAudio.insertTimeRange(segment, of: audioTrack, at: cursor)
            }
            cursor = CMTimeAdd(cursor, segment.duration)
        }

        var audioMix: AVAudioMix?
        if let compAudio, segments.count > 1 {
            let params = AVMutableAudioMixInputParameters(track: compAudio)
            for window in fadeWindows(segmentDurations: segments.map(\.duration), fade: fade) {
                params.setVolumeRamp(fromStartVolume: window.fromVolume,
                                     toEndVolume: window.toVolume,
                                     timeRange: window.range)
            }
            let mix = AVMutableAudioMix()
            mix.inputParameters = [params]
            audioMix = mix
        }
        return Output(composition: composition, audioMix: audioMix)
    }

    /// AVPlayerItem.audioMix 在 SDK 中为 MainActor 隔离，故此入口限定主线程
    @MainActor
    public static func playerItem(url: URL, edits: EditList) async throws -> AVPlayerItem {
        let output = try await compose(url: url, edits: edits)
        let item = AVPlayerItem(asset: output.composition)
        item.audioMix = output.audioMix
        return item
    }

    /// 拼接点淡化窗口（成片时间轴，纯函数可测）：
    /// 每个接缝处 前段末尾 fade 淡出 + 后段开头 fade 淡入；窗口不越段边界。
    struct FadeWindow: Equatable {
        let range: CMTimeRange
        let fromVolume: Float
        let toVolume: Float
    }

    static func fadeWindows(segmentDurations: [CMTime], fade: CMTime) -> [FadeWindow] {
        var windows: [FadeWindow] = []
        var junction = CMTime.zero
        for (i, duration) in segmentDurations.enumerated() {
            let segmentStart = junction
            junction = CMTimeAdd(junction, duration)
            let half = CMTimeMinimum(fade, duration)
            if i > 0 {                       // 段首淡入（首段除外）
                windows.append(FadeWindow(
                    range: CMTimeRange(start: segmentStart, duration: half),
                    fromVolume: 0, toVolume: 1))
            }
            if i < segmentDurations.count - 1 {   // 段尾淡出（末段除外）
                windows.append(FadeWindow(
                    range: CMTimeRange(start: CMTimeSubtract(junction, half), duration: half),
                    fromVolume: 1, toVolume: 0))
            }
        }
        // 极短段（< 2×fade）会让淡入淡出窗口重叠，AVAudioMix 不接受重叠 ramp：
        // 裁掉与前一窗口重叠的部分（宁可淡化不完整，不可无效 mix）
        var pruned: [FadeWindow] = []
        for w in windows.sorted(by: { CMTimeCompare($0.range.start, $1.range.start) < 0 }) {
            if let last = pruned.last,
               CMTimeCompare(w.range.start, last.range.end) < 0 {
                let start = last.range.end
                guard CMTimeCompare(start, w.range.end) < 0 else { continue }
                pruned.append(FadeWindow(range: CMTimeRange(start: start, end: w.range.end),
                                         fromVolume: w.fromVolume, toVolume: w.toVolume))
            } else {
                pruned.append(w)
            }
        }
        return pruned
    }
}
