import AirTrimSpikeKit
import ArgumentParser
import Foundation

struct VADDump: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vad-dump",
        abstract: "从源媒体输出能量 VAD 静音区间 JSON（诊断/对齐校验用）"
    )

    @Option(help: "源媒体文件")
    var source: String

    @Option(name: .customLong("min-gap"), help: "最小静音时长（秒）")
    var minGap: Double = 0.5

    @Option(help: "输出 JSON 路径")
    var output: String

    func run() async throws {
        let samples = try await AudioLoader.loadMonoPCM(url: URL(fileURLWithPath: source))
        let silences = EnergyVAD.silences(samples: samples, sampleRate: AudioLoader.sampleRate,
                                          minDuration: minGap)
        let intervals = silences.map { [$0.lowerBound, $0.upperBound] }
        try SpikeJSON.encode(intervals).write(to: URL(fileURLWithPath: output))
        print("\(intervals.count) 段静音已写入 \(output)")
    }
}
