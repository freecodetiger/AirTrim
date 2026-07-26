# MediaEngine（占位 · 未实现）

**职责**：源媒体只读访问、AVAsset 解码、音频 PCM 抽取（16k mono 给 SpeechPipeline）、`AVMutableComposition` 预览拼装、`AVAssetExportSession` 导出、字幕烧录。

**边界**：整个项目唯一允许操作 AVFoundation 可变对象的模块。不做剪辑决策（那是 EditModel）、不做分析（那是 Analysis）。消费 `EditList` 派生的不可变快照。

首个实现出现在 M0 spike（导出验证路径）与 M1（导入/导出）。见 `docs/architecture/overview.md` §3、§5.4。
