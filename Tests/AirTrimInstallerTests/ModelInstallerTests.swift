import Foundation
import Testing
@testable import AirTrimInstaller

@Suite("Manifest")
struct ManifestTests {
    @Test func largeV3TotalsMatchKnownSizes() {
        let m = ModelManifest.largeV3
        #expect(m.files.count == 27)  // 19 模型文件 + 8 tokenizer 文件
        // 3.09GB 模型 + ~4.4MB tokenizer
        #expect(m.totalBytes > 3_090_000_000 && m.totalBytes < 3_100_000_000)
        #expect(m.sources.count >= 2, "至少 HF + 镜像双源")
        #expect(m.files.filter { $0.path.hasPrefix("tokenizer/") }.count == 8)
    }
}

@Suite("安装计划")
struct PlanTests {
    func makeTemp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("installer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var tinyManifest: ModelManifest {
        ModelManifest(
            name: "tiny-model",
            files: [
                .init(path: "a.bin", remotePath: "m/a.bin", size: 4),
                .init(path: "sub/b.bin", remotePath: "m/sub/b.bin", size: 8),
            ],
            sources: [(URL(string: "https://example.invalid")!, URL(string: "https://example.invalid")!)]
        )
    }

    @Test func freshDirectoryPlansEverything() async throws {
        let dest = try makeTemp()
        let installer = ModelInstaller(manifest: tinyManifest, destination: dest)
        let (skip, todo) = await installer.plan()
        #expect(skip == 0)
        #expect(todo.count == 2)
    }

    @Test func matchingFileIsSkippedMismatchedIsRedone() async throws {
        let dest = try makeTemp()
        let modelDir = dest.appendingPathComponent("tiny-model")
        try FileManager.default.createDirectory(
            at: modelDir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        // a.bin 尺寸正确 → 跳过；b.bin 尺寸错误 → 重下
        try Data([1, 2, 3, 4]).write(to: modelDir.appendingPathComponent("a.bin"))
        try Data([9, 9]).write(to: modelDir.appendingPathComponent("sub/b.bin"))

        let installer = ModelInstaller(manifest: tinyManifest, destination: dest)
        let (skip, todo) = await installer.plan()
        #expect(skip == 4)
        #expect(todo.map(\.path) == ["sub/b.bin"])
    }
}

/// 真网络冒烟（手动执行）：AIRTRIM_NET_TEST=1 swift test --filter RealInstall
/// 对已存在的 large-v3 目录执行安装 → 19 个模型文件应全部跳过，
/// 只补下 8 个 tokenizer 小文件，完成后管线彻底离线。
@Suite("RealInstall", .enabled(if: ProcessInfo.processInfo.environment["AIRTRIM_NET_TEST"] == "1"))
struct RealInstallTests {
    @Test func tokenizerBackfillOnExistingModel() async throws {
        let dest = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AirTrim/Models")
        let installer = ModelInstaller(manifest: .largeV3, destination: dest)
        let modelDir = try await installer.install { p in
            if p.filesDone % 5 == 0 || p.fraction > 0.999 {
                print("progress \(Int(p.fraction * 100))% \(p.currentFile)")
            }
        }
        let tok = modelDir.appendingPathComponent("tokenizer/tokenizer.json")
        #expect(FileManager.default.fileExists(atPath: tok.path))
    }
}
