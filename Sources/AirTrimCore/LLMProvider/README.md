# LLMProvider

**职责**：BYOK provider 协议与适配（Claude / OpenAI / DeepSeek / Ollama 本地兜底）、API Key 存取（`~/Library/Application Support/AirTrim/llm-config.json` 明文 JSON，见 `LLMConfig`）、请求重试与限流。

**边界**：AirTrimCore 内允许出现网络代码（URLSession）的两个模块之一（另一为 `ASRProvider/`，脚本守卫）。只发送文字稿——音视频字节出现在此模块即重大违规（ADR-0003 隐私红线；ADR-0007 修订：音频上云仅限 `ASRProvider` 发往 DashScope 录音识别）。

prompt 契约见 `.claude/skills/cut-quality/`。
