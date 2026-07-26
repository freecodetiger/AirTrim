# M0 Spike · 中文 ASR 词级时间戳验证

> 状态：**评测装置已就绪**（2026-07-26），首个候选 WhisperKit 已接入并冒烟通过；
> 待真实素材 + 人工标注后出量化报告。结论产出 ADR-0006（ASR 选型），量化数据附在 `docs/spikes/results/`。

## 为什么先做这个

剪辑吞字 / 漏气口的根源都是词边界时间戳不准。误差 >100ms 时，"一键清除语气词"会把相邻正常字剪掉半个——产品直接不可用。这是无法靠 UI 弥补的下限。

## 候选方案

| 候选 | 优势 | 顾虑 |
|---|---|---|
| WhisperKit（CoreML，Swift 原生，MIT） | 集成最顺、社区活跃、模型自动下载 | 中文词边界与标点偏弱；词级时间戳靠 DTW 对齐 |
| whisper.cpp（C，MIT） | 成熟、可控、Metal 加速 | 同上；需桥接 |
| FunASR / Paraformer（ONNX 导出，MIT） | 中文识别与标点显著更强，原生词级时间戳 | 需 ONNX Runtime 或自行移植；Swift 生态弱 |
| Apple SpeechAnalyzer / SpeechTranscriber | 系统级、免依赖、快 | 仅 macOS 26+；词级时间戳与中文质量待实测 |
| 组合：Whisper 转写 + 强制对齐（forced alignment）修正边界 | 兼顾识别质量与边界精度 | 管线复杂度 +1，作为备选 |

## 评测集

- 自备真实中文口播素材 ≥ 3 段 × 5 分钟：① 正常语速 ② 快语速/口误多 ③ 带背景音乐。
- 每段人工标注 ~100 个词边界作 ground truth（Audacity/Praat 逐帧看波形+听）。
- 素材放 `Fixtures/private/`（已 gitignore，不入库）。

## 指标与通过线

| 指标 | 通过线 | 说明 |
|---|---|---|
| 词边界误差（中位数） | ≤ 80ms | 对每个标注边界取 \|预测 − 标注\| |
| 词边界误差（P95） | ≤ 200ms | 尾部误差决定翻车频率 |
| RTF（实时率） | ≤ 0.5 | Apple Silicon（M 系列）本地推理；5 分钟素材 ≤ 2.5 分钟转完 |
| 字错率 CER | ≤ 8%（正常语速段） | 识别质量影响文字稿编辑体验 |
| 断句/标点 | 主观可用 | 句编号是 LLM 契约的基础，断句太碎/太长都不行 |

## 执行方式

1. 新增 SPM executable target `AirTrimSpike`（spike 专用，不进入产品依赖图）。
2. 每个候选跑同一评测集，脚本输出误差分布（中位/P95/直方图）+ RTF + CER。
3. **耳朵验收**：用词级时间戳直接生成"删除所有 ≥500ms 停顿"的剪辑成片（AVMutableComposition 导出），听切点是否自然——这同时验证了 MediaEngine 路径的可行性。
4. 报告 + 决策写入 ADR-0006；spike 代码保留在 `Sources/AirTrimSpike/` 供回归复测。

## 评测装置（已实现 · `Sources/AirTrimSpike/` + `Sources/AirTrimSpikeKit/`)

```bash
# 1. 转写（首次自动下载模型；中文评测用 large-v3，快速冒烟用 tiny）
swift run airtrim-spike transcribe --audio 素材.mov --model large-v3 --output pred.json

# 2. 生成标注模板（referenceText 预填，boundaries 人工填 ~100 个词边界）
swift run airtrim-spike gen-truth --transcript pred.json --output truth.json --prefill-every 5

# 3. 评测：边界误差（中位/P95/直方图）+ CER + RTF，判定通过线
swift run airtrim-spike evaluate --transcript pred.json --truth truth.json --report results/whisperkit.md

# 4. 耳朵验收：剪除 ≥500ms 停顿导出成片（最小停顿保留 + 切口音量 ramp，不硬拼）
swift run airtrim-spike earcheck --source 素材.mov --transcript pred.json --output tight.mov
```

纯逻辑（指标计算 / 停顿检测 / keep-range）在 `AirTrimSpikeKit`，有单元测试覆盖；
冒烟结果（`say` 合成 7.3s 中文 + tiny 模型）：文本零错，但中文"词"粒度为整句——
印证候选表对 WhisperKit 中文词边界的顾虑，量化结论待 large-v3 + 真实素材。

### 本机环境备注（不影响其他机器）

开发机 CLT 的 SwiftPM 插件接口与 dylib 版本不一致，任何带 plugin 的
swift-argument-parser（≥1.3，WhisperKit 强制传递依赖）都无法编译。已用
`swift package config set-mirror` 挂本地去插件镜像（`.local-tooling/`，已 gitignore）。
根治方法：安装完整 Xcode 或重装 CLT 后，删除 `.swiftpm/configuration/mirrors.json` 即可。

## 失败预案

- 所有候选词边界都不达标 → 上"转写 + 强制对齐"组合管线，重测。
- 强制对齐也不达标 → 产品策略降级：切点默认外扩 padding 加大 + 必须人工微调，并如实更新 README 预期。
