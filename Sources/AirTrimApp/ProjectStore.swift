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
}

enum ProjectStore {
    static var dir: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AirTrim/Projects", isDirectory: true)
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

    static func save(source: URL, transcript: Transcript, patch: TranscriptPatch) {
        guard let fp = fingerprint(of: source) else { return }
        let doc = ProjectDocument(sourcePath: source.path, fingerprint: fp,
                                  transcript: transcript, patch: patch, savedAt: Date())
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(doc) {
            try? data.write(to: fileURL(fingerprint: fp), options: .atomic)
        }
        UserDefaults.standard.set(source.path, forKey: lastOpenedKey)
    }

    static func discard(for source: URL) {
        if let fp = fingerprint(of: source) {
            try? FileManager.default.removeItem(at: fileURL(fingerprint: fp))
        }
    }

    /// 上次打开且缓存仍有效的源文件
    static func lastOpenedURL() -> URL? {
        guard let path = UserDefaults.standard.string(forKey: lastOpenedKey) else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path), load(for: url) != nil else { return nil }
        return url
    }
}
