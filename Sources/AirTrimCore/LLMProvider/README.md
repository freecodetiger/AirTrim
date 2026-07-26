# LLMProvider（占位 · 未实现）

**职责**：BYOK provider 协议与适配（Claude / OpenAI / DeepSeek / Ollama 本地兜底）、API Key 的 Keychain 存取、请求重试与限流。

**边界**：**整个 AirTrimCore 唯一允许出现网络代码（URLSession）的模块**（脚本守卫）。只发送文字稿——音视频字节出现在此模块即重大违规（ADR-0003 隐私红线）。

首个实现在 M3。prompt 契约见 `.claude/skills/cut-quality/`。
