import AVFoundation
import Foundation

/// 从任意 AVFoundation 可读容器抽取 16kHz 单声道 Float PCM（源只读，ADR-0004）。
/// spike AudioLoader 毕业版。消费方：SpeechPipeline 的 VAD（由组合根编排传递）。
public enum PCMExtractor {
    public static let sampleRate: Int32 = 16000

    public static func monoPCM(url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw MediaEngineError.noAudioTrack
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? MediaEngineError.readerFailed
        }

        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var data = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            data.withUnsafeMutableBytes { ptr in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                               destination: ptr.baseAddress!)
            }
            samples.append(contentsOf: data)
        }
        if reader.status == .failed {
            throw reader.error ?? MediaEngineError.readerFailed
        }
        return samples
    }
}

public enum MediaEngineError: Error, LocalizedError {
    case noAudioTrack
    case readerFailed
    case noVideoTrack
    case compositionFailed
    case exportFailed(String?)

    public var errorDescription: String? {
        switch self {
        case .noAudioTrack: "这个文件里没有音频轨道，无法转写。请确认导入的是带声音的口播视频。"
        case .readerFailed: "音频读取失败，文件可能已损坏或格式不受支持。"
        case .noVideoTrack: "这个文件里没有视频轨道，无法烧录字幕。纯音频素材请改用「导出 SRT」。"
        case .compositionFailed: "导出会话创建失败，请重试。"
        case .exportFailed(let reason): "视频导出失败\(reason.map { "：\($0)" } ?? "")。请检查磁盘剩余空间后重试。"
        }
    }
}
