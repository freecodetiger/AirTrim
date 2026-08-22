import Foundation

/// DashScope 云端转写 BYOK 配置（ADR-0007）。
///
/// 持久化：`~/Library/Application Support/AirTrim/asr-config.json`
/// 与 `LLMConfig` 同模式：纯 JSON 文件，无环境变量、无 Keychain。
public struct ASRConfig: Sendable, Equatable {
    public var apiKey: String
    /// DashScope 模型名（默认 paraformer-v2，逐字时间戳）
    public var model: String

    public init(apiKey: String, model: String) {
        self.apiKey = apiKey
        self.model = model
    }

    // MARK: - 默认值

    public static let defaultModel = "paraformer-v2"

    // MARK: - JSON 持久化

    private static var configFile: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AirTrim/asr-config.json")
    }

    private struct FileConfig: Codable {
        var apiKey: String
        var model: String
    }

    /// 从 JSON 文件加载配置。文件不存在或 apiKey 为空时返回 nil。
    public static func load() -> ASRConfig? {
        guard let data = try? Data(contentsOf: configFile),
              let file = try? JSONDecoder().decode(FileConfig.self, from: data),
              !file.apiKey.isEmpty else { return nil }
        return ASRConfig(apiKey: file.apiKey, model: file.model.isEmpty ? defaultModel : file.model)
    }

    /// 保存到 JSON 文件（设置窗口使用）。
    public static func save(apiKey: String, model: String) throws {
        let dir = configFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config = FileConfig(apiKey: apiKey, model: model)
        try JSONEncoder().encode(config).write(to: configFile, options: .atomic)
    }

    /// 配置是否已保存。
    public static var isConfigured: Bool { load() != nil }
}
