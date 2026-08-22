# ADR-0007 · 云端 ASR 接入：DashScope Fun-ASR（Paraformer 系，BYOK）

- 状态：已接受（方向拍板 2026-08-21）；**代码接入以 spike 过线为验收**（见「验收」）
- 日期：2026-08-21
- 修订：ADR-0003 决策 #1（ASR 完全本地）与隐私红线 #3（音频字节绝不上传）——仅对「ASR 转写音频」放开例外

## 背景

1. 产品下限由中文词级时间戳精度决定（通过线：中位 ≤80ms / P95 ≤200ms）。ADR-0006 定稿 WhisperKit 本地引擎，其词级时间戳需 VAD 融合后才可作剪切依据（Whisper 词首系统性漂早 -230ms）；本地 large-v3 模型下载约 3.1GB。
2. FunASR/Paraformer 是 ADR-0006 预留的 B 计划：**原生中文（字级）时间戳**，不存在 WhisperKit 中文「整句粘词 + 1.4s 截断」的结构性问题。
3. 用户决策：评估**云端 ASR** 作为第二条引擎路径，覆盖弱机 RTF / 免大模型下载 / 更强中文时间戳，并接受「ASR 转写音频上云」对隐私红线的放宽。**方向已拍板，先落 ADR，spike 验收，再动 Core 代码。**

## 决策

1. **新增云 ASR 为第二条引擎路径**，与本地 WhisperKit 共存（不替换）：本地为默认 + 离线兜底；云 ASR 为可选引擎，由 App 设置切换。
2. **引擎**：阿里云百炼 DashScope Fun-ASR（Paraformer 系）录音文件识别（异步提交 + 轮询）；**BYOK**——用户自备阿里云 API Key，Bearer 认证。延续 ADR-0003 的 BYOK 哲学（Key 持久化与 `LLMConfig` 同模式：`~/Library/Application Support/AirTrim/` 下纯 JSON 文件；ADR-0003 声称的 Keychain 存取与实现不符，一并更正）。
3. **隐私红线修订（ADR-0003 #3）**：只有「ASR 转写音频」允许上云，且仅发往 DashScope 录音识别端点；**文字稿/废话判断仍只见文字稿**。音视频字节上云在全部网络路径中仅此一处。README / 设置 UI 需如实标注该变化。
4. **网络边界**：Core 内 `URLSession`/`URLRequest` 允许位置 = `LLMProvider/` + `ASRProvider/`（新增目录，代码阶段落位）。`scripts/check-architecture.sh` 守卫 #2 扩展为同时豁免这两处。
5. **时间戳契约**：云端词级 `words[].begin_time` / `end_time`（毫秒，Long）→ 本地转 `CMTime`（16000 标尺，走 `Transcript+Codable` 的有理数路径，不经 `Double`）→ **本地 VAD 融合照旧**（词首落入 VAD 静音区间的吸附到静音终点）。**LLM 仍禁止产生时间戳。** 通过线不变：中位 ≤80ms / P95 ≤200ms。
6. **验收**：真实口播素材 spike（复用 M0 方法学 + `evaluate`/`earcheck` 工具链），**过线才接 App 层**；不过线如实记录结论并回退本地 WhisperKit，不硬上。

## 依据

- FunASR Paraformer 逐字符时间戳原生输出（`funasr/utils/timestamp_tools.py`），CIF 机制有效分辨率 ~16.7ms/子帧，无 WhisperKit 中文分词路径。
- DashScope 录音文件识别返回 `words[]` 词级 `begin_time`/`end_time`（毫秒）；**词级非严格逐字**（一词可含多字，如「阿里巴巴」单条返回）——与项目 `TranscriptWord` 粒度一致，精剪影响由 spike 判定。
- 本地 VAD（`EnergyVAD`）不动，词首吸附静音终点的融合逻辑在云词边界上照常工作（云返回 ms 与本地 VAD 同时间轴）。

## 开放项（代码阶段定，不阻塞 ADR）

- **产品接入模式**：异步录音文件识别 + **本地 VAD 静音切块**（已实现，任意时长）——单段 ≤180s 走 base64 data URI 免 OSS，逐段提交/轮询/偏移拼接。替代方案：OSS 上传（单任务无切块）与实时 websocket（paraformer-realtime-v2），长连接稳定性待评估，均未采用。
- **成本**：按量计费（按音频时长），ADR 记录、由设置 UI 明示。

## 已知坑（接入时处理）

- `MAX_TOKEN_DURATION` 上限（默认 12 帧 ≈720ms）会截断长音节（拉长语气词「啊——」），需调参（普通话建议 15–25 帧）。
- 标点无时间戳 → 文本/时间戳长度对齐后处理。
- 整体偏移 → `vad_offset` / `force_time_shift` 补偿（与 Whisper 词首 -230ms 同类，但为可调固定偏移）。
- 词级非逐字粒度 → spike 判定。

## 验收结果（2026-08-21 · `results/koubo-01-funasr-cloud.md`）

- **`paraformer-v2`（异步 · 逐字时间戳）：过线 ✅**。VAD 融合后中位 **30ms**、P95 **74.5ms**、最大 130ms、CER 5.6%、RTF 0.12（209.9s 全片）。逐字粒度（每字独立时间戳），无需融合也能过线（raw 35/80.9ms）。**云端 ASR 接入条件成立。**
- **`qwen-audio-3.0-asr-flash`（同步 · 词级）：未达标 ❌**（中位 50ms / P95 217ms）。根因是词级粒度吞词内边界（「这个问题」「一个孩子」4 字词并成单词），非漂移；不进入接入。
- **免 OSS 前提**：异步 `file_urls` 收 base64 data URI（≤~10MB 验证通过）。**任意时长已支持**：本地按 VAD 静音切块（单段 ≤180s），209.9s 全片分片转写 617 词与单次转写一致（2026-08-22 e2e 验证）。
- **结论（per 决策 #6）**：逐字 Paraformer 过线 → 重审接入条件成立；flash 词级模型弃用。是否进入 App 接入（`ASRProvider` + `CloudASRTranscriber`）由产品决策（音频上云的隐私姿态变化）。

## 后果

- ✅ 弱机 / 未下载本地模型时仍有可用转写；中文时间戳候选增强（B 计划转正评估）。
- ✅ 本地路径保留，隐私红线只松「ASR 音频」一处，其余网络行为不变。
- ⚠️ 开源信任点从「音视频永不上传」变为「仅 ASR 转写音频上云，其余只见文字稿」——需在 README / 设置 UI 如实标注。
- ⚠️ 依赖阿里云账户与账单；BYOK 延续，Key 由用户自备。
