# AirTrim

> Open-source, native macOS editor for talking-head videos: transcribe locally, edit video by editing text, and tighten your cut in one click — remove pauses, filler words, and context-aware rambling. Chinese-first.

AirTrim 是开源的 macOS 原生「口播精剪」工具，面向自媒体创作者。它不是另一个多轨剪辑器——它相信：**对口播视频，文字稿才是最高效的剪辑界面**。

```
导入视频 → 本地转写（词级时间戳）→ 文字稿即剪辑界面
        → 一键紧凑（停顿 / 语气词 / 结合全文的废话）→ 带字幕导出
```

## 两个「一键」

| 功能 | 原理 | 运行位置 |
|---|---|---|
| 🕳️ 一键紧凑 | VAD 静音检测 + 词间隙分析，清除停顿、保留自然呼吸感（可调紧凑度） | 本地，毫秒级 |
| 🧹 一键识别废话 | LLM 通读全文，标出重复表达、口误重来、离题内容——**只给建议，删不删你说了算** | 云端（自带 API Key）或本地 Ollama |

隐私底线：**文字稿绝不外传**。转写默认全本地跑（WhisperKit）；可选云端转写（DashScope，你的 Key），此时仅 ASR 转写音频上云（ADR-0007）；废话识别只发送文字稿，且需要你自己的 API Key（或指向本地模型）。

## 状态

🚧 **Alpha · v0.1.4（M0–M4 全部落地）。** 已可用：

- 导入口播视频 → 转写（默认本地 WhisperKit，可选云端 DashScope，词级时间戳，中文优化）
- 逐句编辑器：改错字、拆句/合句、整句试听、当前句跟随高亮
- **手动精确剪**（剪刀模式）：轨道两击成剪，磁吸对齐，⌘Z 逐次撤回
- **一键紧凑**（双滑杆：门槛 × 保留量）：VAD 交叉验证停顿分析 → 建议式审阅 → 逐条接受/拒绝/跳听 → 成片实时预览
- **一键识别废话**：LLM 通读全文标出可删整句——**只给建议，删不删你说了算**
- **AI 语义断句**：长稿自动分块、逐块进度、失败块高亮与选择性重试
- **一键生成抖音文案**：6 赛道人设可选（通用/技术/职场/美妆/健身/育儿，持久化+关键词推荐），AI 生成标题 + 配文 + 标签，右侧边栏一键复制
- 项目管理：项目主页恢复历史会话，每次修订即落盘
- 波形时间线：切割区间 / 建议块 / 播放头，scrub 定位
- 导出 SRT / **字幕烧录 MP4**（白字黑边、竖拍横拍自适应；源文件只读，输出新文件）
- 设置窗口（⌘,）：AI 服务配置 + 语音模型管理（多模型发现、一键下载推荐档位、校验修复）
- 应用内模型下载（large-v3 ~3.1 GB，断点续传，国内自动走镜像源）

路线：**M0** ASR 验证（✅）→ **M1** 字幕工具（✅）→ **M2** 一键紧凑（✅）→ **M3** AI 建议闭环（✅）→ **M4** 项目管理 / AI 辅助（✅）。v0.1.4 已发布（DMG 暂为 ad-hoc 签名，公证待 owner 证书，见 [docs/release.md](docs/release.md)）；后续方向见 [docs/roadmap.md](docs/roadmap.md)。

> M0 过程中发现并修复了 WhisperKit 的中文词级时间戳截断 bug（语言检测返回 `zh-Hans` 未命中白名单 `zh`），已向上游提交 [issue #510](https://github.com/argmaxinc/argmax-oss-swift/issues/510) 与 [PR #511](https://github.com/argmaxinc/argmax-oss-swift/pull/511)；合并前应用内置逐字切词兜底。

## 使用

1. `swift build && scripts/bundle-app.sh` 构建 `.app` bundle（macOS 要求 GUI 应用必须是 bundle）。
2. 首次启动先做「环境准备」：下载语音模型（一次性，~3.1 GB）+ 配置大模型 API（OpenAI 兼容，断句/废话/文案需要）；两项就绪才进入核心工作流。
3. 拖入口播视频 → 等待本地转写 → 逐句编辑 + 一键紧凑。
4. 可选：设置（⌘,）→ AI 服务 填入 OpenAI 兼容 API 地址与 Key，保存后 AI 断句 / 抖音文案 / 识别废话 可用。
5. 工具栏导出 SRT，或「导出视频」直接烧录字幕。

> **LLM 配置**：通过设置窗口 AI 服务页编辑保存，持久化到 `~/Library/Application Support/AirTrim/llm-config.json`。不使用环境变量或 Keychain。

## 设计文档

- [架构总览](docs/architecture/overview.md) —— 数据流、模块、核心数据模型
- [职责边界表](docs/architecture/ownership-map.md) —— 每个关注点的唯一 owner
- [决策记录 ADR](docs/adr/) —— 为什么开源 / 为什么 AVFoundation 不用 ffmpeg / 为什么 BYOK / 为什么非破坏性 EDL / v1 范围
- [M0 spike 计划](docs/spikes/m0-asr-spike.md) —— ASR 选型的量化验证方案
- [设置界面设计](.claude/settings-design-v2.md) —— 分级设置 + 语音模型管理方案
- [M2 一键紧凑设计](docs/design/m2-tighten.md) —— EditList 模型、停顿分析、预览合成
- [M3 AI 建议闭环设计](docs/design/m3-ai-suggestions.md) —— 语气词 / 废话分析器 + LLMProvider
- [M4 项目管理设计](docs/design/m4-project-management.md) —— 项目主页、会话恢复、缓存管理
- [手动精确剪 spec](docs/design/manual-cut.md) —— 剪刀模式两击成剪 + undo

## 构建

要求：macOS 14+，Xcode 15+（Swift 6.1）。

```bash
swift build                      # 构建
swift test                       # 全量测试（swift-testing）
scripts/check-architecture.sh    # 分层守卫（Core 无 UI；网络仅 LLMProvider）
scripts/bundle-app.sh            # 组装 .app bundle（macOS GUI 窗口管理必需）
scripts/make-app.sh              # 打包 build/AirTrim.app（含图标，ad-hoc 签名）
scripts/make-dmg.sh              # 打包 build/AirTrim-<版本>.dmg
```

发布流程（签名 / 公证 / Homebrew Cask）见 [docs/release.md](docs/release.md)；
发版前回归清单见 [docs/release-checklist.md](docs/release-checklist.md)。

## 技术栈

Swift 6 · SwiftUI/AppKit · AVFoundation（无 ffmpeg 依赖）· WhisperKit（ADR-0006）· BYOK LLM（OpenAI 兼容格式：DeepSeek / OpenAI / Ollama…）

## License

[MIT](LICENSE)
