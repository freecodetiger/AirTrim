# ADR-0002 · Swift 原生 + AVFoundation，不依赖 ffmpeg

- 状态：已接受
- 日期：2026-07-26

## 背景

技术栈候选：Swift 原生 / Tauri / Electron。产品是 macOS-only 的媒体密集型应用，且开源定位要求许可干净、构建简单（ADR-0001）。

## 决策

1. **Swift 6 + SwiftUI/AppKit + AVFoundation**，SPM 工程。
2. 解码、预览合成、导出、字幕烧录全部走 AVFoundation：
   - 预览 = `EditList` → `AVMutableComposition`，零转码、秒级反馈——这是非破坏性编辑（ADR-0004）的天然载体；
   - 导出 v1 = `AVAssetExportSession` 全量重编码。
3. **不引入 ffmpeg**：许可纠缠（GPL/LGPL 组件）、vendored 二进制负担、与 AVFoundation 功能重复。

## 后果

- ✅ 原生性能与系统集成（Metal、CoreMedia、Keychain）；无 vendored 二进制（吸取 ProGhostty vendored libghostty-vt 的维护教训）。
- ✅ 许可干净、包体小。
- ⚠️ 容器格式支持受限于系统（部分 mkv/vp9 打不开）——明示"不支持的格式请先转 mp4/mov"，不为此破例引 ffmpeg。
- ⚠️ 智能剪切（关键帧对齐免重编码）在 AVFoundation 下实现更费劲，放到 M3 之后。
