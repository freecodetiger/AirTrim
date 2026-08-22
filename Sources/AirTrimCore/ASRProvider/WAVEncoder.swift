import Foundation

/// Float PCM → 16-bit 单声道 WAV（DashScope data URI 上传用）。纯函数，可单测。
public enum WAVEncoder {
    /// - Parameter samples: 归一化 Float 采样（-1...1），如 PCMExtractor 产出
    /// - Parameter sampleRate: 采样率（AirTrim 约定 16kHz）
    public static func wav16(from samples: [Float], sampleRate: Int) -> Data {
        var data = Data(capacity: samples.count * 2 + 44)
        let dataSize = samples.count * 2
        let byteRate = sampleRate * 2
        data.append(Data("RIFF".utf8))
        appendUInt32LE(UInt32(36 + dataSize), to: &data)
        data.append(Data("WAVE".utf8))
        data.append(Data("fmt ".utf8))
        appendUInt32LE(16, to: &data)          // fmt 块大小
        appendUInt16LE(1, to: &data)           // PCM
        appendUInt16LE(1, to: &data)           // 单声道
        appendUInt32LE(UInt32(sampleRate), to: &data)
        appendUInt32LE(UInt32(byteRate), to: &data)
        appendUInt16LE(2, to: &data)           // block align
        appendUInt16LE(16, to: &data)          // 位深
        data.append(Data("data".utf8))
        appendUInt32LE(UInt32(dataSize), to: &data)
        for s in samples {
            let v = Int16(max(-1.0, min(1.0, s)) * 32767.0)
            appendUInt16LE(UInt16(bitPattern: v), to: &data)
        }
        return data
    }

    private static func appendUInt16LE(_ v: UInt16, to data: inout Data) {
        withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func appendUInt32LE(_ v: UInt32, to data: inout Data) {
        withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
    }
}
