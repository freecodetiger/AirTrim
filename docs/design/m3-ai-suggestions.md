# M3 设计 · AI 建议闭环（语气词 + 废话识别）

> 状态：实施中（2026-07-28，分支 feat/m3-ai-suggestions）。
> 范围以 roadmap M3 为准：FillerAnalyzer（语气词词表）+ VerbosityAnalyzer（LLM 废话
> 识别）+ 统一建议审阅 UI。域规则来源：`cut-quality` / `edit-model` /
> `speech-pipeline` skills，本文档不复述只引用，冲突时以 skills 为准。

## 1. 数据模型扩展（EditModel）

```swift
enum Kind: String, Codable { case pause, filler, verbosity }

struct EditSuggestion {
    // …M2 既有字段不变…
    let detail: String?        // filler = 所删词文本；verbosity = LLM reason
    let confidence: Float?     // verbosity 置信度（本地分析器不填）
    let category: VerbosityCategory?  // verbosity 四分类
}

enum VerbosityCategory: String, Codable {
    case repetition, falseStart, offTopic, padding
}
```

- **D-M3-1 · 新字段全部 optional 编码**：M2 项目文件直接打开（向后兼容）；
  M3 文件被旧版打开会解码失败（前向不兼容，可接受）。
- **D-M3-2 · verbosity 永不自动接受在模型层设防**：
  `acceptAllProposed(of:)` 硬性拒绝 `kind == .verbosity`（CLAUDE.md 禁止事项），
  防线不只靠 UI。
- 重跑去重沿用 `replaceProposed`（按 kind + originalGap 重叠），三类互不干扰。

## 2. FillerAnalyzer（Analysis · 纯函数）

```
FillerAnalyzer.suggest(transcript:effectiveSentences:silences:params:) -> [EditSuggestion]
```

词表分两档（保守优先，宁可漏不误杀）：

- **高置信单字叹词**：嗯 / 啊 / 呃 / 唔 / 诶 / 哦——独立成词即命中；
  「啊」等在句尾作语气助词时跳过（判定：为句末词且前词间隙 < 80ms，
  说明与前文连读，是助词不是填充词）。
- **低置信多字口头禅**：那个 / 就是 / 就是说 / 然后——有实义用法，仅当
  两侧词间隙均 ≥ 150ms（孤立漂浮）时才出建议；间隙长到 VAD 可检（≥500ms，
  EnergyVAD minDuration）时还需静音佐证（复用 PauseAnalyzer.isMostlySilent；
  更短的间隙 VAD 无数据，只看词间隙）。
  中文管线词≈单字（ZhWordSplitTokenizer），多字词需跨相邻词拼接最长匹配，
  且不跨句边界。

切口定形（cut-quality 规则 4：删词后两侧停顿合并**取较长者**，不留双倍空洞）：

```
leftGap  = 前词 end → 填充词 start
rightGap = 填充词 end → 后词 start
mergedKeep = clamp(max(leftGap, rightGap), wordPadding, 句中/句尾 keep)
cut = [前词 end + wordPadding, 后词 start − (mergedKeep − wordPadding)]
```

- 词边界 padding 50ms（TightenParams.wordPadding 复用）；
- 净时长 < minCutWorth(120ms) 不出建议；
- 句首/句末填充词无一侧词时，切口止于词边界，开场/收尾静音归 PauseAnalyzer；
  filler 的 originalGap = 词区间本身（与 pause 建议的 gap 键天然不重叠，
  避免 replaceProposed 跨类误杀）。

## 3. VerbosityAnalyzer（纯逻辑在 Analysis，网络在 LLMProvider）

管线：

```
AppModel（组合根）
  → LLMProvider.VerbosityClient.analyze(numberedText:topic:) -> [VerbosityFinding]
  → Analysis.VerbosityMapper.suggestions(findings:transcript:sentences:params:) -> [EditSuggestion]
```

- **契约**（cut-quality skill）：输入 = 带句编号全文（`patch.effectiveSentences`
  的位置序号）+ 可选主题提示；输出 JSON：
  `[{sentence_ids:[Int], category, reason, confidence}]`。
- **禁止时间戳/字符 offset 入库**——解析器只收 sentence_ids；句编号 → 词下标
  区间 → CMTime 的反查全部本地完成（ADR-0003）。
- 切口：整句剪除，右端按句尾 keep(250ms) 保留停顿，词边界 padding 50ms。
- 非法句编号（越界）静默丢弃该条，不中断整批。
- JSON 解析失败 → 带 schema 提醒重试 1 次，仍失败抛错（文案可行动）。
- 长文分块：句数 > 200 按句切块，每块携带全文首尾各 300 字摘要做上下文；
  跨块结果按 sentence_ids 合并去重。
- **句表指纹**：请求发起时快照句表（起点数组 hash），返回后失配则丢弃结果
  提示重跑——防止用户请求期间拆合句导致句编号错位。

## 4. 字幕一致性（Subtitles）

`cues(transcript:patch:edits:rules:)` 增加 edits 参数：

- 无 textOverride 的句子：词区间**完全落入** cut 的词从 cue 文本剔除
  （字幕与音画一致；部分重叠的词保留——音频还在响就不能删字）。
- 有 textOverride 的句子：用户手改文本优先，不做词级剔除。
- 整句被剪的 cue 在 retime 时自然丢弃（M2 已有逻辑）。

## 5. 界面（复用 M2 审阅交互，一套 UI 三类建议）

- **建议控制条**（原 TightenBar 扩展）：停顿 / 语气词 / 废话三个入口 +
  各自计数徽标；语气词即时出结果；废话按钮带运行态（菊花 + 取消）。
- **轨道着色**：pause 橙 / filler 蓝 / verbosity 紫；accepted 统一实心红。
- **审阅气泡**：filler 显示所删词；verbosity 显示分类 + 理由 + 置信度。
- **verbosity 审阅面板**：按 category 分组、低置信（< 0.5）折叠、
  按类批量接受；无「一键全收」。
- **主题提示**：废话识别发起前可选填一句话视频主题（显著提升离题判定）。
- 跳听沿用 M2：切点前后各 1.5s。

## 6. 实施顺序（每步三绿可提交）

1. 本设计文档。
2. EditModel 扩展（Kind / 字段 / acceptAll 防线）+ 单测。
3. FillerAnalyzer + 单测。
4. VerbosityClient + VerbosityMapper + 单测。
5. Subtitles 词级剔除 + 单测。
6. App 集成（控制条 / 轨道着色 / 审阅面板）。
7. release-checklist 扩 M3 项 + koubo-01 耳测。

## 7. 风险

| 风险 | 对策 |
|---|---|
| 词表误杀实义词（"然后"作连接词） | 多字词强制孤立判定 + VAD 佐证；宁可漏不误杀 |
| 删词后双倍空洞 | 切口定形即合并停顿取较长者；耳测项入 checklist |
| LLM 返回与句表错位 | 句表指纹校验，失配丢弃提示重跑 |
| LLM 输出不合 schema | 重试 1 次 + 非法条目静默丢弃 + 可行动报错 |
| filler 建议与 pause 建议重叠 | originalGap 重叠去重（replaceProposed 既有机制） |
