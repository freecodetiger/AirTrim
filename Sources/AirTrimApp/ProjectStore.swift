import AirTrimCore
import CryptoKit
import Foundation

/// 项目持久化（App 层）：转写结果 + 修订补丁按源文件指纹索引存 JSON。
/// 源文件只读不动（ADR-0004）；缓存命中 = 秒开，源文件变动（大小/修改时间）= 重转。
struct ProjectDocument: Codable {
    let sourcePath: String
    let fingerprint: String
    let transcript: Transcript
    var patch: TranscriptPatch
    var savedAt: Date
    // M2 起（可选字段，M1 缓存解码为 nil 不炸）
    var edits: EditList?
    var suggestions: [EditSuggestion]?
    var waveformPeaks: [Float]?
}

enum ProjectStore {
    static var dir: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AirTrim/Projects", isDirectory: true)
    }

    /// 与 UserDefaults 解耦：裸二进制（open）和 Xcode 启动使用的 domain 不同，
    /// 写到文件保证任何启动方式都能读到。
    static var lastOpenedFile: URL {
        // 往上一级写到 AirTrim/ 根，和 Projects/ Models/ 同级
        dir.deletingLastPathComponent().appendingPathComponent("last-opened.txt")
    }

    static let lastOpenedKey = "project.lastOpenedPath"

    /// 指纹 = 路径 + 大小 + 修改时间；源文件变动即失效
    static func fingerprint(of url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64,
              let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 else {
            return nil
        }
        let digest = SHA256.hash(data: Data("\(url.path)|\(size)|\(mtime)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func fileURL(fingerprint: String) -> URL {
        dir.appendingPathComponent("\(fingerprint).json")
    }

    static func load(for source: URL) -> ProjectDocument? {
        guard let fp = fingerprint(of: source),
              let data = try? Data(contentsOf: fileURL(fingerprint: fp)),
              let doc = try? JSONDecoder().decode(ProjectDocument.self, from: data),
              doc.fingerprint == fp else { return nil }
        return doc
    }

    static func save(source: URL, transcript: Transcript, snapshot: EditSession.Snapshot,
                     waveformPeaks: [Float]? = nil) {
        guard let fp = fingerprint(of: source) else { return }
        // 峰值只在显式提供时覆盖，否则保留已存的（避免每次修订都丢波形）
        let peaks = waveformPeaks ?? load(for: source)?.waveformPeaks
        let doc = ProjectDocument(sourcePath: source.path, fingerprint: fp,
                                  transcript: transcript, patch: snapshot.patch, savedAt: Date(),
                                  edits: snapshot.edits, suggestions: snapshot.suggestions,
                                  waveformPeaks: peaks)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(doc) {
            try? data.write(to: fileURL(fingerprint: fp), options: .atomic)
        }
        // 文件持久化：与 UserDefaults domain 无关，任何启动方式都能恢复
        try? source.path.write(to: lastOpenedFile, atomically: true, encoding: .utf8)
    }

    static func discard(for source: URL) {
        if let fp = fingerprint(of: source) {
            try? FileManager.default.removeItem(at: fileURL(fingerprint: fp))
        }
    }

    /// 上次打开且缓存仍有效的源文件。
    /// 优先读文件（与 UserDefaults domain 无关），回退 UserDefaults（兼容旧版缓存）。
    static func lastOpenedURL() -> URL? {
        // 优先读文件持久化路径
        let path: String?
        if let filePath = try? String(contentsOf: lastOpenedFile, encoding: .utf8),
           !filePath.isEmpty {
            path = filePath
        } else {
            // 回退：旧版用 UserDefaults 存的路径
            path = UserDefaults.standard.string(forKey: lastOpenedKey)
        }
        guard let path else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path), load(for: url) != nil else { return nil }
        return url
    }
}
