import Foundation

/// OpenAI 兼容 chat.completions 客户端。Core 内允许联网的两个模块之一（另一为 ASRProvider/，架构守卫强制）。
/// 只发送文字稿——音视频字节绝不经过这里（CLAUDE.md 铁律；音频上云仅 ASRProvider，ADR-0007）。
public struct OpenAIChatClient: Sendable {
    public let config: LLMConfig

    public init(config: LLMConfig) {
        self.config = config
    }

    public func complete(system: String, user: String, temperature: Double = 0) async throws -> String {
        var endpoint = config.baseURL
        if !endpoint.path.hasSuffix("/chat/completions") {
            endpoint.append(path: "/chat/completions")
        }
        var request = URLRequest(url: endpoint, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": config.model,
            "temperature": temperature,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.badResponse("非 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.badResponse("HTTP \(http.statusCode)：\(body.prefix(200))")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMError.badResponse("响应格式不符合 OpenAI chat.completions")
        }
        return content
    }
}

public enum LLMError: Error, LocalizedError {
    case notConfigured
    case badResponse(String)
    case textMismatch

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "未配置 LLM（请打开设置 → AI 服务 → 填写 API Key 并保存）"
        case .badResponse(let detail): "LLM 请求失败：\(detail)"
        case .textMismatch: "模型改动了文本内容，已放弃本次断句（可重试）"
        }
    }
}
