# M1 设计 · 字幕工具（首个可发布版本）

> 状态：已接受（2026-07-26 owner 确认，UI 先行）。补充决策：模型分档
> （默认小模型 + 高精度可选，见候选表 large-v3-v20240930_626MB 等）列为
> **后续产品能力**，M1 先用已验证的 large-v3；D3 的 TranscriptPatch v1 以
> **句为粒度**（字幕条不需要词级文本覆盖，词级留给 M2）。范围以 roadmap M1 为准：
> 导入视频 → 本地转写 → 文字稿编辑（改错字、调断句）→ SRT 导出 + 字幕烧录导出。
> 不做剪辑（EditList 的 cut 语义、时间线、紧凑度都属 M2）。

## 1. 总体形态

单窗口三步流：**导入页 →（转写进度）→ 文稿编辑页 → 导出面板**。
逐句列表即编辑器：点句 inline 改字、回车拆句、删除行首合并句；右上导出
（SRT 文件 / 烧录 MP4）。无时间线、无波形（M2 引入）。

```
视频文件 ──MediaEngine.抽音频──▶ PCM
                                 │ SpeechPipeline
                                 │  ├ WhisperKitTranscriber（词级 CMTime）
                                 │  ├ EnergyVAD（静音区间）
                                 │  ├ 融合：词首吸附 VAD 起音（ADR-0006）
                                 │  ├ 简繁归一化 · 断句
                                 ▼
                             Transcript（不可变快照）
                                 │        ＋ TranscriptPatch（EditModel）
                                 ▼
                         Subtitles.cues() → [SubtitleCue]（纯函数）
                          ├──▶ SRT 序列化（纯文本）→ App 保存
                          └──▶ MediaEngine.烧录导出（CATextLayer 合成）
```

## 2. 关键设计决策

### D1 · 模型下载归 App 层，Core 保持离线（维持"网络仅 LLMProvider"铁律）

矛盾：SpeechPipeline 需要模型文件（~3GB），但 Core 的联网白名单只有
LLMProvider。**决策：SpeechPipeline 永不联网**——只接受本地模型目录
（spike `--model-folder` 已验证此路径，含禁用 WhisperKit 内置 HubApi 下载）。
下载由 App 层组合根的 `ModelInstaller` 负责：

- 下载到 `~/Library/Application Support/AirTrim/Models/`（ADR-0001）；
- 自实现断点续传（ranged GET + 逐文件字节校验；spike 教训：HubApi 大文件
  超时不可靠）；文件清单与尺寸预置在 App 内；
- **tokenizer 资源一并预取**（spike 里 tokenizer 仍走 HF 小文件下载，M1 必须
  彻底离线化）；
- 架构守卫脚本不变；`AirTrimApp` 本就不受 URLSession 限制。

### D2 · 新增纯值层模块 `Subtitles/`（需补 ownership-map + CLAUDE.md 职责表）

字幕条生成 = 领域逻辑（断行、时长约束、间隙链接），纯函数可测，不属于
MediaEngine（它只管烧录像素）也不属于 SpeechPipeline（它只管转写）。提案：

| 关注点 | 唯一 owner | 位置 |
|---|---|---|
| 字幕条生成（Transcript+Patch → [SubtitleCue] → SRT 文本） | `Subtitles` | `Sources/AirTrimCore/Subtitles/` |

规则 v1：每条 ≤2 行 × ≤16 字/行（中文），最短显示 1.0s，相邻条间隙 ≤120ms
时无缝相接；断条优先句边界，超长句按标点/词边界折分。参数进设置，默认值
待真实素材调校。

### D3 · 改错字/调断句 = 编辑状态，归 EditModel（`TranscriptPatch`）

`Transcript` 保持不可变（重转写 = 新快照）。所有人工修订放值类型
`TranscriptPatch`：

```swift
struct TranscriptPatch: Sendable {          // EditModel 唯一持有
    var textOverrides: [Int: String]        // 词下标 → 修正文本（时间戳不动）
    var sentenceBreaks: SentenceBreakEdit   // 拆句/合句（只动句归属，不动词）
}
```

- undo 复用 `EditSession` 快照栈模式（M2 的 EditList 与它同栈演进）；
- 改字**永不改时间戳**（时间权威仍是 SpeechPipeline 的 CMTime）；
- 字幕、导出全部从 `(Transcript, TranscriptPatch)` 派生，无第二份状态。

### D3a · 结构编辑与预览（2026-07-26 UI 反馈后补充）

- 句身份 = **起点词下标**（拆/合句时未波及句的键天然稳定）；结构 =
  `sentenceStarts` 断点表（nil = 原始断句）。
- 拆/合句时**被波及句子的文本覆盖作废**（回原始转写，undo 可回退）——
  结构整理通常先于文本润色，冲突场景按此策略化解。
- 交互：右键句子 → "拆分此句…"（弹词块选择器，点词即从词前断开）/
  "与上一句合并"。
