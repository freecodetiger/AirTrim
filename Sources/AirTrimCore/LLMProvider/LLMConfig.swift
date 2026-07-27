import Foundation

/// BYOK 配置，OpenAI 兼容格式。
///
/// 持久化：`~/Library/Application Support/AirTrim/llm-config.json`
/// 用户通过设置窗口编辑保存，纯 JSON 文件，无环境变量、无 Keychain。
public struct LLMConfig: Sendable, Equatable {
    public var baseURL: URL
    public var model: String
    public var apiKey: String

    public init(baseURL: URL, model: String, apiKey: String) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
    }

    // MARK: - 默认值

    public static let defaultBaseURL = "https://api.deepseek.com"
    public static let defaultModel = "deepseek-chat"

    // MARK: - JSON 持久化

    private static var configFile: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AirTrim/llm-config.json")
    }

    private struct FileConfig: Codable {
        var baseURL: String
        var model: String
        var apiKey: String
    }

    /// 从 JSON 文件加载配置。文件不存在或 apiKey 为空时返回 nil。
    public static func load() -> LLMConfig? {
        guard let data = try? Data(contentsOf: configFile),
              let file = try? JSONDecoder().decode(FileConfig.self, from: data),
              !file.apiKey.isEmpty,
              let url = URL(string: file.baseURL) else { return nil }
        return LLMConfig(baseURL: url, model: file.model, apiKey: file.apiKey)
    }

    /// 保存到 JSON 文件（设置窗口使用）。
    public static func save(baseURLString: String, model: String, apiKey: String) throws {
        let dir = configFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config = FileConfig(baseURL: baseURLString, model: model, apiKey: apiKey)
        try JSONEncoder().encode(config).write(to: configFile, options: .atomic)
    }

    /// 配置是否已保存。
    public static var isConfigured: Bool { load() != nil }
}
