# 职责边界表（Ownership Map）

> 改代码前先查此表：这个职责归谁？我要改的状态谁拥有？
> 发现职责漂移时，先改本表（走 ADR 讨论），再动代码。

## 唯一 owner

| 关注点 | 唯一 owner | 位置 | 守卫 |
|---|---|---|---|
| 源媒体访问（只读）· 解码 · 音频抽取 | `MediaEngine` | `Sources/AirTrimCore/MediaEngine/` | — |
| 预览合成（AVMutableComposition） | `MediaEngine` | 同上 | — |
| 导出 · 字幕烧录 | `MediaEngine` | 同上 | — |
| VAD 静音检测 → `[SilenceInterval]` | `SpeechPipeline` | `Sources/AirTrimCore/SpeechPipeline/` | — |
| ASR 转写 · 词级时间戳 → `Transcript` | `SpeechPipeline` | 同上 | — |
| **时间戳权威值**（`CMTime`） | `SpeechPipeline` 产出，全局只读消费 | — | 代码评审 |
| 停顿建议 | `PauseAnalyzer` | `Sources/AirTrimCore/Analysis/` | 无 AVFoundation（脚本） |
| 废话建议（结合全文） | `VerbosityAnalyzer` | 同上 | 同上 |
| 网络调用 · LLM 文字稿（BYOK，Key 存 llm-config.json 明文） | `LLMProvider` | `Sources/AirTrimCore/LLMProvider/` | URLSession 仅此目录 + `ASRProvider/`（脚本） |
| 云端 ASR 客户端 · 音频上云 · 词级时间戳拉取 | `ASRProvider` | `Sources/AirTrimCore/ASRProvider/` | 同上（ADR-0007） |
| **剪辑状态**：`EditList` · suggestion 生命周期 · `TranscriptPatch`（改字/断句修订）· undo | `EditModel` | `Sources/AirTrimCore/EditModel/` | 代码评审 |
| 字幕条生成（Transcript+Patch → cues → SRT 文本） | `Subtitles` | `Sources/AirTrimCore/Subtitles/` | 无 AVFoundation（脚本） |
| UI 全部 | `AirTrimApp` | `Sources/AirTrimApp/` | Core 无 SwiftUI/AppKit（脚本） |

## 分层与依赖方向

```
AirTrimApp（SwiftUI/AppKit · UI）
   ↓ 只依赖协议 + 值类型
AirTrimCore
   ├── 纯值类型层：EditModel · Analysis        ← 无系统框架依赖（CoreMedia 除外）
   └── 适配层：    MediaEngine（AVFoundation）
                   SpeechPipeline（ASR/VAD 模型 · 本地默认 + 云端可选）
                   LLMProvider / ASRProvider（URLSession · 仅此两处联网）
```

- 依赖只能向下：App → Core；适配层可以消费纯值类型层，反向禁止。
- 适配层之间不互相依赖（MediaEngine 不认识 LLMProvider，反之亦然）；需要协作时由 App 层（组合根）编排。

## 最容易翻车的重复状态（历史教训预防）

1. **第二份剪辑区间** —— UI 或预览层缓存了自己的 keep/cut 列表。只允许从 `EditList` 派生，派生物必须是不可变快照。
2. **第二份时间戳** —— 用 `Double` 秒在某处换算后回写。权威值只有 `SpeechPipeline` 产出的 `CMTime`。
3. **LLM 产出的数字** —— 任何来自模型的 offset/时长/时间戳都不可信，只接受句编号。
