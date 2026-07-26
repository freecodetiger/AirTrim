# SpeechPipeline（占位 · 未实现）

**职责**：VAD 静音检测 → `[SilenceInterval]`；ASR 转写 → `Transcript`（词级时间戳）。**全项目时间戳权威值的唯一来源**。ASR 模型运行时下载管理。

**边界**：不碰 AVAsset（PCM 由 MediaEngine 提供）；不产生建议（那是 Analysis）。

ASR 选型由 M0 spike 决定（`docs/spikes/m0-asr-spike.md` → ADR-0006）。域细节见 `.claude/skills/speech-pipeline/`。
