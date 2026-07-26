# M2 设计 · 一键紧凑（核心卖点）

> 状态：已实施（2026-07-27，分支 feat/m2-tighten；听感耳测待 owner 验收）。
> 范围以 roadmap M2 为准：VAD 停顿分析 + 可调紧凑度 + 时间线（切割区间）
> + 合成实时预览 + 听感参数体系。语气词/废话分析器是 M3，不做。
> 域规则来源：`cut-quality` / `edit-model` / `speech-pipeline` skills，
> 本文档不复述只引用，冲突时以 skills 为准。

## 1. 数据模型（EditModel，唯一 owner）

```swift
/// 剪辑状态唯一真相源。区间全部落【源时间轴】（skill 不变量 3）。
struct EditList: Sendable, Equatable, Codable {
    private(set) var cuts: [CMTimeRange]     // 有序、互不重叠（入口保证，非消费方兜底）
    mutating func add(_ range: CMTimeRange)  // 唯一写入口：插入 + 归并重叠
    mutating func remove(overlapping: CMTimeRange)
    func keepSegments(sourceDuration: CMTime) -> [CMTimeRange]   // 派生：预览/导出消费
    func outputTime(forSource t: CMTime) -> CMTime   // 源轴→成片轴（cuts 前缀和，纯函数）
    func sourceTime(forOutput t: CMTime) -> CMTime   // 成片轴→源轴（预览 seek 用）
    var removedDuration: CMTime
}

/// 建议与剪辑分离存储；accept 是区间进 EditList 的唯一路径
struct EditSuggestion: Sendable, Equatable, Codable, Identifiable {
    enum Kind: String, Codable { case pause }        // M3 加 filler/verbosity
    enum State: String, Codable { case proposed, accepted, rejected }
    let id: UUID
    let kind: Kind
    let cut: CMTimeRange          // 已含词边界 padding 与最小停顿保留的最终切口（源轴）
    let originalGap: CMTimeRange  // 完整静音区间（UI 展示/跳听定位用）
    var state: State
}

/// 会话状态整体快照 undo（skill 不变量 4）：patch + editList + suggestions 一体入栈，
/// 取代 M1 的 PatchSession（其 API 兼容迁移，undo 语义升级为全量）
struct EditSession: Sendable {
    struct Snapshot: Sendable, Equatable, Codable {
        var patch: TranscriptPatch
        var edits: EditList
        var suggestions: [EditSuggestion]
    }
    private(set) var current: Snapshot
    private(set) var history: [Snapshot]
    mutating func apply(_ mutate: (inout Snapshot) -> Void)
    mutating func undo() -> Bool
}
```

接受/拒绝/重跑规则、时间换算的归属，照抄 `edit-model` skill；此处只落两个补充决策：

- **D-M2-1 · 建议的切口在产出时就定形**：PauseAnalyzer 直接输出带 padding、
  留停顿的最终 `cut`，accept 时原样并入 EditList，不在接受时二次计算——
  紧凑度变化 = 重跑分析器生成新 proposed 集（rejected 按 originalGap 重叠去重），
  已 accepted 的不动（用户已确认的决定不被参数滑杆偷改）。
- **D-M2-2 · 成片轴换算放 EditList 本体**（纯函数），SRT 重定时、预览 seek、
  轨道绘制共用，杜绝三处各写一份前缀和。

## 2. 停顿分析（Analysis · 纯函数）

```
PauseAnalyzer.suggest(transcript:silences:params:) -> [EditSuggestion]
```

- 交叉验证（`speech-pipeline` skill）：VAD 真静音 ∩ 相邻词间隙 ≥ 阈值才出建议；
  ASR 词间隙单独不算数。
- 参数体系（`cut-quality` skill 数值，`TightenParams` 值类型）：
  - `minPauseKept`：句中 150ms / 句尾 250ms；紧凑度 0…1 线性缩放到下限 80ms；
  - `wordPadding`：50ms（40–60 区间取中）；
  - `minCutWorth`：切口净时长 < 120ms 的不出建议（剪了听不出，白增审阅负担）；
  - 句中/句尾判定：静音右侧第一个词是否为句首（用 patch 生效后的句划分）。
- peakEnergy 高于阈值的"静音"（低语/底噪）降置信 → M2 先直接跳过，不出建议
  （宁可少剪）。

## 3. 预览合成（MediaEngine）

