import Foundation

/// 应用层模型安装器（设计 D1）：Core 永不联网，下载全部发生在这里。
/// 断点续传（ranged GET）+ 逐文件尺寸校验 + 多下载源自动回退。
/// 安装完成后 SpeechPipeline 以纯本地方式加载（模型 + tokenizer 双离线）。

public struct ModelManifest: Sendable {
    public struct File: Sendable {
        public let path: String       // 目标相对路径（相对模型目录）
        public let remotePath: String // 源站相对路径
        public let size: Int64

        public init(path: String, remotePath: String, size: Int64) {
            self.path = path
            self.remotePath = remotePath
            self.size = size
        }
    }

    public let name: String
    public let files: [File]
    /// 每个源是 (模型文件基址, tokenizer 文件基址)
    public let sources: [(model: URL, tokenizer: URL)]

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    /// v1 唯一档位：已通过 M0 评测的 large-v3（分档是后续产品能力，见设计 D1 修订）
    public static let largeV3: ModelManifest = {
        let m = "openai_whisper-large-v3"
        let model: [(String, Int64)] = [
            ("AudioEncoder.mlmodelc/analytics/coremldata.bin", 243),
            ("AudioEncoder.mlmodelc/coremldata.bin", 348),
            ("AudioEncoder.mlmodelc/metadata.json", 1826),
            ("AudioEncoder.mlmodelc/model.mil", 581035),
            ("AudioEncoder.mlmodelc/model.mlmodel", 408667),
            ("AudioEncoder.mlmodelc/weights/weight.bin", 1_273_974_400),
            ("MelSpectrogram.mlmodelc/analytics/coremldata.bin", 243),
            ("MelSpectrogram.mlmodelc/coremldata.bin", 329),
            ("MelSpectrogram.mlmodelc/metadata.json", 1850),
            ("MelSpectrogram.mlmodelc/model.mil", 10187),
            ("MelSpectrogram.mlmodelc/weights/weight.bin", 373_376),
            ("TextDecoder.mlmodelc/analytics/coremldata.bin", 243),
            ("TextDecoder.mlmodelc/coremldata.bin", 637),
            ("TextDecoder.mlmodelc/metadata.json", 4770),
            ("TextDecoder.mlmodelc/model.mil", 1_010_477),
            ("TextDecoder.mlmodelc/model.mlmodel", 745_579),
            ("TextDecoder.mlmodelc/weights/weight.bin", 1_813_201_716),
            ("config.json", 1163),
            ("generation_config.json", 2810),
        ]
        // tokenizer 放 <模型目录>/tokenizer/，WhisperKit 支持顶层 tokenizer.json 目录
        let tokenizer: [(String, Int64)] = [
            ("tokenizer.json", 2_480_617),
            ("tokenizer_config.json", 282_843),
            ("config.json", 1272),
            ("special_tokens_map.json", 2072),
            ("vocab.json", 1_036_558),
            ("merges.txt", 493_869),
            ("normalizer.json", 52_666),
            ("added_tokens.json", 34_648),
        ]
        return ModelManifest(
            name: m,
            files: model.map { .init(path: $0.0, remotePath: "\(m)/\($0.0)", size: $0.1) }
                + tokenizer.map { .init(path: "tokenizer/\($0.0)", remotePath: $0.0, size: $0.1) },
            sources: [
                (URL(string: "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/main")!,
                 URL(string: "https://huggingface.co/openai/whisper-large-v3/resolve/main")!),
                (URL(string: "https://hf-mirror.com/argmaxinc/whisperkit-coreml/resolve/main")!,
                 URL(string: "https://hf-mirror.com/openai/whisper-large-v3/resolve/main")!),
            ]
        )
    }()
}

public struct InstallProgress: Sendable {
    public let bytesDone: Int64
    public let bytesTotal: Int64
    public let filesDone: Int
    public let filesTotal: Int
    public let currentFile: String

    public init(bytesDone: Int64, bytesTotal: Int64, filesDone: Int, filesTotal: Int, currentFile: String) {
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
        self.filesDone = filesDone
        self.filesTotal = filesTotal
        self.currentFile = currentFile
    }

    public var fraction: Double { bytesTotal > 0 ? Double(bytesDone) / Double(bytesTotal) : 0 }
}

public enum InstallError: Error, LocalizedError {
    case sizeMismatch(file: String, got: Int64, want: Int64)
    case httpError(file: String, code: Int)
    case allSourcesFailed(file: String, underlying: String)
    case insufficientDisk(needed: Int64, available: Int64)

