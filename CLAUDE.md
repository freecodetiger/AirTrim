# AirTrim · AI 开发指南

> 本文件是 Agent 进入项目的**唯一入口**，只放最高优先级规则。
> 各域细节在 `.claude/skills/` 与 `docs/`，用到时再查。
> 规则与代码冲突时，**以代码为准**，并回头更新本文件。

---

## 项目目标（Project Goal）

AirTrim 是开源的 macOS 原生「口播精剪」工具，面向自媒体创作者：

```
导入视频 → 本地转写（词级时间戳）→ 文字稿即剪辑界面
        → 一键紧凑（停顿 / 语气词 / 结合全文的废话）→ 带字幕导出
```

它**不是**通用多轨剪辑器（那是 Final Cut / 剪映的领地）。v1 只做单条口播视频的转写驱动精剪，做深做透（见 ADR-0005）。

优先级排序（发生冲突时按此裁决）：

```
源素材安全（非破坏性）  >  剪切正确性（不吞字/不漏字）  >  听感自然  >  架构边界清晰  >  功能  >  代码风格
```

---

## 核心原则（Core Principles · 不可违反）

- **源媒体文件只读。** 任何"剪辑"都是 `EditList`（keep/cut 区间的值类型）上的操作；只有导出才产生新文件（ADR-0004）。
- **`EditList` 是剪辑状态的唯一真相源。** 绝不在别处维护第二份剪辑区间、第二份 undo 栈。
- **时间戳的唯一来源是本地管线**（ASR 词级时间戳 + VAD）。权威时间用 `CMTime`（有理数），`Double` 秒只用于 UI 展示。**LLM 永不产生时间戳**，只引用句编号，由本地反查词级数据。
- **云端只见文字稿。** 音频/视频字节绝不上传；网络调用只允许出现在 `LLMProvider/`（脚本守卫）。
- **建议式编辑。** 三个分析器（停顿/语气词/废话）输出统一为 `EditSuggestion`；废话（verbosity）建议**必须人工确认**，绝不自动应用。UI 只有一套审阅交互。
- **剪切点必须自然。** 零间隙硬拼是禁令：最小停顿保留 + 音频 crossfade + 词边界 padding，参数见 `cut-quality` skill。
- **`AirTrimCore` 绝不 `import SwiftUI`/`AppKit`**；`Analysis/` 纯值类型，不 `import AVFoundation`。（由 `scripts/check-architecture.sh` 守卫。）
- **不重新发明架构，扩展现有架构。**

---

## 职责边界（唯一 owner）

| 关注点 | 唯一 owner | 位置 |
|---|---|---|
| 媒体解码 · 音频抽取 · 预览合成 · 导出/烧录 | `MediaEngine` | `Sources/AirTrimCore/MediaEngine/` |
| VAD 静音检测 + ASR 转写（词级时间戳）→ `Transcript` | `SpeechPipeline` | `Sources/AirTrimCore/SpeechPipeline/` |
| 停顿分析 | `PauseAnalyzer` | `Sources/AirTrimCore/Analysis/` |
| 语气词分析 | `FillerAnalyzer` | `Sources/AirTrimCore/Analysis/` |
| 结合全文的废话分析 | `VerbosityAnalyzer` | `Sources/AirTrimCore/Analysis/` |
| 云端 LLM 调用（BYOK · 唯一联网点） | `LLMProvider` | `Sources/AirTrimCore/LLMProvider/` |
| 剪辑状态（EditList / suggestion 生命周期 / TranscriptPatch / undo） | `EditModel` | `Sources/AirTrimCore/EditModel/` |
| 字幕条生成（cues / SRT 序列化，纯值类型） | `Subtitles` | `Sources/AirTrimCore/Subtitles/` |
| UI（文字稿编辑器 · 时间线 · 审阅 · 设置） | `AirTrimApp` | `Sources/AirTrimApp/` |

依赖方向：`App → Core`；Core 内 `Analysis`/`EditModel` 是纯值类型层，`MediaEngine`/`SpeechPipeline`/`LLMProvider` 是系统框架/网络适配层。**禁止回指。**

