# Spike 观察报告 · WhisperKit large-v3 · 真实素材首测

- 日期：2026-07-26
- 素材：`Fixtures/private/koubo-01.mov`（209.9s · 1080×1920 · 48kHz 单声道，真实口播）
- 引擎：WhisperKit `openai_whisper-large-v3`（本地 `Models/`，`--model-folder` 加载）
- 命令：`airtrim-spike transcribe --audio … --model large-v3 --model-folder Models/openai_whisper-large-v3`

## 结论速览

| 维度 | 结果 | 判定 |
|---|---|---|
| RTF | **0.22**（209.9s 素材 47.2s 转完，M 系列） | ✅ 通过（线 ≤0.5） |
| 识别质量（主观） | 高：专名/口语词全对（深圳/高材生/抛出），tiny 的错误全部修正 | 待人工标注出 CER |
| 词级时间戳 | **退化，不可用**（详下） | ❌ 未达标 |
| 断句/标点 | 中途简体漂移为繁体；标点稀疏 | 需归一化，断句待评 |

## 词级时间戳退化的证据（本 spike 的核心发现）

- 69 个"词"，平均 8.8 字/"词"，最长 24 字——粒度是**整句**而非词。
- 27/69 个"词"时长**精确等于 1.40s**——超长词截断启发式的上限
  `min(0.7, 中位词长) × 2`（SegmentSeeker.swift:503-504），非真实边界。

**根因（读源码定位）**：`splitToWordTokens`（Models.swift:1293）对无空格语言有特判
（`["zh","ja","th","lo","my","yue"]` → 按 token 切分），但语言检测用
`NLLanguageRecognizer`，中文返回 `"zh-Hans"` / `"zh-Hant"`，与白名单字面量
`"zh"` 不相等 → 特判永不命中 → 落入英文式按空格分词 → 中文无空格 → 整句
粘成单"词"（真实时长 5–10s）→ 触发 1.4s 截断 → 时长扎堆 1.40s 且时间轴
只剩 45% 覆盖。日语/泰语恰好命中白名单，唯独中文踩坑。
可修：注入自定义 tokenizer 覆盖 `splitToWordTokens`（`WhisperKit.tokenizer`
是 public var），或给上游提 one-line PR（前缀匹配 `zh`）。
- 全部词只覆盖 95.3s / 209.9s 时间轴；若按词间隙剪停顿，
  会把 **~45% 的真实语音判为"停顿"剪掉**——正是 spike 要拦截的吞字事故。

> tiny 模型同素材同样退化（1.4s 兜底 + 12s 空洞），排除模型规模因素；
> 是 WhisperKit 中文词对齐管线的系统性问题，坐实候选表"中文词边界靠 DTW、偏弱"的顾虑。

## 逐字切词修复后（ZhWordSplitTokenizer 注入，2026-07-26 补测）

| 指标 | 修复前 | 修复后 |
|---|---|---|
| 词数 | 69（整句粒度，平均 8.8 字） | **481**（平均 1.29 字，最长 3 字） |
| 词时长中位 | 1400ms（截断值） | **220ms**（符合中文语速） |
| 1.4s 截断词 | 27 个 | **0 个** |
| 时间轴覆盖 | 45%（吞掉真实语音） | 60%（与 VAD 静音测量吻合） |
| 时间单调性 | — | 无倒流 |

交叉验证：ASR 词间隙 ≥500ms 共 77.5s（53 处），与独立的能量 VAD 静音测量
（59 段，含保留边距剪除 64.3s，还原约 79s）**一致性 ~98%**——两条互不依赖的
证据链指向同一组停顿，词级时间戳已具备可用性。
形式判定（中位 ≤80ms / P95 ≤200ms）仍待人工标注 `evaluate`。

> 修复方式：`ZhWordSplitTokenizer` 包装器注入 `WhisperKit.tokenizer`
> （`--language zh` 时自动启用）；应同步给上游提 PR 修语言检测。

## 耳朵验收改走 VAD

按产品架构（停顿检测本属 VAD 职责），spike 补了能量 VAD（`EnergyVAD`，
帧 RMS + 噪声底自适应 + 动态范围守卫），`earcheck --vad` 不依赖 ASR 时间戳出紧凑成片。
结果见 `koubo-01-tight.mov` 试听记录（待补听感结论）。

## 对候选路线的影响

1. WhisperKit **识别质量、RTF、集成体验都合格**，但词级时间戳当前不可直接用于剪辑。
2. 下一步优先验证：
   - **FunASR/Paraformer**（原生中文词级时间戳）——候选表预期的中文强项；
   - **Whisper 转写 + 强制对齐**（如 CTC forced alignment）修正边界的组合管线；
   - WhisperKit token 级时间戳（绕过其词分组，自行按 token→字聚合）是否可救。
3. 简繁漂移：产品侧需在 Transcript 层做简繁归一化（OpenCC 类）。

## 待办

- [ ] 人工标注 `koubo-01.truth.json`（~100 词边界）后跑 `evaluate` 出量化报告
- [ ] 补两段素材（快语速/带 BGM）凑齐评测集
- [ ] earcheck 试听结论回填本文件
