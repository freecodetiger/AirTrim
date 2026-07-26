# AirCut

> Open-source, native macOS editor for talking-head videos: transcribe locally, edit video by editing text, and tighten your cut in one click — remove pauses, filler words, and context-aware rambling. Chinese-first.

AirCut 是开源的 macOS 原生「口播精剪」工具，面向自媒体创作者。它不是另一个多轨剪辑器——它相信：**对口播视频，文字稿才是最高效的剪辑界面**。

```
导入视频 → 本地转写（词级时间戳）→ 文字稿即剪辑
        → 一键紧凑（停顿 / 语气词 / 结合全文的废话）→ 带字幕导出
```

## 三个「一键」

| 功能 | 原理 | 运行位置 |
|---|---|---|
| 🕳️ 清除停顿 | VAD 静音检测 + 词间隙分析，保留自然呼吸感（可调紧凑度） | 本地，毫秒级 |
| 💬 清除语气词 | 词级时间戳 + 词表匹配（嗯 / 啊 / 呃 / 那个 / 就是说…） | 本地，即时 |
| 🧹 识别废话 | LLM 通读全文，标出重复表达、口误重来、离题内容——**只给建议，删不删你说了算** | 云端（自带 API Key）或本地 Ollama |

隐私底线：**音视频永不上传**。转写完全在本地跑；废话识别只发送文字稿，且需要你自己的 API Key（或指向本地模型）。

## 状态

🚧 **Pre-alpha · 文档建设阶段。** 当前仓库是架构骨架 + 设计文档，尚无可用功能。路线：

1. **M0** — ASR 技术验证：中文词级时间戳精度达标才往下走
2. **M1** — 转写 + 字幕编辑 + SRT 导出 / 烧录
3. **M2** — 静音检测 + 一键紧凑 + 时间线预览
4. **M3** — 语气词 + LLM 废话建议 + 审阅界面

详见 [docs/roadmap.md](docs/roadmap.md)。

## 设计文档

- [架构总览](docs/architecture/overview.md) —— 数据流、模块、核心数据模型
- [职责边界表](docs/architecture/ownership-map.md) —— 每个关注点的唯一 owner
- [决策记录 ADR](docs/adr/) —— 为什么开源 / 为什么 AVFoundation 不用 ffmpeg / 为什么 BYOK / 为什么非破坏性 EDL / v1 范围
- [M0 spike 计划](docs/spikes/m0-asr-spike.md) —— ASR 选型的量化验证方案

## 构建

要求：macOS 14+，Xcode 15+（Swift 6.1）。

```bash
swift build
swift test
scripts/check-architecture.sh
```

## 技术栈

Swift 6 · SwiftUI/AppKit · AVFoundation（无 ffmpeg 依赖）· WhisperKit / FunASR（M0 后定）· BYOK LLM（Claude / OpenAI / DeepSeek / Ollama）

## License

[MIT](LICENSE)
