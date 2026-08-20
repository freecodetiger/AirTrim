# 设计 · 环境准备门槛 + 进入编辑器自动断句

> 状态：设计定稿（2026-08-21，分支 feat/env-gate-auto-seg），owner 拍板三项决策：
> **A 硬门槛**（语音模型 + LLM 都就绪才进核心工作流）· **B 自动断句不进 undo 栈** ·
> **C 不允许跳过自动断句**。
> 范围：App 层状态机（Stage）+ ProjectStore 扩展 + EditSession 一个只读化扩展；不触碰 Core 分析器/LLMProvider 契约。

## 1. 背景与问题

- 转写完成直接进编辑器，句子是 ASR 原生断句（长句/口语场景切碎、黏连），用户要自己发现右上角「AI 断句」再点；断句质量直接影响后续紧凑/废话/文案体验，但入口太弱（之前讨论过）。
- 环境依赖（语音模型 + LLM API）是"能用但残缺"：没配 LLM 也能进，只是断句/废话/文案显示"需配置"——用户进到一半才撞见功能不可用。

## 2. 目标与非目标

**目标**
- 语音模型 + LLM **双就绪**才允许进入核心工作流；不满足就停在环境准备页。
- 进入编辑器前自动跑一次语义断句（仅当该 transcript 尚未断过），进入时句子已经通顺。
- 自动断句不可见地完成：`正在断句 N/M…` 准备界面，结束后进编辑器。

**非目标**
- 不改变手动「AI 断句」按钮（用户主动重断句仍入 undo）。
- 不做断句结果的人工审阅（自动断句是"准备"，失败回落原生断句 + 非阻断提示）。
- 不动 Core 分析器与 LLM 契约。

## 3. 决策（owner 拍板）

- **D-EAS-1 · LLM 硬门槛**：`ensureEnvironmentReady()` = 语音模型有效 + `LLMConfig.isConfigured`。任一缺失 → `.environmentSetup`，不进入项目列表/转写/编辑器。代价：本地纯转写用户需自带 Key，接受（隐私不受影响——只上传文字稿）。
- **D-EAS-2 · 自动断句不入 undo**：新增 `EditSession.applyWithoutUndo(_:)`（与 `refreshProposed` 同理：非用户编辑的直接修改）。用户首次 ⌘Z 不会撤销一个"自己没做过的动作"。手动「AI 断句」仍走 `apply`（可撤销）。
- **D-EAS-3 · 不允许跳过**：自动断句是流程必过步骤，无「跳过」按钮。**失败不硬阻塞**：断句出错回落原生断句 + 编辑器内非阻断提示（`aiError`），而不是卡在准备页。

## 4. 状态机

```
启动/init ──► .environmentSetup（模型+LLM 双就绪检查）──► .idle（项目列表）
                                                          │
点/建项目 start(url:) ──（再次守卫）──► 缓存命中？
        ├─ 已断句 ─────────────────────────────────► .editor
        ├─ 未断句（含全新转写）──► .preparing（自动断句 N/M…）──► .editor
```

- `.needsModel` 废弃，合并进 `.environmentSetup`（语义升级）。
- 新增 `.preparing`：转写完成/恢复后、进编辑器前，显示自动断句进度。

## 5. 关键实现点

### 5.1 环境准备页（EnvironmentSetupView，替代 SetupView）
- 分区① 语音模型：复用现 SetupView 的下载/选目录（`installProgress`、`downloadModel()`、`chooseModelFolder()`）。
- 分区② LLM：**直接复用 `AIServiceSettingsView`**（自带读取/保存/测试连接，零新代码）。
- 底部就绪态：两项 ✅ 后「进入工作流」可点。
- `pendingProjectURL`：在 `start(url:)` 守卫处记住用户点开的项目；就绪后 `开始(url:)` 继续（不丢意图）。

### 5.2 自动断句
- `segmentForEntry(url:)`：`.preparing` → `SemanticSegmenter.proposeSentenceStarts`（复用 `aiSegmentProgress` 进度）→ `applyWithoutUndo { $0.patch.sentenceStarts = ... }` → `.editor` + save + `rerunPauseAnalysis`。
- 幂等：`ProjectDocument.aiSegmentedAt: Date?`（可选字段，旧缓存解码 nil 不炸）。已断句项目重开直接 `.editor`，不重跑。

## 6. 文件改动清单

| 文件 | 改动 |
|---|---|
| `App/AppModel.swift` | Stage 增 `.environmentSetup`/`.preparing`；init 双就绪守卫；`ensureEnvironmentReady()`；`pendingProjectURL`；`start(url:)` 守卫 + 转写完成接 `segmentForEntry`；`segmentForEntry`/`finishEntry`；`downloadPreset` 的 `.needsModel` 分支更新 |
| `App/AirTrimApp.swift` | RootView 增两个 case；SetupView → EnvironmentSetupView（模型 + LLM 双分区）；新增 PreparingView |
| `App/ProjectStore.swift` | `ProjectDocument.aiSegmentedAt: Date?` + save 透传（保留已存值） |
| `Core/EditModel/EditSession.swift` | `applyWithoutUndo(_:)` |
| `Tests/.../EditSessionTests` | `applyWithoutUndo` 不入 history 的用例 |

## 7. 测试

- `applyWithoutUndo`：修改后 `history.isEmpty` 且 `canUndo == false`。
- ProjectStore `aiSegmentedAt`：编解码往返；旧缓存（无字段）解码 nil。
- 全量 `swift test` + `scripts/check-architecture.sh` 绿。

## 8. 落地顺序

- Phase 1：环境门槛（Stage + 守卫 + EnvironmentSetupView）。
- Phase 2：自动断句（applyWithoutUndo + aiSegmentedAt + .preparing + PreparingView）。
- 每阶段独立 build/test/arch 绿 + 手测。
