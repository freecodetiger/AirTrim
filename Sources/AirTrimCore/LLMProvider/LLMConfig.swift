import Foundation
import Security

/// BYOK 配置（ADR-0003）：Key 存 Keychain，端点/模型存 UserDefaults。
/// OpenAI 兼容格式：baseURL 如 https://api.deepseek.com 或 https://api.openai.com/v1
public struct LLMConfig: Sendable, Equatable {
    public var baseURL: URL
    public var model: String
    public var apiKey: String

    public init(baseURL: URL, model: String, apiKey: String) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
    }
}

public enum LLMSettings {
    static let urlKey = "llm.baseURL"
    static let modelKey = "llm.model"
    public static let defaultBaseURL = "https://api.deepseek.com"
    public static let defaultModel = "deepseek-chat"

    public static func load() -> LLMConfig? {
        guard let apiKey = KeychainStore.load(), !apiKey.isEmpty else { return nil }
        let defaults = UserDefaults.standard
        let urlString = defaults.string(forKey: urlKey) ?? defaultBaseURL
        guard let url = URL(string: urlString) else { return nil }
        return LLMConfig(baseURL: url,
                         model: defaults.string(forKey: modelKey) ?? defaultModel,
                         apiKey: apiKey)
    }

    public static func save(baseURLString: String, model: String, apiKey: String) throws {
        let defaults = UserDefaults.standard
        defaults.set(baseURLString, forKey: urlKey)
        defaults.set(model, forKey: modelKey)
        try KeychainStore.save(apiKey)
    }
}

/// Keychain 读写（LLMProvider 是 Key 的唯一 owner，见 ownership-map）
enum KeychainStore {
    static let service = "dev.airtrim.llm"
    static let account = "api_key"

    static func save(_ value: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Keychain 写入失败（\(status)）"])
        }
    }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