> 完整数据流与数据模型：`docs/architecture/overview.md` · `docs/architecture/ownership-map.md`
> 各域深入细节：`.claude/skills/`（edit-model / speech-pipeline / cut-quality）

---

## 改代码前的工作流

1. **读 ownership 表**，找到唯一 owner；跨模块改动读对应 skill。
2. **不引入重复状态** —— 本项目最容易翻车的两处：第二份剪辑区间、第二份时间戳。
3. **守住模块边界** —— 不跨层回指、Core 不碰 UI、Analysis 不碰 AVFoundation、网络只在 LLMProvider。
4. **扩展而非重写**。
5. `swift build` + `swift test` + `scripts/check-architecture.sh` 三者全绿再收工。
6. 涉及边界/状态归属的改动，**先补/改 ADR 或 overview.md 再动代码**。

---

## 禁止事项（Forbidden · Never）

- ❌ 修改或覆盖源媒体文件。
- ❌ 在 `EditModel` 之外维护剪辑区间 / undo 状态副本。
- ❌ 把 LLM 返回的时间戳或任何数字直接入库（只允许句编号反查本地数据）。
- ❌ 上传音频/视频字节到任何网络端点。
- ❌ `URLSession` / 网络代码出现在 `LLMProvider/` 之外。
- ❌ 自动应用 verbosity（废话）建议。
- ❌ 剪切点零间隙硬拼（必须最小停顿保留 + crossfade，见 `cut-quality` skill）。
- ❌ `AirTrimCore` 里 `import SwiftUI`/`AppKit`；`Analysis/` 里 `import AVFoundation`。
- ❌ 引入 ffmpeg 依赖（ADR-0002；许可与分发原因）。
- ❌ 未被明确要求就重新设计架构 / 管线。

---

## 偏好模式（Preferred）

- 组合优于继承 · 不可变快照优于共享可变状态 · 状态机优于散落 flag。
- 依赖注入（组合根装配）优于类内部 `new` 协作者。
- 小模块 · 纯值类型（可测）· 面向协议优于面向具体类。
- 分析器 = 纯函数：`(Transcript, [SilenceInterval]) → [EditSuggestion]`，直接单测。

---

## 构建与测试（Build & Test）

Swift 6.1 · macOS 14+ · 语言模式 `.v6` · 测试用 **swift-testing**（`import Testing`，非 XCTest）。

```bash
swift build                      # 构建
swift test                       # 全量测试
scripts/check-architecture.sh    # 分层守卫（Core 无 UI；网络仅 LLMProvider；Analysis 纯值类型）
```

### Git · Commit / Push

- Conventional Commits：`<type>(<scope>): <summary>`（如 `feat(analysis): …` / `docs(adr): …`）。
- 一个意图一个 commit；改代码先绿再 commit。
- **只有用户明确要求时才 push。**
- **commit 只署用户本人**：不加 `Co-Authored-By`、不加 AI/agent trailer。

---

## 现状备注

- **M0 已完成（2026-07-26）**：ASR 选型定为 WhisperKit + VAD 融合（ADR-0006），量化报告见 `docs/spikes/results/`；spike 工具保留在 `Sources/AirTrimSpike/`（兼作回归工具：transcribe/evaluate/burn/srt）。
- **M1 已完成（2026-07-27）**：转写→逐句编辑→SRT/烧录导出全链路 + 持久化 + 应用内模型下载，设计见 `docs/design/m1-subtitle-tool.md`，发版流程见 `docs/release.md`（公证待 owner 证书）。当前处于 **M2（一键紧凑）实施阶段**，分支 `feat/m2-tighten`，设计见 `docs/design/m2-tighten.md`。
- 项目名 **AirTrim** 已定（2026-07 由工作名 "AirCut" 更名，避免与 CapCut 撞名及 haircut 谐音）。
- 文档索引：`docs/architecture/overview.md`（总设计）· `ownership-map.md`（职责表）· `docs/adr/`（决策记录）· `docs/roadmap.md`（里程碑）· `docs/spikes/`（技术验证）。
