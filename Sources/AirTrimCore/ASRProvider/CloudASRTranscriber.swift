import CoreMedia
import Foundation

/// 云端 ASR 引擎（DashScope paraformer-v2，ADR-0007）。
/// 逐字时间戳（spike 实测 30/74.5ms 过线）；`file_urls` 收 base64 data URI，免 OSS。
/// **任意时长**：按 VAD 静音间隙切块（每段 ≤180s，单段 data URI ≤~7.7MB），
/// 逐段提交异步任务 → 轮询 → 按段偏移拼接 → 全局 `TranscriptAssembly`（VAD 融合跨段一致）。
public struct CloudASRTranscriber: Transcriber {
    public let config: ASRConfig

    /// 单段 data URI 硬上限对应的秒数（≈9MB，16k mono 16bit ~210s）
    static let maxChunkDuration = 210.0
    /// 目标段长（留余量；切点落在 VAD 静音中点，实际段可能略长/略短）
    static let targetChunkDuration = 180.0
    /// 小于该秒数的尾段并入上一段（避免为几秒开一个任务）
    static let minTailChunk = 30.0
    /// 可作切点的静音最小宽度（VAD 默认 0.3s，这里取 0.25s）
    static let minCutSilence = 0.25

    public init(config: ASRConfig) {
        self.config = config
    }

