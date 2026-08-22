# Spike 评测报告 · DashScope 云端转写（ADR-0007 验收）

- 日期：2026-08-21
- 素材：`Fixtures/private/koubo-01.mov`（209.9s 真实口播）
- 端点：DashScope 百炼（北京）
- 方法：转写 → `evaluate`（32 个 truth 边界）→ **本地 VAD 融合**（词首吸附静音终点，产品契约）为最终口径
- 命令：`transcribe-cloud --async --model paraformer-v2`（全片）→ 融合 → `evaluate`

## 结论速览

| 引擎 | 粒度 | 中位 | P95 | 最大 | CER | 判定 |
|---|---|---|---|---|---|---|
| `qwen-audio-3.0-asr-flash`（同步） | 词级（4 字词吞内界） | 50ms | 217ms | 330ms | —（口径无效） | ❌ |
| `paraformer-v2`（异步）**融合后** | **逐字** | **30ms** | **74.5ms** | 130ms | **5.6%** | ✅ |
| 对照：WhisperKit large-v3（本地，融合后） | 逐字 | 0.0ms | 6.7ms | 42ms | 0% | ✅（M0 基线） |

**通过线：中位 ≤80ms / P95 ≤200ms / CER ≤8%。**

## Paraformer-v2（异步 · 逐字时间戳）

- 转写：209.9s · 24.6s（含网络）· RTF **0.12**
- 词数：617（逐字粒度）
- 边界：中位 **30.0ms** ✅ · P95 **74.5ms** ✅ · 最大 130ms
- CER：**5.6%** ✅（全片对全片，公平口径）
- 误差分布：32 个边界 29 个 <100ms、0 个 ≥200ms

```
  0– 20ms |██████████████████████████████ 15
 20– 40ms |██████████████ 7
 40– 60ms |██████████ 5
 60– 80ms |██████ 3
 80–100ms |██ 1
100–120ms | 0
120–140ms |██ 1
  ≥200ms  | 0
```

- **逐字证据**：words 数组每字独立时间戳（「今」760–950ms、「天」950–1160ms、「聊」1160–1310ms）。

## 对比：qwen-audio-3.0-asr-flash（同步 · 词级）——未达标

- 中位 50ms ✅ 但 P95 217ms ❌。根因是**词级粒度吞词内边界**：「这个问题」「一个孩子」4 字词并成单词，中间边界丢失（truth 标注基于逐字粒度在这些位置有边界）。
- 本地 VAD 融合只吸附 13 词、P95 不变 → 排除漂移，纯粒度问题。
- 结论：flash 词级模型不进入接入；**逐字 Paraformer 才是 ADR-0006 预留的 B 计划形态。**

## 方法注记

- **免 OSS**：异步接口 `file_urls` 收 base64 data URI（本 spike 9MB 验证通过）。但 1h+ 素材（~115MB→base64 153MB）超 HTTP 请求体承受，长视频需 OSS URL 或实时 websocket——产品接入阶段的开放项。
- **参数**：paraformer 默认关闭时间戳，需 `timestamp_alignment_enabled: true`；`channel_id` 须为数组（本次已按实际报错修正）。
- **VAD 融合**：全片 57 个词首被吸附，中位 30ms（raw 35ms），P95 74.5ms（raw 80.9ms）——融合仍符合产品契约，但逐字 Paraformer 不依赖它也能过线。

## 判定（per ADR-0007）

- **paraformer-v2 逐字时间戳过线（30/74.5/130 · CER 5.6%）→ 云端 ASR 接入条件成立。**
- 与本地 WhisperKit（0/6.7ms）相比仍明显宽，但都在通过线内；云路径价值在免大模型下载 / 弱机 RTF。
- 下一步为 App 接入（`ASRProvider` + `CloudASRTranscriber` conform `Transcriber`），涉及隐私姿态变化（音频上云），需产品决策是否启用。
