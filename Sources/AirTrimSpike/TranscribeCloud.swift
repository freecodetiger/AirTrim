import AirTrimSpikeKit
import ArgumentParser
import Foundation

/// DashScope Fun-ASR 云端转写命令（ADR-0007 spike 验收）。
///
/// 与本地 `Transcribe` 产出**同一 `SpikeTranscript` JSON**，`evaluate`/`gen-truth`/`earcheck`
/// 零改动复用。时间戳精度才是验收项（中位 ≤80ms / P95 ≤200ms）；云端 RTF 受网络影响，仅记录不判过线。
struct TranscribeCloud: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "用 DashScope Fun-ASR 云端转写音/视频，输出词级时间戳 JSON（SpikeTranscript 同构，供 evaluate 复用）"
    )

    @Option(help: "音频或视频文件路径")
    var audio: String

    @Option(help: "DashScope 模型名（fun-asr-flash 默认；可选 qwen-audio-3.0-asr-flash / paraformer-realtime-v2）")
    var model: String = "fun-asr-flash"

    @Option(help: "DashScope API Key（默认读环境变量 DASHSCOPE_API_KEY）")
    var apiKey: String?

    @Option(help: "API 端点（默认 dashscope 北京 legacy 域名；区域专属域名走 --endpoint 覆盖）")
    var endpoint: String = "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation"

    @Option(help: "只转写前 N 秒（0 = 全片；truth 标注只覆盖前 64s，默认 70 避免 API 时长上限）")
    var maxSeconds: Double = 70

    @Flag(help: "异步录音文件识别路径（paraformer-v2 / fun-asr；逐字时间戳，需 timestamp_alignment_enabled）")
    var async: Bool = false

    @Option(help: "输出 JSON 路径")
    var output: String

    func run() async throws {
        let key = apiKey ?? ProcessInfo.processInfo.environment["DASHSCOPE_API_KEY"] ?? ""
        guard !key.isEmpty else {
            throw ValidationError("缺少 DashScope API Key：设环境变量 DASHSCOPE_API_KEY 或传 --api-key")
        }
        let audioURL = URL(fileURLWithPath: audio)
        guard FileManager.default.fileExists(atPath: audio) else {
            throw ValidationError("找不到文件：\(audio)")
        }

        FileHandle.standardError.write(Data("抽取 16kHz 单声道 PCM…\n".utf8))
        var samples = try await AudioLoader.loadMonoPCM(url: audioURL)
        if maxSeconds > 0 {
            let keep = Int(maxSeconds * AudioLoader.sampleRate)
            if samples.count > keep { samples = Array(samples[..<keep]) }
        }
        let duration = Double(samples.count) / AudioLoader.sampleRate

        FileHandle.standardError.write(Data("编码 16-bit WAV → 上传 DashScope（\(model)）…\n".utf8))
        let wav = Self.makeWAV16(from: samples, sampleRate: Int(AudioLoader.sampleRate))
        let dataURI = "data:audio/wav;base64," + wav.base64EncodedString()
        FileHandle.standardError.write(Data(String(format: "音频 %.1fs · WAV %.1fMB · base64 %.1fMB\n",
            duration, Double(wav.count) / 1_048_576, Double(dataURI.count) / 1_048_576).utf8))

        let t0 = Date()
        let (text, words): (String, [SpikeWord])
        if async {
            (text, words) = try await Self.dashscopeAsyncTranscribe(key: key, model: model, dataURI: dataURI)
        } else {
            (text, words) = try await Self.dashscopeTranscribe(key: key, model: model,
                                                               dataURI: dataURI, endpoint: endpoint)
        }
        let elapsed = Date().timeIntervalSince(t0)

        let transcript = SpikeTranscript(
            engine: "dashscope/\(model)",
            audioFile: audioURL.lastPathComponent,
            audioDuration: duration,
            transcribeSeconds: elapsed,
            text: text,
            words: words
        )
        try SpikeJSON.encode(transcript).write(to: URL(fileURLWithPath: output))

        print("转写完成：\(words.count) 词 · \(String(format: "%.1f", duration))s 素材 · "
            + "耗时 \(String(format: "%.1f", elapsed))s（含网络）· RTF \(String(format: "%.2f", transcript.rtf))")
        print("已写入 \(output)")
    }

    /// 调 DashScope Fun-ASR-Flash 同步接口（`output.sentence.words[]` 词级时间戳，毫秒）。
    /// 参考：help.aliyun.com/en/model-studio/non-real-time-speech-recognition-for-fun-asr-flash
    static func dashscopeTranscribe(key: String, model: String, dataURI: String,
                                    endpoint: String) async throws -> (String, [SpikeWord]) {
        var req = URLRequest(url: URL(string: endpoint)!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("disable", forHTTPHeaderField: "X-DashScope-SSE")
        let body: [String: Any] = [
            "model": model,
            "input": ["messages": [["role": "user",
                                    "content": [["type": "input_audio",
                                                 "input_audio": ["data": dataURI]]]]]],
            "parameters": ["format": "wav", "sample_rate": "16000"],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 600

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "TranscribeCloud", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无 HTTP 响应"])
        }
        guard http.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "TranscribeCloud", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)：\(detail)"])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = json["output"] as? [String: Any] else {
            throw NSError(domain: "TranscribeCloud", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "响应缺少 output"])
        }
        let sentence = output["sentence"] as? [String: Any]
        let wordArr = sentence?["words"] as? [[String: Any]] ?? (output["words"] as? [[String: Any]] ?? [])
        let words = wordArr.compactMap { w -> SpikeWord? in
            guard let text = w["text"] as? String,
                  let b = Self.ms(w["begin_time"]), let e = Self.ms(w["end_time"]) else { return nil }
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return nil }
            return SpikeWord(text: t, start: Double(b) / 1000.0, end: Double(e) / 1000.0)
        }
        let text = (sentence?["text"] as? String)
            ?? (output["text"] as? String)
            ?? words.map(\.text).joined()
        return (text, words)
    }

    /// 调 DashScope 异步录音文件识别：提交 → 轮询 `GET /api/v1/tasks/{id}` → 下载 `transcription_url` 结果。
    /// paraformer-v2 为**逐字**时间戳（默认关闭，需 `timestamp_alignment_enabled: true`）；`file_urls` 收 base64 data URI，免 OSS。
    /// 参考：help.aliyun.com/en/model-studio/fun-asr-recorded-speech-recognition-http-api
    static func dashscopeAsyncTranscribe(key: String, model: String,
                                         dataURI: String) async throws -> (String, [SpikeWord]) {
        let baseURL = "https://dashscope.aliyuncs.com"

        var submit = URLRequest(url: URL(string: baseURL + "/api/v1/services/audio/asr/transcription")!)
        submit.httpMethod = "POST"
        submit.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        submit.setValue("application/json", forHTTPHeaderField: "Content-Type")
        submit.setValue("enable", forHTTPHeaderField: "X-DashScope-Async")
        var parameters: [String: Any] = [:]
        if model.hasPrefix("paraformer") {   // fun-asr 时间戳常开；paraformer 需显式开启
            parameters["timestamp_alignment_enabled"] = true
            parameters["language_hints"] = ["zh"]
        }
        submit.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "input": ["file_urls": [dataURI]],
            "parameters": parameters,
        ])
        submit.timeoutInterval = 300

        let (submitData, submitResp) = try await URLSession.shared.data(for: submit)
        guard let submitHTTP = submitResp as? HTTPURLResponse, submitHTTP.statusCode == 200,
              let sj = try JSONSerialization.jsonObject(with: submitData) as? [String: Any],
              let taskID = (sj["output"] as? [String: Any])?["task_id"] as? String else {
            throw NSError(domain: "TranscribeCloud", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "提交失败：HTTP \((submitResp as? HTTPURLResponse)?.statusCode ?? -1)：\(String(data: submitData, encoding: .utf8) ?? "")"])
        }
        FileHandle.standardError.write(Data("异步任务已提交：\(taskID)，轮询中…\n".utf8))

        let taskURL = URL(string: baseURL + "/api/v1/tasks/" + taskID)!
        var transcriptionURL: URL?
        for _ in 0..<120 {   // 最长 ~10min
            try await Task.sleep(nanoseconds: 5_000_000_000)
            var query = URLRequest(url: taskURL)
            query.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            query.timeoutInterval = 60
            guard let (qData, qResp) = try? await URLSession.shared.data(for: query),
                  let qhttp = qResp as? HTTPURLResponse, qhttp.statusCode == 200,
                  let qj = try? JSONSerialization.jsonObject(with: qData) as? [String: Any],
                  let qo = qj["output"] as? [String: Any] else { continue }
            let status = qo["task_status"] as? String ?? ""
            if status == "SUCCEEDED" {
                transcriptionURL = Self.extractTranscriptionURL(qo)
                break
            }
            if status == "FAILED" || status == "UNKNOWN" {
                throw NSError(domain: "TranscribeCloud", code: 5,
                              userInfo: [NSLocalizedDescriptionKey: "任务失败：\(status)"])
            }
        }
        guard let transcriptionURL else {
            throw NSError(domain: "TranscribeCloud", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "轮询超时（10min）"])
        }

        var dl = URLRequest(url: transcriptionURL)
        dl.timeoutInterval = 120
        let (rData, rResp) = try await URLSession.shared.data(for: dl)
        guard (rResp as? HTTPURLResponse)?.statusCode == 200,
              let rj = try JSONSerialization.jsonObject(with: rData) as? [String: Any],
              let transcripts = rj["transcripts"] as? [[String: Any]],
              let tr = transcripts.first else {
            throw NSError(domain: "TranscribeCloud", code: 7,
                          userInfo: [NSLocalizedDescriptionKey: "结果解析失败：\(String(data: rData, encoding: .utf8) ?? "")"])
        }

        let text = tr["text"] as? String ?? ""
        let sentences = tr["sentences"] as? [[String: Any]] ?? []
        let words = sentences.flatMap { s -> [SpikeWord] in
            guard let wordArr = s["words"] as? [[String: Any]] else { return [] }
            return wordArr.compactMap { w -> SpikeWord? in
                guard let text = w["text"] as? String,
                      let b = Self.ms(w["begin_time"]), let e = Self.ms(w["end_time"]) else { return nil }
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { return nil }
                return SpikeWord(text: t, start: Double(b) / 1000.0, end: Double(e) / 1000.0)
            }
        }
        return (text, words)
    }

    /// 从任务结果里取出转录结果下载 URL（嵌套路径 `results[].output.results[].transcription_url`）。
    private static func extractTranscriptionURL(_ output: [String: Any]) -> URL? {
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

    /// JSON 数字统一取毫秒整数（兼容 Int / Double 两种解析）。
    private static func ms(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        return nil
    }

    /// Float PCM → 16-bit 单声道 WAV（RIFF/PCM 头 + 小端采样）。
    static func makeWAV16(from samples: [Float], sampleRate: Int) -> Data {
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
