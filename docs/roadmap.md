# Roadmap

> 原则：每个里程碑独立可用、可发 release。顺序不可交换——M0 不达标就不写 UI。

## M0 · ASR 技术验证（spike，1–2 周）

整个产品的下限由中文词级时间戳精度决定，先验证再投入。

- 交付：`docs/spikes/m0-asr-spike.md` 定义的 CLI spike target + 量化报告 + ADR-0006（ASR 选型决策）。
- 完成标准（详见 spike 文档）：词边界中位误差 ≤ 80ms、P95 ≤ 200ms、RTF ≤ 0.5（Apple Silicon）、中文断句可用。
- **不写任何 UI。** 用命令行剪出成片，耳朵验收听感。

## M1 · 字幕工具（首个可发布版本）

- 导入视频 → 本地转写 → 文字稿编辑（改错字、调断句）→ SRT 导出 + 字幕烧录导出。
- 这本身已是有独立价值的开源工具，可以开始积累用户和反馈。
- 涉及模块：MediaEngine（导入/导出）、SpeechPipeline、App（文字稿编辑器最小版）。

## M2 · 一键紧凑（核心卖点上线）

- VAD 静音检测 + PauseAnalyzer + 可调"紧凑度"。
- 波形时间线（显示切割区间）+ `AVMutableComposition` 实时预览。
- 剪切听感参数体系落地（最小停顿保留 / crossfade / 词边界 padding）。

## M3 · AI 建议闭环

- VerbosityAnalyzer + LLMProvider（BYOK：Claude / OpenAI / DeepSeek / Ollama）。
- 建议审阅 UI：按类别着色、逐条/按类接受、切点跳听预览。

## 之后（不承诺顺序）

- 智能剪切导出（关键帧对齐，无损段直拷 + 切点局部重编码）。
- 字幕样式模板（花字/双语）。
- FCPXML 导出打磨（进 Final Cut 精修工作流）。
- 批量处理 / CLI 模式。
- 多轨 / B-roll —— 仅在口播精剪做透之后评估（需新 ADR 推翻 ADR-0005）。
