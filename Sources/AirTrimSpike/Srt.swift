import AirTrimCore
import ArgumentParser
import Foundation

/// 从 App 项目缓存 JSON 生成 SRT（验收/回归用，与 App 内导出走同一纯函数）。
struct Srt: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "从项目缓存 JSON 导出 SRT 字幕文件"
    )

    @Option(help: "项目缓存 JSON（~/Library/Application Support/AirTrim/Projects/<指纹>.json）")
    var project: String

    @Option(help: "输出 SRT 路径")
    var output: String

    func run() async throws {
        let payload = try JSONDecoder().decode(
            Burn.ProjectPayload.self, from: Data(contentsOf: URL(fileURLWithPath: project)))
        let cues = Subtitles.cues(transcript: payload.transcript, patch: payload.patch)
        try Data(Subtitles.srt(cues).utf8).write(to: URL(fileURLWithPath: output))
        print("\(cues.count) 条字幕 → \(output)")
    }
}
