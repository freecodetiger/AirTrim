# AirTrim

> Open-source, native macOS editor for talking-head videos: transcribe locally, edit video by editing text, and tighten your cut in one click — remove pauses, filler words, and context-aware rambling. Chinese-first.

AirTrim 是开源的 macOS 原生「口播精剪」工具，面向自媒体创作者。它不是另一个多轨剪辑器——它相信：**对口播视频，文字稿才是最高效的剪辑界面**。

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

🚧 **Alpha · M1（字幕工具）功能就绪，发布打磨中。** 已可用：

- 导入口播视频 → **全本地**转写（WhisperKit large-v3，词级时间戳，中文优化）
- 逐句编辑器：改错字、拆句/合句、整句试听、当前句跟随高亮
- **AI 语义断句**（可选）：OpenAI 兼容 API 自带 Key（DeepSeek 等）；只上传文字稿，时间戳永远来自本地
- 导出 SRT / **字幕烧录 MP4**（白字黑边、竖拍横拍自适应；源文件只读，输出新文件）
- 项目持久化：重启秒恢复上次会话，每次修订即落盘
- 应用内模型下载（3.1 GB，断点续传，国内自动走镜像源）

路线：**M0** ASR 验证（✅ 已达标，[报告](docs/spikes/results/koubo-01-whisperkit-large-v3.md)）→ **M1** 字幕工具（当前）→ **M2** 一键紧凑 → **M3** AI 建议闭环。详见 [docs/roadmap.md](docs/roadmap.md)。

> M0 过程中发现并修复了 WhisperKit 的中文词级时间戳截断 bug（语言检测返回 `zh-Hans` 未命中白名单 `zh`），已向上游提交 [issue #510](https://github.com/argmaxinc/argmax-oss-swift/issues/510) 与 [PR #511](https://github.com/argmaxinc/argmax-oss-swift/pull/511)；合并前应用内置逐字切词兜底。

## 使用

1. `scripts/make-app.sh` 构建 `build/AirTrim.app`，双击启动（正式 DMG 见 Releases，发布后提供）。
2. 首次启动引导下载语音模型（一次性，3.1 GB）。
3. 拖入口播视频 → 等待本地转写（有真实进度条）→ 逐句编辑。
4. 可选：设置（⌘,）→ AI 服务 填入 OpenAI 兼容 API 地址与 Key，工具栏「AI 断句」按语义重新断句。
5. 工具栏导出 SRT，或「导出视频」直接烧录字幕。

## 设计文档

- [架构总览](docs/architecture/overview.md) —— 数据流、模块、核心数据模型
- [职责边界表](docs/architecture/ownership-map.md) —— 每个关注点的唯一 owner
- [决策记录 ADR](docs/adr/) —— 为什么开源 / 为什么 AVFoundation 不用 ffmpeg / 为什么 BYOK / 为什么非破坏性 EDL / v1 范围
- [M0 spike 计划](docs/spikes/m0-asr-spike.md) —— ASR 选型的量化验证方案

## 构建

要求：macOS 14+，Xcode 15+（Swift 6.1）。

```bash
swift build                      # 构建
swift test                       # 全量测试（swift-testing）
scripts/check-architecture.sh    # 分层守卫（Core 无 UI；网络仅 LLMProvider）
scripts/make-app.sh              # 打包 build/AirTrim.app（含图标，ad-hoc 签名）
scripts/make-dmg.sh              # 打包 build/AirTrim-<版本>.dmg
```

发布流程（签名 / 公证 / Homebrew Cask）见 [docs/release.md](docs/release.md)；
发版前回归清单见 [docs/release-checklist.md](docs/release-checklist.md)。

## 技术栈

Swift 6 · SwiftUI/AppKit · AVFoundation（无 ffmpeg 依赖）· WhisperKit（ADR-0006）· BYOK LLM（OpenAI 兼容格式：DeepSeek / OpenAI / Ollama…）

## License

[MIT](LICENSE)