    public func transcribe(audioPath: String, pcm: [Float], language: String = "zh",
                           onProgress: (@Sendable (TranscribePhase) -> Void)? = nil) async throws -> Transcript {
        guard !pcm.isEmpty else { throw CloudASRError.badResponse("音频为空") }
        let sampleRate = Int(TranscriptAssembly.sampleRate)

        // 1. 按 VAD 静音间隙切块（切点不落在词上，任意长度）
        let silences = EnergyVAD.silences(samples: pcm, sampleRate: TranscriptAssembly.sampleRate)
        let chunks = Self.chunkRanges(silences: silences, sampleCount: pcm.count, sampleRate: sampleRate,
                                      target: Self.targetChunkDuration, max: Self.maxChunkDuration,
                                      minTail: Self.minTailChunk)

        // 2. 逐段提交异步任务（提交很快，先全部提交再统一轮询）
        onProgress?(.loadingModel)
        struct ChunkRef { let offset: Int; let taskID: String }
        var refs: [ChunkRef] = []
        for chunk in chunks {
            let segment = Array(pcm[chunk])
            let wav = WAVEncoder.wav16(from: segment, sampleRate: sampleRate)
            let dataURI = "data:audio/wav;base64," + wav.base64EncodedString()
            let taskID = try await Self.submitTask(config: config, dataURI: dataURI, language: language)
            refs.append(ChunkRef(offset: chunk.lowerBound, taskID: taskID))
        }
        onProgress?(.uploading)

        // 3. 轮询全部完成（每轮查未完成的段），下载并解析各段原始词
        var results: [String: [(text: String, start: Double, end: Double)]] = [:]
        while results.count < refs.count {
            for ref in refs where results[ref.taskID] == nil {
                if let words = try await Self.tryFetch(config: config, taskID: ref.taskID) {
                    results[ref.taskID] = words
                }
            }
            onProgress?(.transcribing(Double(results.count) / Double(refs.count)))
            if results.count < refs.count {
                try await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        onProgress?(.transcribing(1))

        // 4. 按段偏移拼接成完整时间轴的原始词
        var rawWords: [(text: String, start: Double, end: Double)] = []
        for ref in refs.sorted(by: { $0.offset < $1.offset }) {
            guard let words = results[ref.taskID] else { continue }
            let offset = Double(ref.offset) / Double(sampleRate)
            rawWords.append(contentsOf: words.map {
                (text: $0.text, start: $0.start + offset, end: $0.end + offset)
            })
        }

        // 5. 全局后处理：VAD 融合基于全 pcm，跨段一致
        let sourceDuration = CMTime(value: CMTimeValue(pcm.count), timescale: TranscriptAssembly.sampleRate)
        return TranscriptAssembly.makeTranscript(rawWords: rawWords, pcm: pcm, sourceDuration: sourceDuration)
    }

    // MARK: - 切块

    /// 按 VAD 静音间隙把音频切成 ≤max 秒的段；切点取 target 前最近静音的中点（不切词）。
    /// 段内无可用静音时在 target 硬切；尾段 < minTail 秒时并入上一段。
    static func chunkRanges(silences: [SilenceInterval], sampleCount: Int, sampleRate: Int,
                            target: Double, max: Double, minTail: Double) -> [Range<Int>] {
        guard sampleCount > 0 else { return [] }
        let targetS = Int(target * Double(sampleRate))
        let maxS = Int(max * Double(sampleRate))
        let minSilS = Int(minCutSilence * Double(sampleRate))
        let sil = silences.map {
            (start: Int($0.start.seconds * Double(sampleRate)), end: Int($0.end.seconds * Double(sampleRate)))
        }

        var cuts: [Int] = [0]
        var cursor = 0
        while sampleCount - cursor > targetS {
            let windowEnd = cursor + targetS
            // 窗口内最后一个足够宽的静音（end 在窗口内且在 cursor 之后）
            let lastSil = sil.last { $0.end - $0.start >= minSilS && $0.end <= windowEnd && $0.end > cursor }
            let cut = lastSil.map { ($0.start + $0.end) / 2 } ?? windowEnd
            cuts.append(cut > cursor + 1 ? cut : cursor + 1)   // 防御：至少前进一帧
            cursor = cuts.last!
        }
        cuts.append(sampleCount)

        // 尾段太小则并入上一段（合并后 ≤ target + minTail ≤ max）
        if cuts.count >= 3 {
            let tailStart = cuts[cuts.count - 2]
            if sampleCount - tailStart < Int(minTail * Double(sampleRate)) {
                cuts.remove(at: cuts.count - 2)
            }
        }

        return (0..<(cuts.count - 1)).map { cuts[$0]..<cuts[$0 + 1] }
    }

    // MARK: - 网络（提交 / 查询 / 下载）

    private static let baseURL = "https://dashscope.aliyuncs.com"

    /// 提交一段异步录音文件识别任务，返回 task_id。
    /// 参考：help.aliyun.com/en/model-studio/fun-asr-recorded-speech-recognition-http-api
    static func submitTask(config: ASRConfig, dataURI: String, language: String) async throws -> String {
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

        let (data, resp) = try await URLSession.shared.data(for: submit)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let sj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let taskID = (sj["output"] as? [String: Any])?["task_id"] as? String else {
            throw CloudASRError.badResponse("提交失败（HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)）：\(String(data: data, encoding: .utf8) ?? "")")
        }
        return taskID
    }

    /// 查询任务并取结果：SUCCEEDED → 下载解析返回词；PENDING/RUNNING → nil（继续轮询）；
    /// FAILED → throw；查询网络错误 → nil（下一轮重试）。
    static func tryFetch(config: ASRConfig, taskID: String) async throws -> [(text: String, start: Double, end: Double)]? {
        var query = URLRequest(url: URL(string: baseURL + "/api/v1/tasks/" + taskID)!)
        query.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        query.timeoutInterval = 60
        guard let (qData, qResp) = try? await URLSession.shared.data(for: query),
              let qhttp = qResp as? HTTPURLResponse, qhttp.statusCode == 200,
              let qj = try? JSONSerialization.jsonObject(with: qData) as? [String: Any],
              let qo = qj["output"] as? [String: Any] else { return nil }
        switch qo["task_status"] as? String ?? "" {
        case "SUCCEEDED":
            guard let url = extractTranscriptionURL(qo) else {
                throw CloudASRError.badResponse("任务成功但缺少结果 URL")
            }
            return try await downloadAndParse(config: config, url: url)
        case "FAILED", "UNKNOWN":
            throw CloudASRError.badResponse("转写任务失败：\(qo["message"] as? String ?? qo["task_status"] as? String ?? "")")
        default:
            return nil
        }
    }

    /// 下载转录结果 JSON 并解析为原始词（秒）。
    static func downloadAndParse(config: ASRConfig, url: URL) async throws -> [(text: String, start: Double, end: Double)] {
        var dl = URLRequest(url: url)
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
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .badResponse(let detail):
            "云端转写失败：\(detail)"
        }
    }
}
