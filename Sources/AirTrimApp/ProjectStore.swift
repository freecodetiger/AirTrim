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
    /// M5：已执行语义断句的时间（进入编辑器前自动断句，D-EAS-2/3）；nil = 未断过
    var aiSegmentedAt: Date?
}

/// 项目管理页列表项（M4）：从缓存 JSON 解出的只读元数据快照。
struct ProjectMetadata: Identifiable {
    let fingerprint: String     // 即文件名主干，也是 id
    let sourcePath: String
    let fileName: String        // sourcePath 末段（列表主标题）
    let savedAt: Date           // 最后编辑时间（排序键，倒序）
    let projectSizeBytes: Int64 // 缓存 JSON 大小
    let sourceExists: Bool      // 源文件还在不在（灰态标记）

    var id: String { fingerprint }
    var sourceURL: URL { URL(fileURLWithPath: sourcePath) }
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
                     waveformPeaks: [Float]? = nil, aiSegmentedAt: Date? = nil) {
        guard let fp = fingerprint(of: source) else { return }
        // 峰值/断句标记只在显式提供时覆盖，否则保留已存的（避免每次修订丢派生状态）
        let previous = load(for: source)
        let peaks = waveformPeaks ?? previous?.waveformPeaks
        let segDate = aiSegmentedAt ?? previous?.aiSegmentedAt
        let doc = ProjectDocument(sourcePath: source.path, fingerprint: fp,
                                  transcript: transcript, patch: snapshot.patch, savedAt: Date(),
                                  edits: snapshot.edits, suggestions: snapshot.suggestions,
                                  waveformPeaks: peaks, aiSegmentedAt: segDate)
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

    /// 扫描 Projects/ 目录取全部项目元数据，按最后编辑时间倒序（M4 设计 D-M4-2）。
    /// v1 容忍全量解码（几十项 × ~100KB 毫秒级）；坏文件跳过、目录不存在返回空——绝不崩溃。
    /// directory 参数仅供测试注入，产品代码走默认值。
    static func listAllProjects(in directory: URL = dir) -> [ProjectMetadata] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return [] }
        return entries
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> ProjectMetadata? in
                guard let data = try? Data(contentsOf: url),
                      let doc = try? JSONDecoder().decode(ProjectDocument.self, from: data)
                else { return nil }   // 解码失败跳过不入列表
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? data.count
                return ProjectMetadata(
                    fingerprint: url.deletingPathExtension().lastPathComponent,
                    sourcePath: doc.sourcePath,
                    fileName: (doc.sourcePath as NSString).lastPathComponent,
                    savedAt: doc.savedAt,
                    projectSizeBytes: Int64(size),
                    sourceExists: fm.fileExists(atPath: doc.sourcePath))
            }
            .sorted { $0.savedAt > $1.savedAt }
    }

    /// 删除单个项目缓存 JSON（源文件永远不动）。directory 参数仅供测试注入。
    static func deleteProject(fingerprint: String, in directory: URL = dir) {
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent("\(fingerprint).json"))
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
