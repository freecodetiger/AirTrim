import ArgumentParser

/// M0 spike CLI（docs/spikes/m0-asr-spike.md）。
/// 评测流程：transcribe → gen-truth（人工标注）→ evaluate；earcheck 出成片耳朵验收。
@main
struct SpikeCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "airtrim-spike",
        abstract: "AirTrim M0 · 中文 ASR 词级时间戳评测装置",
        subcommands: [Transcribe.self, GenTruth.self, Evaluate.self, EarCheck.self]
    )
}
