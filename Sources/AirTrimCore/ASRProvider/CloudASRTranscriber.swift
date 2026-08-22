import CoreMedia
import Foundation

/// 云端 ASR 引擎（DashScope paraformer-v2，ADR-0007）。
/// 逐字时间戳（spike 实测 30/74.5ms 过线）；`file_urls` 收 base64 data URI，免 OSS。
/// 时长上限：data URI ≈9MB（16k mono 16bit ~210s），超长抛错建议本地。
/// ponytail: base64 上限限制长视频，OSS 上传为升级路径。
public struct CloudASRTranscriber: Transcriber {
    public let config: ASRConfig

    /// base64 data URI 能安全承载的最大音频秒数（≈9MB）
    static let maxDurationSeconds = 210.0

    public init(config: ASRConfig) {
        self.config = config
    }

    public func transcribe(audioPath: String, pcm: [Float], language: String = "zh",
                           onProgress: (@Sendable (TranscribePhase) -> Void)? = nil) async throws -> Transcript {
        let duration = Double(pcm.count) / Double(TranscriptAssembly.sampleRate)
        guard duration <= Self.maxDurationSeconds else {
            throw CloudASRError.tooLong(max: Int(Self.maxDurationSeconds))
        }

        onProgress?(.loadingModel)
        let wav = WAVEncoder.wav16(from: pcm, sampleRate: Int(TranscriptAssembly.sampleRate))
        let dataURI = "data:audio/wav;base64," + wav.base64EncodedString()

        let rawWords = try await Self.fetchWords(config: config, dataURI: dataURI,
                                                 language: language) { phase in
            onProgress?(phase)
        }
        onProgress?(.transcribing(1))

        let sourceDuration = CMTime(value: CMTimeValue(pcm.count), timescale: TranscriptAssembly.sampleRate)
        return TranscriptAssembly.makeTranscript(rawWords: rawWords, pcm: pcm, sourceDuration: sourceDuration)
    }

    // MARK: - 网络（提交 → 轮询 → 下载 → 解析）

    private static let baseURL = "https://dashscope.aliyuncs.com"

    /// 提交异步录音文件识别任务并等待完成，返回解析后的原始词（秒）。
    /// 参考：help.aliyun.com/en/model-studio/fun-asr-recorded-speech-recognition-http-api
    static func fetchWords(config: ASRConfig, dataURI: String, language: String,
                           onPhase: @escaping @Sendable (TranscribePhase) -> Void) async throws -> [(text: String, start: Double, end: Double)] {
        onPhase(.uploading)

        var submit = URLRequest(url: URL(string: baseURL + "/api/v1/services/audio/asr/transcription")!)
        submit.httpMethod = "POST"
        submit.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        submit.setValue("application/json", forHTTPHeaderField: "Content-Type")
        submit.setValue("enable", forHTTPHeaderField: "X-DashScope-Async")
        var parameters: [String: Any] = [:]
        if config.model.hasPrefix("paraformer") {   // paraformer 时间戳默认关闭；fun-asr 常开
            parameters["timestamp_alignment_enabled"] = true
            parameters["language_hints"] = [language]
        }
        submit.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": config.model,
            "input": ["file_urls": [dataURI]],
            "parameters": parameters,
        ])
        submit.timeoutInterval = 300

        let (submitData, submitResp) = try await URLSession.shared.data(for: submit)
        guard let http = submitResp as? HTTPURLResponse, http.statusCode == 200,
              let sj = try JSONSerialization.jsonObject(with: submitData) as? [String: Any],
              let taskID = (sj["output"] as? [String: Any])?["task_id"] as? String else {
            throw CloudASRError.badResponse("提交失败（HTTP \((submitResp as? HTTPURLResponse)?.statusCode ?? -1)）：\(String(data: submitData, encoding: .utf8) ?? "")")
        }

        // 轮询至完成（最长 ~5min）
        let taskURL = URL(string: baseURL + "/api/v1/tasks/" + taskID)!
        var transcriptionURL: URL?
        for _ in 0..<60 {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            var query = URLRequest(url: taskURL)
            query.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
            query.timeoutInterval = 60
            guard let (qData, qResp) = try? await URLSession.shared.data(for: query),
                  let qhttp = qResp as? HTTPURLResponse, qhttp.statusCode == 200,
                  let qj = try? JSONSerialization.jsonObject(with: qData) as? [String: Any],
                  let qo = qj["output"] as? [String: Any] else { continue }
            switch qo["task_status"] as? String ?? "" {
            case "SUCCEEDED":
                transcriptionURL = extractTranscriptionURL(qo)
                break
            case "FAILED", "UNKNOWN":
                throw CloudASRError.badResponse("转写任务失败：\(qo["message"] as? String ?? qo["task_status"] as? String ?? "")")
            default:
                continue
            }
        }
        guard let transcriptionURL else {
            throw CloudASRError.badResponse("转写任务超时（>5min）")
        }

        var dl = URLRequest(url: transcriptionURL)
        dl.timeoutInterval = 120
        let (rData, rResp) = try await URLSession.shared.data(for: dl)
        guard (rResp as? HTTPURLResponse)?.statusCode == 200,
              let rj = try JSONSerialization.jsonObject(with: rData) as? [String: Any] else {
            throw CloudASRError.badResponse("结果下载失败：\(String(data: rData, encoding: .utf8) ?? "")")
        }
        return parseWords(from: rj)
    }

    /// 从任务查询结果里取出转录结果下载 URL（嵌套 `results[].output.results[].transcription_url`）。纯函数。
    static func extractTranscriptionURL(_ output: [String: Any]) -> URL? {
        let results = output["results"] as? [[String: Any]] ?? []
        guard let first = results.first else { return nil }
        if let inner = (first["output"] as? [String: Any])?["results"] as? [[String: Any]],
           let url = inner.first?["transcription_url"] as? String {
            return URL(string: url)
        }
        if let url = (first["output"] as? [String: Any])?["transcription_url"] as? String {
            return URL(string: url)
        }
        return nil
    }

    /// 解析转录结果 JSON → 原始词（text + 秒起止）。纯函数，可单测。
    /// 结构：`transcripts[].sentences[].words[] = { begin_time, end_time, text, punctuation }`（毫秒）。
    static func parseWords(from json: [String: Any]) -> [(text: String, start: Double, end: Double)] {
        guard let transcripts = json["transcripts"] as? [[String: Any]],
              let tr = transcripts.first else { return [] }
        let sentences = tr["sentences"] as? [[String: Any]] ?? []
        var out: [(text: String, start: Double, end: Double)] = []
        for s in sentences {
            guard let wordArr = s["words"] as? [[String: Any]] else { continue }
            for w in wordArr {
                guard let text = w["text"] as? String,
                      let b = ms(w["begin_time"]), let e = ms(w["end_time"]) else { continue }
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { continue }
                out.append((text: t, start: Double(b) / 1000.0, end: Double(e) / 1000.0))
            }
        }
        return out
    }

    /// JSON 数字统一取毫秒整数（兼容 Int / Double）。
    private static func ms(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        return nil
    }
}

public enum CloudASRError: Error, LocalizedError {
    /// 素材超过 base64 data URI 上限（OSS 方案为升级路径）
    case tooLong(max: Int)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .tooLong(let max):
            "云端转写暂支持 ≤\(max) 秒（约 \(max / 60) 分钟）素材，请改用本地转写；更长素材的云端方案开发中。"
        case .badResponse(let detail):
            "云端转写失败：\(detail)"
        }
    }
}
