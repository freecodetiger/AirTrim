import Foundation

// MARK: - 已安装模型

/// 本地已安装的语音模型信息。
public struct InstalledModel: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let directory: URL
    public let sizeBytes: Int64
    /// nil = 未校验；true/false = 是否完整
    public let isValid: Bool?
    public let isManaged: Bool    // 是否在应用自管目录下

    public init(id: String, name: String, directory: URL, sizeBytes: Int64,
                isValid: Bool?, isManaged: Bool) {
        self.id = id
        self.name = name
        self.directory = directory
        self.sizeBytes = sizeBytes
        self.isValid = isValid
        self.isManaged = isManaged
    }

    /// 格式化大小。
    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

// MARK: - 校验结果

/// 模型结构校验结果。
public struct ModelValidation: Sendable {
    public let isValid: Bool
    public let hasConfig: Bool
    public let hasGenerationConfig: Bool
    public let hasAudioEncoder: Bool
    public let hasMelSpectrogram: Bool
    public let hasTextDecoder: Bool
    public let hasTokenizer: Bool
    public let missingFiles: [String]
}

// MARK: - 模型校验器

/// 校验本地模型目录结构是否符合 WhisperKit CoreML 模型规范。
public enum ModelValidator {
    /// 校验模型目录。不检查文件尺寸（那是 installer 的职责），只检查必需组件是否存在。
    public static func validate(at url: URL) -> ModelValidation {
        let fm = FileManager.default
        let hasConfig = fm.fileExists(atPath: url.appendingPathComponent("config.json").path)
        let hasGenConfig = fm.fileExists(atPath: url.appendingPathComponent("generation_config.json").path)
        let hasAudioEnc = fm.fileExists(atPath: url.appendingPathComponent("AudioEncoder.mlmodelc").path)
        let hasMel = fm.fileExists(atPath: url.appendingPathComponent("MelSpectrogram.mlmodelc").path)
        let hasTextDec = fm.fileExists(atPath: url.appendingPathComponent("TextDecoder.mlmodelc").path)
        let hasTokenizer = fm.fileExists(atPath: url.appendingPathComponent("tokenizer/tokenizer.json").path)

        // 核心组件：三编码器 + config
        let hasCore = hasConfig && hasAudioEnc && hasMel && hasTextDec

        var missing: [String] = []
        if !hasConfig { missing.append("config.json") }
        if !hasGenConfig { missing.append("generation_config.json") }
        if !hasAudioEnc { missing.append("AudioEncoder.mlmodelc/") }
        if !hasMel { missing.append("MelSpectrogram.mlmodelc/") }
        if !hasTextDec { missing.append("TextDecoder.mlmodelc/") }
        if !hasTokenizer { missing.append("tokenizer/（未安装则可能触发联网）") }

        return ModelValidation(
            isValid: hasCore,
            hasConfig: hasConfig,
            hasGenerationConfig: hasGenConfig,
            hasAudioEncoder: hasAudioEnc,
            hasMelSpectrogram: hasMel,
            hasTextDecoder: hasTextDec,
            hasTokenizer: hasTokenizer,
            missingFiles: missing
        )
    }

    /// 递归计算目录大小。
    public static func directorySize(at url: URL) -> Int64 {
        guard let files = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in files {
            total += Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }
}
