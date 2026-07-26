# ADR-0006 · ASR 引擎选型：WhisperKit + VAD 融合

- 状态：已接受（2026-07-26，owner 确认后进入 M1 设计）
- 日期：2026-07-26
- 依据：M0 spike（`docs/spikes/m0-asr-spike.md` · 量化结果 `docs/spikes/results/`）

## 背景

产品下限由中文词级时间戳精度决定（M0 通过线：边界中位 ≤80ms、P95 ≤200ms、
RTF ≤0.5、CER ≤8%）。候选：WhisperKit / whisper.cpp / FunASR(Paraformer) /
Apple SpeechAnalyzer / Whisper+强制对齐组合。

## 决策

1. **v1 ASR 引擎采用 WhisperKit（openai_whisper-large-v3）**。
2. **词级时间戳必须经 VAD 融合后使用**：词首落入 VAD 静音区间的吸附到静音
   终点（真实起音）。这不是临时补丁，而是 `SpeechPipeline` 的正式设计——
   Whisper DTW 词首系统性漂早（实测停顿旁中位 -230ms），单独 ASR 时间戳
   不得直接作为剪切依据。
3. **中文词切分修复**：上游 bug（NLLanguage `zh-Hans` vs 白名单 `zh`，
   [issue #510](https://github.com/argmaxinc/argmax-oss-swift/issues/510) /
   [PR #511](https://github.com/argmaxinc/argmax-oss-swift/pull/511)）。
   合并前用 `ZhWordSplitTokenizer` 注入绕过；合并后升级依赖并删除包装器。
4. **Transcript 层需做简繁归一化**（Whisper 中文输出存在简繁漂移，实测复现）。

## 依据（koubo-01 · 209.9s 真实口播 · Apple Silicon）

| 指标 | 结果 | 通过线 |
|---|---|---|
| RTF | 0.22 | ≤0.5 ✅ |
| 边界中位 / P95（n=32 人工标注） | 0.0ms / 6.7ms | ≤80 / ≤200ms ✅ |
| CER | ~0% | ≤8% ✅ |
| 耳朵验收（VAD 剪停顿成片） | 通过（209.9s→145.6s，59 切口无吞字） | 主观 |

证据强度注记（标注锚定、最近邻掩盖、评测集 n=1）见
`results/koubo-01-whisperkit-large-v3.md` 终评一节。

## 备选处置

- **FunASR/Paraformer**：原生中文时间戳更强，但 Swift 生态弱、需 ONNX 运行时。
  **保留为 B 计划**：若快语速/BGM 素材上融合方案翻车再启动。
- **whisper.cpp**：对本项目相比 WhisperKit 无增量优势，不采用。
- **SpeechAnalyzer**：仅 macOS 26+，与 macOS 14+ 目标冲突，暂不采用。
- **强制对齐组合管线**：复杂度 +1，VAD 融合已覆盖主要偏差，暂不引入。

## 后果

- ✅ 纯 Swift/SPM 集成、MIT 许可（符合 ADR-0001/0002）、模型自动下载。
- ✅ 词级时间戳经融合后达到剪辑精度；管线已被 spike CLI 全链路验证。
- ⚠️ 快语速/带 BGM 未验证（owner 决策收口），M1 期间用真实用户素材跟进；
  翻车路径已预留（FunASR B 计划 + 失败预案降级策略）。
- ⚠️ 依赖上游 PR 合并进度；本地包装器为过渡态，跟踪于 spike 结果文档。