    public var errorDescription: String? {
        switch self {
        case .sizeMismatch(let f, let got, let want): "\(f) 校验失败（\(got)/\(want) 字节）"
        case .httpError(let f, let code): "\(f) 下载失败（HTTP \(code)）"
        case .allSourcesFailed(let f, let underlying): "\(f) 所有下载源均失败：\(underlying)"
        case .insufficientDisk(let needed, let available):
            "磁盘空间不足：还需约 \(needed / 1_000_000_000 + 1) GB，当前可用 \(available / 1_000_000_000) GB。清理后点重试可从断点继续。"
        }
    }
}

public actor ModelInstaller {
    private let manifest: ModelManifest
    private let destination: URL
    private let session: URLSession

    // 进度状态（actor 隔离，避免闭包捕获可变量）
    private var bytesDone: Int64 = 0
    private var filesDoneCount = 0
    private var onProgress: (@Sendable (InstallProgress) -> Void)?

    private func report(delta: Int64, currentFile: String) {
        bytesDone += delta
        onProgress?(InstallProgress(
            bytesDone: bytesDone, bytesTotal: manifest.totalBytes,
            filesDone: filesDoneCount, filesTotal: manifest.files.count,
            currentFile: currentFile))
    }

    public init(manifest: ModelManifest, destination: URL) {
        self.manifest = manifest
        self.destination = destination
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600 * 6
        self.session = URLSession(configuration: config)
    }

    /// 已就绪字节数（尺寸匹配的文件计入），用于展示与跳过
    public func plan() -> (skip: Int64, todo: [ModelManifest.File]) {
        var skip: Int64 = 0
        var todo: [ModelManifest.File] = []
        for f in manifest.files {
            if localSize(of: f) == f.size {
                skip += f.size
            } else {
                todo.append(f)
            }
        }
        return (skip, todo)
    }

    public func install(onProgress: @Sendable @escaping (InstallProgress) -> Void) async throws -> URL {
        let modelDir = destination.appendingPathComponent(manifest.name, isDirectory: true)
        let (skipped, todo) = plan()
        // 磁盘预检：剩余待下载字节 + 1GB 余量；不足时先报错，别下到一半才失败
        try? FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        let remaining = todo.reduce(Int64(0)) { $0 + $1.size }
        if let values = try? modelDir.resourceValues(
               forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let available = values.volumeAvailableCapacityForImportantUsage,
           available < remaining + 1_000_000_000 {
            throw InstallError.insufficientDisk(needed: remaining, available: available)
        }
        self.onProgress = onProgress
        self.bytesDone = skipped
        self.filesDoneCount = manifest.files.count - todo.count

        for file in todo {
            var lastError = "无"
            var succeeded = false
            for source in manifest.sources {
                let base = file.path.hasPrefix("tokenizer/") ? source.tokenizer : source.model
                let url = base.appendingPathComponent(file.remotePath)
                do {
                    try await download(file: file, from: url, into: modelDir)
                    succeeded = true
                    break
                } catch {
                    lastError = error.localizedDescription
                    continue    // 换源重试；已下载的部分保留，续传接力
                }
            }
            guard succeeded else {
                throw InstallError.allSourcesFailed(file: file.path, underlying: lastError)
            }
            filesDoneCount += 1
        }
        return modelDir
    }

    private func localSize(of file: ModelManifest.File) -> Int64 {
        let url = destination.appendingPathComponent(manifest.name).appendingPathComponent(file.path)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? Int64) ?? -1
    }

    private func download(
        file: ModelManifest.File, from url: URL, into modelDir: URL
    ) async throws {
        let target = modelDir.appendingPathComponent(file.path)
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(),
                               withIntermediateDirectories: true)

        var existing: Int64 = 0
        if let attrs = try? fm.attributesOfItem(atPath: target.path),
           let size = attrs[.size] as? Int64 {
            if size == file.size { return }
            if size < file.size {
                existing = size          // 断点续传
            } else {
                try fm.removeItem(at: target)   // 脏文件重来
            }
        }

        var request = URLRequest(url: url)
        if existing > 0 {
            request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range")
        }

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw InstallError.httpError(file: file.path, code: -1)
        }
        switch http.statusCode {
        case 200:
            // 源不支持 Range，从头来
            if existing > 0 { try? fm.removeItem(at: target); existing = 0 }
        case 206:
            break
        default:
            throw InstallError.httpError(file: file.path, code: http.statusCode)
        }

        if !fm.fileExists(atPath: target.path) {
            fm.createFile(atPath: target.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        try handle.seekToEnd()

        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: buffer)
                report(delta: Int64(buffer.count), currentFile: file.path)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            report(delta: Int64(buffer.count), currentFile: file.path)
        }

        let final = localSize(of: file)
        guard final == file.size else {
            throw InstallError.sizeMismatch(file: file.path, got: final, want: file.size)
        }
    }
}
