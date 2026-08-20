# AirTrim 架构总览

> 状态：设计阶段（pre-alpha），尚无实现。本文是所有实现的依据；与 ADR 冲突时以 ADR 为准。

## 1. 产品定位

转写驱动的口播精剪工具（参照系：Descript 的精剪子集，中文优先、原生、开源）。
核心洞察：**对口播视频，文字稿是最高效的剪辑界面**——删掉一句话的文字 = 删掉对应视频片段；时间线只负责验证和微调。

**Non-goals（v1，见 ADR-0005）**：多轨、转场、贴纸、素材库、调色、通用剪辑。

## 2. 数据流

```
源视频文件（只读，永不修改）
  │
  ├─ MediaEngine ──── 解码 · 抽取音频 PCM
  │                          │
  │                    SpeechPipeline
  │                    ├─ VAD → [SilenceInterval]
  │                    └─ ASR → Transcript（词级时间戳，不可变快照）
  │                          │
  │                     Analysis（纯函数层）
  │                    ├─ PauseAnalyzer      （本地 · 信号处理）
  │                    └─ VerbosityAnalyzer ←─ LLMProvider（BYOK 云端/Ollama，只见文字稿）
  │                          │
  │                    [EditSuggestion]（统一建议格式）
  │                          │
  │                     EditModel ←──── 用户审阅（接受/拒绝）
  │                    EditList = keep/cut 区间（唯一真相源，值类型快照）
  │                          │
  ├─ MediaEngine.preview ── AVMutableComposition（零转码实时预览）
  └─ MediaEngine.export ─── AVAssetExportSession（导出 + 字幕烧录）+ SRT/FCPXML
```

## 3. 模块职责

| 模块 | 类型 | 职责 |
|---|---|---|
| `MediaEngine` | 系统框架适配层 | AVAsset 解码、音频 PCM 抽取、`AVMutableComposition` 预览拼装、`AVAssetExportSession` 导出、字幕烧录。唯一允许操作 AVFoundation 可变对象的模块。 |
| `SpeechPipeline` | 系统框架/模型适配层 | VAD（静音区间）+ ASR（词级时间戳）→ `Transcript`。时间戳的唯一来源。 |
| `Analysis` | 纯值类型层 | 三个分析器，纯函数：`(Transcript, [SilenceInterval], 配置) → [EditSuggestion]`。不 import AVFoundation。 |
| `LLMProvider` | 网络适配层 | BYOK provider 协议（Claude / OpenAI / DeepSeek / Ollama）。整个 Core 唯一允许联网的模块；只发送文字稿。 |
| `EditModel` | 纯值类型层 | `EditList`、suggestion 生命周期、undo（快照栈）。剪辑状态唯一真相源。 |
| `AirTrimApp` | UI | 文字稿编辑器（主界面）、波形时间线（辅助）、建议审阅面板、导出与设置。只依赖 Core 的协议 + 值类型。 |

## 4. 核心数据模型（全部值类型 · Sendable · 可直接单测）

权威时间一律用 `CMTime`（有理数，来自 CoreMedia——值类型框架，Analysis 可用）；`Double` 秒只用于 UI 展示，绝不作为权威值回写。

```swift
struct TranscriptWord: Sendable {
    let text: String
    let range: ClosedRange<CMTime>     // 源时间轴
    let confidence: Float
}

struct TranscriptSentence: Sendable {
    let id: Int                        // LLM 只允许引用这个编号
    let words: Range<Int>              // 指向 Transcript.words 的下标区间
}

struct Transcript: Sendable {          // 不可变快照；重转写 = 新 Transcript
    let words: [TranscriptWord]
    let sentences: [TranscriptSentence]
}

struct SilenceInterval: Sendable {
    let range: ClosedRange<CMTime>
    let peakEnergy: Float              // 区分真静音与低语/底噪
}

struct EditSuggestion: Identifiable, Sendable {
    enum Kind: Sendable {
        case pause
        case verbosity(category: VerbosityCategory, reason: String, confidence: Float)
    }
    enum State: Sendable { case proposed, accepted, rejected }

    let id: UUID
    let kind: Kind
    let range: ClosedRange<CMTime>     // 由本地词级数据换算，永不来自 LLM
    var state: State
}

enum VerbosityCategory: Sendable { case repetition, falseStart, offTopic, padding }

struct EditList: Sendable {            // 唯一真相源
    var cuts: [ClosedRange<CMTime>]    // 不变量：有序、互不重叠（合并于接受时）
}

struct EditSession: Sendable {         // undo = 快照栈
    var current: EditList
    var history: [EditList]
}
```

## 5. 关键机制

### 5.1 建议式编辑（信任模型）

分析器全部产出 `EditSuggestion`，UI 一套审阅交互（按类别着色、逐条或按类接受、切点预览跳听）。
- 停顿：可一键全收（本地确定性高），但同样走 suggestion → accept 流程，可撤销。
- 废话（verbosity）：**必须人工确认**。错删一句好内容比留十句废话更伤信任。

### 5.2 LLM 契约（详见 cut-quality skill）

- 输入：带句编号的全文（+ 可选主题提示）。
- 输出：结构化 JSON `{sentence_ids, category, reason, confidence}`。
- **禁止 LLM 输出时间戳**；本地由句编号 → 词区间 → `CMTime` 反查。杜绝模型编造数字。
- 无 Key / 离线时 verbosity 功能优雅降级（隐藏入口 + 引导设置），其余功能不受影响。

### 5.3 剪切听感（详见 cut-quality skill）

- 保留最小停顿：句中 ~150ms、句尾 ~250ms（默认值，随"紧凑度"滑杆缩放）。
- 切点音频 crossfade 20–40ms（equal-power）。
- 切点对齐词边界并外扩 padding 40–60ms，绝不在元音中间切。

### 5.4 预览与导出

- 预览：`EditList` → `AVMutableComposition`（`insertTimeRange` 拼 keep 区间），零转码、秒级反馈。
- 导出 v1：`AVAssetExportSession` 全量重编码（简单可靠）；关键帧对齐的智能剪切留到后续优化。
- 字幕：烧录（Core Animation 合成）+ SRT + FCPXML（进 Final Cut 精修的专业出口）。

## 6. 已识别的最大风险

| 风险 | 缓解 |
|---|---|
| 中文词级时间戳精度不足（剪辑吞字） | M0 spike 用真实素材量化验证，达标才往下走（`docs/spikes/m0-asr-spike.md`）；备选强制对齐 |
| 剪切点听感生硬 | 5.3 的参数体系 + spike 阶段用耳朵验收 |
| LLM 废话误判 | 建议式 + 分类置信度 + 审阅 UI；绝不自动删 |
| 长视频性能（1h+ 素材） | Transcript/建议分段惰性加载；分析器纯函数天然可并行 |