- 预览面板（编辑闭环必需）：左句列表右 AVPlayer；点时间码跳句首、
  行首按钮试听整句（句尾自动停）、播放时当前句高亮跟随 + 自动滚动；
  播放器下方实时显示当前字幕条 = 烧录前软预览。播放头是派生显示值，
  不构成第二份时间状态。
- ModelInstaller 提前为下一工作项（onboarding 阻断）；分档默认值须先过
  评测（owner 决定测试时机）。

### D7 · 项目持久化（2026-07-27，owner 要求）

- 转写结果 + 修订补丁存 `App Support/AirTrim/Projects/<指纹>.json`；
  指纹 = 源文件路径+大小+修改时间的 SHA256，源变动即失效重转。
- **CMTime 以 {value, timescale} 有理数编码**——时间权威规则延伸到磁盘，
  绝不经过 Double。
- 每次修订原子写盘（~100KB），关闭/崩溃零丢失；启动自动恢复上次会话；
  文件菜单提供 打开(⌘O)/关闭/重新转写（忽略缓存）。
- undo 栈不持久化（会话内语义）；AI 断句、手动拆合句、改字全部随 patch 落盘。

### D4 · 烧录：CoreAnimation 合成 + CoreText 预渲染位图（2026-07-27 实现修订）

`AVMutableComposition`（M1 无剪切，整段直通）+ `AVVideoCompositionCoreAnimationTool`
+ `AVAssetExportSession` 导出。样式 v1 固定一套（白字黑边、底部居中、安全
边距、竖拍横拍字号自适应），模板化留给 roadmap 的"字幕样式"项。

**实现修订**：原方案的 `CATextLayer` 在离屏导出渲染器里不触发 display，
出片无字（真机二分定位：纯色层渲染正常、文字层空白）。改为每条 cue 用
CoreText 预渲染成 `CGImage` 挂在普通 `CALayer.contents` 上，显隐仍由
opacity 动画在视频时间轴上驱动。竖拍 `preferredTransform` 归一化到渲染
坐标。回归入口：`airtrim-spike burn --dump-frame`（无头出帧视觉验证）、
`airtrim-spike srt`（同一纯函数出 SRT）。

### D5 · 简繁归一化用 ICU transform，零依赖

`StringTransform` 自定义 ICU ID（`"Hant-Hans"`）做繁→简归一。M1.1 第一周
用 spike 素材验证覆盖率；不达标再评估词表方案（引第三方库需过 ADR-0001
许可检查）。归一化发生在 SpeechPipeline 产出 Transcript 之前，词数组与
原文逐字对齐（变长映射时保词边界）。

## 3. 模块任务拆解

| 模块 | M1 交付 | 来源 |
|---|---|---|
| `SpeechPipeline` | `Transcriber` 协议 + WhisperKit 适配（CMTime）· EnergyVAD 正式版 · 融合 · 断句 · 简繁归一 | spike 代码毕业重写，语义已验证 |
| `MediaEngine` | 导入校验 · PCM 抽取 · 烧录导出 | spike AudioLoader/EarCheck 毕业 |
| `Subtitles` | cue 生成 + SRT 序列化（纯函数 + 全量单测） | 新写 |
| `EditModel` | `TranscriptPatch` + `EditSession` 快照 undo | 新写（M2 的地基） |
| `AirTrimApp` | 导入 → 进度 → 逐句编辑器 → 导出面板 · ModelInstaller | 新写 |
| `AirTrimSpike` | 保留作回归复测工具，不进产品依赖图 | 现状 |

## 4. 阶段与验收

- **M1.1 Core headless（先绿后 UI）**：上表 Core 部分 + 单测；用 spike CLI 加
  `srt` 子命令跑通"视频 → SRT"全链路，koubo-01 出片人工验收字幕质量。
- **M1.2 App 最小可用**：导入/转写/编辑/导出 SRT；ModelInstaller 完整体验
  （进度、续传、校验、磁盘不足提示）。
- **M1.3 烧录 + 发布**：烧录导出、错字回归测试、README/截图、
  notarized DMG + Homebrew Cask 首个 release（ADR-0001 分发决策落地）。

每阶段完成标准：swift build + swift test + check-architecture.sh 三绿 +
阶段验收项人工确认。

## 5. 风险与对策

| 风险 | 对策 |
|---|---|
| 上游 PR #511 未合并 | `ZhWordSplitTokenizer` 包装器随 SpeechPipeline 毕业；合并后一行删除 |
| 3GB 模型下载体验 | D1 断点续传 + 明确进度 UI；探索 turbo 模型（large-v3-v20240930，约一半体积）作为默认档 |
| 长视频（1h+）内存/耗时 | 转写分段流式进 Transcript；M1 标注"建议 ≤30min"，优化留 M2 |
| 简繁 ICU 覆盖不全 | M1.1 首周验证；备选词表方案 |
| 快语速/BGM 素材未验证（M0 注记） | M1.2 起收集真实用户素材回归跑 spike evaluate |

## 6. 明确不做（防蔓延）

剪辑/紧凑（M2）· 时间线与波形（M2）· 建议审阅（M3）· 字幕样式模板 ·
FCPXML · 批量/CLI 产品化 · 双语字幕。