```
PreviewComposer.playerItem(source:edits:) -> AVPlayerItem
PreviewComposer.composition(source:edits:) -> (AVMutableComposition, AVAudioMix)
```

- keep 段依次插入 composition（视频跳切，口播成熟语言，不做画面过渡）；
- 每个拼接点音频 **equal-power crossfade 30ms**：AVMutableAudioMix 对相邻段
  各设 30ms 音量 ramp（前段淡出后段淡入）。v1 用双轨交替布局实现重叠淡化；
- 预览 = `AVPlayer(playerItem:)` 直接换 item，**播放头显示值经
  `sourceTime(forOutput:)` 映射回源轴**驱动卡片/轨道高亮——播放器只认成片轴，
  唯一真相仍是 EditList；
- 导出（SRT/烧录/纯导出）共用同一 composition 路径；字幕 cue 时间经
  `outputTime(forSource:)` 重定时，落入被剪区间的 cue 裁剪或丢弃。

## 4. 持久化（v2，向后兼容）

- `Transcript.silences: [SilenceInterval]`：新转写直接带上（转写时顺手产出）；
  旧缓存解码为缺省空 → App 打开时用重抽 PCM 后台补算一次并回写。
- `ProjectDocument` 增：`edits: EditList?`、`suggestions: [EditSuggestion]?`、
  `waveformPeaks: [Float]?`（约 2000 bin，轨道波形背景；缓存命中免抽 PCM）。
  全部可选字段，M1 缓存打开不炸。
- undo 栈仍不持久化（会话内语义，D7 决策沿用）。

## 5. 界面（D8 · 交付级编辑界面，含 owner 已认可的 UI 方案）

布局：左卡片列表 + 右预览，底部通栏**轨道**。

- **字幕卡片**：序号/起止时间码/时长/可编辑文本/徽标（改字过、超长警告
  >2行×16字）/试听按钮；单击选中+定位，双击编辑；右键拆合句。
- **轨道**（一个组件，M1 字幕块与 M2 切割区间同居）：
  - 时间标尺（自适应刻度）+ 波形背景（峰值持久化）+ 字幕块行 + 播放头（30Hz）；
  - **停顿建议着色**：proposed = 半透明橙、accepted = 实心红（被剪掉）、
    rejected 不显示；点击建议块 = 选中并弹出接受/拒绝/跳听；
  - 点击/拖拽标尺 scrub；缩放滑杆 + ⌘+/-；播放时跟随滚动。
- **紧凑度控制条**（轨道上方一行）：滑杆（松→紧）+ "一键紧凑"（全收 proposed，
  走 accept 路径可撤销）+ 已省时长徽标（"已剪 37s / 3:30"）+ 原片/成片预览切换。
- **跳听**：切点前后各 1.5s 的拼接试听（cut-quality skill 审阅原则）——
  用临时双段 composition 播放。
- 不做：拖拽块边缘改时间（时间权威在词级数据；M3 再设计词边界吸附拖拽）、
  字幕样式编辑、多选批量。

## 6. 实施顺序（每步三绿可运行）

1. 本文档 + ownership/CLAUDE.md 对表确认（无新 owner，全部落既有模块）。
2. UI 基建：卡片 + 轨道（标尺/波形/字幕块/播放头/缩放），M1 功能不回退。
3. EditModel：EditList/EditSuggestion/EditSession + 换算纯函数 + 全量单测。
4. Analysis：PauseAnalyzer + TightenParams + 单测（含紧凑度缩放曲线）。
5. SpeechPipeline/持久化 v2：silences + peaks + 兼容迁移。
6. MediaEngine：PreviewComposer + crossfade + 导出重定时。
7. App 集成：紧凑度条 + 建议审阅 + 成片预览 + 导出适配。
8. 验证：单测 + koubo-01 紧凑样片耳测 + release-checklist 扩 M2 项。

## 7. 风险

| 风险 | 对策 |
|---|---|
| crossfade 双轨布局实现复杂 | 退路：先单轨硬接 + 30ms ramp 淡出淡入（无重叠），耳测不过再上双轨 |
| 旧缓存无 silences，补算窗口用户可感 | 后台补算 + 轨道先出（建议延迟出现），不阻塞编辑 |
| 建议切口与字幕 cue 交叠（剪掉半句字幕） | cue 重定时裁剪逻辑单测覆盖；被整剪的 cue 丢弃 |
| 预览 item 频繁重建卡顿 | accept/undo 去抖 300ms 重建；原片模式零开销 |
