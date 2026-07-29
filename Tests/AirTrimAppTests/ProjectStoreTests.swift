import AirTrimCore
import CoreMedia
import Foundation
import Testing
@testable import AirTrimApp

/// ProjectStore 项目列表扫描/删除（M4 D-M4-2）。
/// 全部走临时目录注入，不触碰真实 ~/Library/Application Support。
@Suite("ProjectStore 项目列表")
struct ProjectStoreListTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("projectstore-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var tinyTranscript: Transcript {
        let word = TranscriptWord(text: "测",
                                  start: CMTime(value: 0, timescale: 600),
                                  end: CMTime(value: 300, timescale: 600))
        return Transcript(words: [word],
                          sentences: [TranscriptSentence(id: 0, words: 0..<1)],
                          sourceDuration: CMTime(value: 600, timescale: 600))
    }

    /// 写一个最小可解码的项目缓存 JSON，返回其字节数
    @discardableResult
    private func writeProject(fingerprint: String, sourcePath: String,
                              savedAt: Date, in dir: URL) throws -> Int {
        let doc = ProjectDocument(sourcePath: sourcePath, fingerprint: fingerprint,
                                  transcript: tinyTranscript, patch: TranscriptPatch(),
                                  savedAt: savedAt, edits: nil, suggestions: nil,
                                  waveformPeaks: nil)
        let data = try JSONEncoder().encode(doc)
        try data.write(to: dir.appendingPathComponent("\(fingerprint).json"))
        return data.count
    }

    @Test func sortsBySavedAtDescendingAndDecodesMetadata() throws {
        let dir = try makeTempDir()
        // 造一个真实存在的“源文件”
        let source = dir.appendingPathComponent("koubo.mov")
        try Data("v".utf8).write(to: source)
        let older = Date(timeIntervalSince1970: 1000)
        let newer = Date(timeIntervalSince1970: 2000)
        let bytes = try writeProject(fingerprint: "aaa", sourcePath: source.path,
                                     savedAt: older, in: dir)
        try writeProject(fingerprint: "bbb", sourcePath: "/nonexistent/gone.mov",
                         savedAt: newer, in: dir)

        let list = ProjectStore.listAllProjects(in: dir)

        #expect(list.map(\.fingerprint) == ["bbb", "aaa"], "按 savedAt 倒序")
        let a = try #require(list.first { $0.fingerprint == "aaa" })
        #expect(a.id == "aaa")
        #expect(a.sourcePath == source.path)
        #expect(a.fileName == "koubo.mov")
        #expect(a.savedAt == older)
        #expect(a.projectSizeBytes == Int64(bytes))
        #expect(a.sourceExists)
        let b = try #require(list.first { $0.fingerprint == "bbb" })
        #expect(!b.sourceExists, "源文件不存在 → 灰态标记")
        #expect(b.fileName == "gone.mov")
    }

    @Test func skipsCorruptAndNonJSONFilesWithoutCrashing() throws {
        let dir = try makeTempDir()
        try writeProject(fingerprint: "good", sourcePath: "/tmp/x.mov",
                         savedAt: Date(), in: dir)
        // 坏 JSON：解码失败跳过不入列表
        try Data("{not json".utf8).write(to: dir.appendingPathComponent("broken.json"))
        // 非 .json 文件（如 last-opened.txt 混入）：直接忽略
        try Data("path".utf8).write(to: dir.appendingPathComponent("last-opened.txt"))

        let list = ProjectStore.listAllProjects(in: dir)
        #expect(list.map(\.fingerprint) == ["good"])
    }

    @Test func missingDirectoryReturnsEmpty() {
        let ghost = FileManager.default.temporaryDirectory
            .appendingPathComponent("projectstore-ghost-\(UUID().uuidString)")
        #expect(ProjectStore.listAllProjects(in: ghost).isEmpty)
    }

    @Test func deleteProjectRemovesOnlyTargetCache() throws {
        let dir = try makeTempDir()
        try writeProject(fingerprint: "keep", sourcePath: "/tmp/a.mov",
                         savedAt: Date(timeIntervalSince1970: 1), in: dir)
        try writeProject(fingerprint: "drop", sourcePath: "/tmp/b.mov",
                         savedAt: Date(timeIntervalSince1970: 2), in: dir)

        ProjectStore.deleteProject(fingerprint: "drop", in: dir)

        #expect(ProjectStore.listAllProjects(in: dir).map(\.fingerprint) == ["keep"])
        // 删不存在的指纹不崩溃
        ProjectStore.deleteProject(fingerprint: "ghost", in: dir)
    }
}
