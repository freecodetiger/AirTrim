# Analysis（占位 · 未实现）

**职责**：三个分析器，全部是纯函数 `(Transcript, [SilenceInterval], 配置) → [EditSuggestion]`：

- `PauseAnalyzer` —— 停顿（VAD × 词间隙交叉验证）
- `FillerAnalyzer` —— 语气词（词表匹配）
- `VerbosityAnalyzer` —— 结合全文的废话（经 LLMProvider 调用模型，只收句编号）

**边界**：纯值类型层，**不得 import AVFoundation**（脚本守卫；CoreMedia 的 `CMTime` 允许）。不直接联网（网络归 LLMProvider）。

实现顺序：Pause（M2）→ Filler、Verbosity（M3）。听感参数与 LLM 契约见 `.claude/skills/cut-quality/`。
