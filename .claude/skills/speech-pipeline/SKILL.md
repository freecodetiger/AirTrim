---
name: speech-pipeline
description: 改动 VAD、ASR 转写、词级时间戳、Transcript 结构、模型下载管理时使用。覆盖时间戳权威规则与静音/词间隙的判定分工。
---

# SpeechPipeline 域知识

## 不变量

1. **时间戳的唯一来源**：全项目所有 `CMTime` 权威值都产自本模块（ASR 词边界 + VAD 静音区间）。任何其他模块换算/修正时间戳都必须回到这里的数据，不许自造。
2. `Transcript` 是**不可变快照**：改错字/调断句产生新 `Transcript`（词时间戳不变，只动文本与句划分）；重转写整体替换。
3. 模型不入库：运行时下载到 `~/Library/Application Support/AirCut/Models/`，带校验与断点续传；仓库内实验模型放 `Models/`（已 gitignore）。

## 静音 vs 词间隙的分工（容易混）

- **真静音**：VAD 能量判定（`SilenceInterval` 带 `peakEnergy`，可区分底噪/低语）。
- **词间隙**：相邻 `TranscriptWord` 时间差。ASR 在静音段可能漂移，**不能单独作为静音依据**。
- `PauseAnalyzer` 消费两者交叉验证：VAD 说静 + 词间隙 ≥ 阈值 → 高置信停顿建议。

## 中文特有的坑

- Whisper 系词边界与标点偏弱 → M0 spike 用真实素材量化（`docs/spikes/m0-asr-spike.md`），通过线：中位 ≤80ms / P95 ≤200ms。
- 断句质量直接决定 LLM 契约的句编号可用性；太碎/太长都要在本模块后处理，不甩给 Analysis。
- 备选管线：转写 + 强制对齐（forced alignment）修正词边界。

## 性能

- 转写走后台任务 + 进度上报；1h 素材 RTF ≤0.5 是产品线。
- 音频抽取由 MediaEngine 提供 PCM（16k mono），本模块不碰 AVAsset。
