import AVFoundation
import Foundation

/// 从任意 AVFoundation 可读容器（mov/mp4/m4a/wav…）抽取 16kHz 单声道 Float PCM。
enum AudioLoader {
    static let sampleRate = 16000.0

    static func loadMonoPCM(url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw NSError(domain: "AudioLoader", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "找不到音频轨道"])
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
            throw reader.error ?? NSError(domain: "AudioLoader", code: 2)
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
            throw reader.error ?? NSError(domain: "AudioLoader", code: 3)
        }
        return samples
    }
}
