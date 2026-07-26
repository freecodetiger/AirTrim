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

### Bug 深挖验证（2026-07-26，判定：真 bug，未被上游报告）

1. **实证**：`NLLanguageRecognizer` 对白名单 6 语言的输出——ja/th/lo/my 均返回
   与白名单一致的码（✅ 命中），中文返回 `zh-Hans`/`zh-Hant`（❌ 双双漏判）；
   `yue` 是死代码（NLLanguage 无粤语，归入 zh-Hant，同样漏）。
2. **设计对照**：OpenAI 原版 `split_to_word_tokens` 用**解码器语言码**
   （`self.language`，字面 `"zh"`，tokenizer.py:277-282）；WhisperKit 移植时
   白名单照抄、语言来源改为对文本重跑 NL 检测——BCP-47 对 Whisper 码制，
   码制错配即回归点。main 分支（2026-07）仍存在。
3. **无副作用证明**：`findAlignment` 先做 DTW 得到**逐 token** 时间，再按
   `splitToWordTokens` 分组合并——底层对齐一直是对的，是错误分组 + 1.4s
   截断启发式把好数据毁掉；修复只改合并粒度，纯收益。
4. **上游检索**：zh-Hans / splitToWordTokens / NLLanguageRecognizer /
   chinese word timestamps 全部 0 命中——未被报告。
5. **影响面**：所有对中文（简/繁）及粤语开 `wordTimestamps` 的 WhisperKit 用户。

已提交上游：[issue #510](https://github.com/argmaxinc/argmax-oss-swift/issues/510) · [PR #511](https://github.com/argmaxinc/argmax-oss-swift/pull/511)（2026-07-26，fix + 中文回归测试）。合并后升级依赖即可移除 ZhWordSplitTokenizer 包装器。
上游修复建议：最小改动 = 白名单匹配改前缀/Locale 映射（`zh-Hans`→`zh`）；
设计正确版 = 仿 OpenAI 把解码语言传入 tokenizer（需动 `WhisperTokenizer` 协议）。

## 词起点系统性偏早（2026-07-26，用户标注时发现）

用户在标注页观察到"每个边界都偏约半秒"。诊断（`vad-dump` 输出 mov 的 VAD
静音区间做三方对齐）：

- 标注音频（avconvert m4a）vs 原始 mov：偏移中位 **+0ms** —— 工具链无罪；
- ASR 词尾 vs VAD 静音起点：中位 **-70ms** —— 词尾基本准；
- **ASR 词起点 vs VAD 静音终点（起音点）：中位 -230ms，首词 -680ms** ——
  词起点系统性偏早（Whisper DTW 词首注意力漂入前导静音的已知行为）。

> 教训：此前"ASR 间隙与 VAD 吻合 98%"只对比了停顿**总量**，恒定偏移是其盲区；
> 位置级对齐才能暴露系统性偏差。

**校正 = 产品架构中本就规划的 VAD+ASR 融合**：词起点落在 VAD 静音内的，
吸附到静音终点（真实起音）。481 词中 46 个被修正（正是停顿旁的词），
写入 `koubo-01.large-v3-snapped.json`；标注页预填与后续 `evaluate` 均
以 snapped 版为准。句中词边界的精度由人工标注判定。

## 耳朵验收改走 VAD

按产品架构（停顿检测本属 VAD 职责），spike 补了能量 VAD（`EnergyVAD`，
帧 RMS + 噪声底自适应 + 动态范围守卫），`earcheck --vad` 不依赖 ASR 时间戳出紧凑成片。

**试听结论（2026-07-26，用户本人验收）：通过** ✅ —— `koubo-01-tight.mov`
（209.9s → 145.6s，剪除 59 处 ≥500ms 停顿，切口保留 150ms 最小停顿 + 50ms
padding + 30ms 音量 ramp）听感自然、无吞字、无跳变。同时验证了
AVMutableComposition → AVAssetExportSession 的 MediaEngine 导出路径可行
（spike 执行方式第 3 项）。cut-quality 默认参数在正常语速素材上成立；
快语速/带 BGM 素材待补测。

## 对候选路线的影响

1. WhisperKit **识别质量、RTF、集成体验都合格**，但词级时间戳当前不可直接用于剪辑。
2. 下一步优先验证：
   - **FunASR/Paraformer**（原生中文词级时间戳）——候选表预期的中文强项；
   - **Whisper 转写 + 强制对齐**（如 CTC forced alignment）修正边界的组合管线；
   - WhisperKit token 级时间戳（绕过其词分组，自行按 token→字聚合）是否可救。
3. 简繁漂移：产品侧需在 Transcript 层做简繁归一化（OpenCC 类）。

## 终评（2026-07-26 · 人工标注 n=32，素材前 64s）

| 指标 | snapped 版 | 原始 zhfix 版 | 通过线 |
|---|---|---|---|
| 边界误差中位 | **0.0ms** | 0.0ms | ≤80ms ✅ |
| 边界误差 P95 | **6.7ms** | 25.3ms | ≤200ms ✅ |
| 最大误差 | 42ms | 60ms | — |
| CER | **0.0%** | — | ≤8% ✅ |
| RTF | 0.22 | 同 | ≤0.5 ✅ |

**判定：通过**（详表 `koubo-01-eval-snapped.md` / `koubo-01-eval-raw.md`）。

### 方法学注记（如实记录，评估证据强度用）

1. **标注锚定**：标注在预填（snapped 预测）基础上进行，32 个边界仅 2 个被手工
   调整（-42ms / +15ms）。因此指标语义是"人工复核未发现可感知误差"（标注者
   分辨率约 10-15ms），而非完全独立的 ground truth。标注者此前曾一眼识破
   ~500ms 的系统性偏移并推动修正，说明其对大误差敏感，30 个"确认未动"有效。
2. **最近邻匹配会掩盖词首偏早**：全边界集合（词首+词尾）里相邻词尾常落在真实
   起音附近，因此原始版也能过线。词首系统性偏早（停顿旁中位 -230ms）是真实
   存在的，由 VAD 融合修正——剪辑切点恰好只依赖停顿旁边界，风险已覆盖。
3. **评测集缩减**：owner 决策以 1 段正常语速素材收口（原计划 ≥3 段）；
   快语速/带 BGM 场景未验证，列为 M1 期间的跟进项。

## 待办

- [x] 人工标注后跑 `evaluate` 出量化报告（2026-07-26 通过，见终评）
- [x] earcheck 试听结论回填本文件（2026-07-26 通过，见上）
- [ ] 快语速/带 BGM 素材验证（降级为 M1 跟进项，owner 决策）
