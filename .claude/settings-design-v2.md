# AirTrim 设置界面 v2 — 分级设置 + 语音模型管理

> 状态：设计稿（待评审）
> 前置文档：`.claude/settings-design.md`（已实现 · Window 场景 / TextField 焦点问题已修复）
> 本设计聚焦：分级设置结构 + 语音模型管理独立界面

---

## 1. 现状问题

### 1.1 模型发现只取第一个

`AppModel.discoverModel()` 扫描 `~/Library/Application Support/AirTrim/Models/`，找到第一个含 `*.mlmodelc` 的目录即停止。用户如果装了多个模型（如 tiny + large-v3），应用只能"看到"一个。

```swift
// AppModel.swift:80-91 — 当前实现
static func discoverModel() -> URL? {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(at: appSupportModels, ...) 
    else { return nil }
    return entries
        .map { $0.resolvingSymlinksInPath() }
        .first { url in                             // ← 只取第一个
            (try? fm.contentsOfDirectory(at: url, ...))?
                .contains { $0.pathExtension == "mlmodelc" } ?? false
        }
}
```

### 1.2 没有模型清单

当前只有一个 `ModelManifest.largeV3`（27 个文件，~3.1 GB），没有其他档位可选。WhisperKit 生态中存在 tiny (~150MB)、base (~300MB)、small (~900MB)、medium (~2GB)、large-v3-turbo (~1.2GB) 等多个档位，但应用完全没有暴露这些选项。

### 1.3 外部模型校验弱

`chooseModelFolder()` 允许用户选任意目录，唯一校验是"目录里有没有 `.mlmodelc`"。没有检查：
- `config.json` / `generation_config.json` 是否存在
- `tokenizer/` 子目录是否存在（缺失时会触发 WhisperKit 网络回退，违反离线原则）
- 三组件（AudioEncoder / MelSpectrogram / TextDecoder）是否完整

### 1.4 设置页扁平

当前设置窗口是 AI 服务 + 模型管理两个 Section 纵向排列，没有层级结构。信息密度尚可，但模型管理一旦扩展到多模型，单页 Form 就会溢出。

---

## 2. 设计方案

### 2.1 整体架构：侧边栏分级导航

```
┌──────────────────────────────────────────────────────────┐
│  设置                                                    │
├──────────────┬───────────────────────────────────────────┤
│              │                                           │
│  ◉ AI 服务   │  右侧内容区（随左侧选中项切换）              │
│              │                                           │
│  ○ 语音模型  │  - AI 服务：API Key / Base URL / Model     │
│              │  - 语音模型：已安装列表 + 获取新模型         │
│              │                                           │
├──────────────┴───────────────────────────────────────────┤
│  窗口尺寸：580 × 440（比当前 520×480 略宽，容纳侧边栏）       │
└──────────────────────────────────────────────────────────┘
```

- **侧边栏**：`List(selection:)` + `.listStyle(.sidebar)`，两个导航项（后续可扩展字幕样式等）
- **内容区**：根据选中项切换视图
- **不用 `TabView`**：侧边栏在视觉上更接近 macOS 原生设置（参考系统设置.app），且避免了旧版 TabView 的焦点 bug

#### 为什么不分两个窗口

语音模型管理在设置窗口内作为独立页面即可。原因是：(1) 用户心智模型是"设置 = 所有配置的入口"；(2) 模型下载进度在设置窗口内可见，不阻塞主编辑器；(3) 无需管理多窗口生命周期。

### 2.2 AI 服务页（保持现有逻辑，微调）

与当前 `SettingsView` 的 `llmSection` 基本一致，只做细节调整：

```
AI 服务
─────────────────────────────────────────────
● 已配置 / ○ 未配置

API Key   [sk-…                    ]
Base URL  [https://api.deepseek.com]
模型      [deepseek-chat           ]

[测试连接]  [保存]

ℹ️ 配置保存在本地 JSON 文件，绝不上传。
```

变化：
- 移除旧的"来源：环境变量"提示（已删除环境变量依赖）
- `loadCurrentConfig()` 只从 JSON 文件读取

### 2.3 语音模型页（全新设计）

这是本次设计的核心。分为三个区域：

```
┌──────────────────────────────────────────────────────────┐
│  语音模型管理                                             │
│                                                          │
│  ── 已安装的模型 ─────────────────────────────────────── │
│                                                          │
│  ┌──────────────────────────────────────────────────────┐│
│  │ ● Whisper large-v3                   3.1 GB  已就绪  ││
│  │   位置：~/Library/Application Support/AirTrim/       ││
│  │         Models/openai_whisper-large-v3               ││
│  │   [在访达中显示] [校验修复] [删除…]                  ││
│  └──────────────────────────────────────────────────────┘│
│                                                          │
│  ┌──────────────────────────────────────────────────────┐│
│  │ ○ 未安装任何模型                                     ││
│  │   下载下方推荐模型或选择本地已有模型目录。              ││
│  └──────────────────────────────────────────────────────┘│
│                                                          │
│  ── 获取新模型 ──────────────────────────────────────── │
│  选择适合你需求的档位：                                    │
│                                                          │
│  ┌────────────┐ ┌────────────┐ ┌──────────────────────┐  │
│  │ 🏃 轻量    │ │ ⚖ 均衡    │ │ 🎯 高精度  ⭐ 推荐    │  │
│  │            │ │            │ │                      │  │
│  │ ~150 MB    │ │ ~1.2 GB    │ │ ~3.1 GB              │  │
│  │ tiny       │ │ turbo      │ │ large-v3             │  │
│  │ 速度最快   │ │ 速度与精度 │ │ 中文识别精度最高      │  │
│  │ 精度一般   │ │ 兼顾       │ │ 适合口播精剪          │  │
│  │            │ │            │ │                      │  │
│  │ [获取]     │ │ [获取]     │ │ [已安装 ✓]           │  │
│  └────────────┘ └────────────┘ └──────────────────────┘  │
│                                                          │
│  ── 手动添加 ────────────────────────────────────────── │
│  [选择本地模型目录…]                                      │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

#### 2.3.1 已安装模型列表

核心改进：**自动发现所有已安装的模型**，不再只取第一个。

新增 `AppModel.discoverInstalledModels() -> [InstalledModel]`：

```swift
struct InstalledModel: Identifiable {
    let id: String              // 目录名，如 "openai_whisper-large-v3"
    let name: String            // 显示名，如 "Whisper large-v3"
    let directory: URL
    let sizeBytes: Int64        // 磁盘占用
    let isValid: Bool           // 三组件 + tokenizer + config 是否齐全
    let isManaged: Bool         // 是否在 appSupportModels 下
}
```

发现逻辑：
1. 扫描 `appSupportModels` 目录下所有子目录
2. 对每个子目录做**结构校验**（见 2.3.2）
3. 返回所有校验通过 + 校验不通过但含 `.mlmodelc` 的模型
4. 外部模型（通过 `chooseModelFolder` 添加的）也纳入列表

每个已安装模型的可用操作：

| 状态 | 操作 |
|---|---|
| 有效 + 自管 | 在访达中显示 / 校验修复 / 删除… |
| 有效 + 外部 | 在访达中显示 / 校验修复 / 移除引用 |
| 无效（缺文件） | 校验修复 / 删除… |
| 下载中 | 进度条 + 取消 |

#### 2.3.2 模型结构校验

新增 `ModelValidator`（`AirTrimInstaller/`，纯 Foundation）：

```swift
struct ModelValidator {
    /// 校验一个目录是否是有效的 WhisperKit CoreML 模型。
    /// 返回缺失/损坏的文件列表；空列表 = 有效。
    static func validate(at url: URL, against manifest: ModelManifest) -> [String]
}
```

校验规则：
- 必须包含 `config.json` + `generation_config.json`
- 必须包含三组件 `*.mlmodelc`：`AudioEncoder` / `MelSpectrogram` / `TextDecoder`
- 推荐包含 `tokenizer/` 子目录（缺失时标记为 warning，不 block）
- 文件尺寸与 manifest 一致（可选，仅用于"校验修复"按钮）

这使得"已安装模型"列表可以区分：
- **完整有效** → 绿色对号
- **基本可用**（三组件齐全但 tokenizer 缺失）→ 黄色警告
- **损坏/不完整** → 红色叉号 + 提示修复

#### 2.3.3 推荐模型档位

新增 `ModelPreset` 定义可下载的预设模型。

**数据层**：在 `AirTrimInstaller` 中新增 manifest 定义。

当前只有 `largeV3`（3.1 GB）。v1 建议至少增加两个常用档位：

| 档位 | 名称 | 大小 | 适用场景 |
|---|---|---|---|
| 🏃 轻量 | `openai_whisper-tiny` | ~150 MB | 快速草剪 · 低精度 · 磁盘紧张 |
| ⚖ 均衡 | `openai_whisper-large-v3-turbo` | ~1.2 GB | 日常剪辑 · 精度与速度兼顾 |
| 🎯 高精度 ⭐ | `openai_whisper-large-v3` | ~3.1 GB | 口播精剪 · 中文最高精度（推荐） |

三个档位以**卡片形式**横向排列，每个卡片包含：
- 档位图标 + 名称
- 模型代号
- 磁盘大小
- 一句话场景描述
- 操作按钮：`[获取]`（未安装）/ `[已安装 ✓]`（已安装，灰色不可点）

**注意**：tiny 和 turbo 的 CoreML 编译版需要确认 argmax/WhisperKit 是否提供预编译包。若不提供，v1 可以只放 large-v3（一个卡片）+ 两个"即将推出"占位卡片。这保持了诚实——不编造不存在的下载链接。

#### 2.3.4 下载流程

点击 `[获取]` 按钮：

```
1. 创建 ModelInstaller(manifest: preset.manifest, destination: appSupportModels)
2. 调用 installer.install(onProgress:)
3. 进度在卡片上显示（替换 [获取] 按钮为进度条）
4. 完成后自动加入"已安装模型"列表
```

下载进度在对应卡片内展示（非全局模态框），用户可同时看到其他模型的信息。如果当前已有模型在下载，其他模型的 `[获取]` 按钮置灰。

#### 2.3.5 手动添加

保留现有 `chooseModelFolder()` 功能，但在选择后增加**结构校验**：

```
用户选择目录
    → ModelValidator.validate(at: against: .largeV3)
    → 通过：加入已安装列表，标记为"外部"
    → 不通过：弹窗说明缺少什么文件，用户确认是否仍然使用
        ├── 仍然使用 → 加入列表，标记为"不完整"
        └── 取消 → 回到设置页
```

### 2.4 状态管理

不引入第二个 ObservableObject。所有模型状态通过 `AppModel` 暴露：

```
AppModel（单一真相源）
├── installedModels: [InstalledModel]      // 已发现的所有模型（替代单一 modelFolder）
├── activeModel: InstalledModel?           // 当前转写使用的模型
├── installProgress: InstallProgress?      // 下载进度（保持现有）
├── installError: String?                  // 下载错误（保持现有）
├── presets: [ModelPreset]                 // 可下载的推荐模型
│
├── discoverInstalledModels()              // 扫描已安装
├── downloadPreset(_ preset: ModelPreset)  // 下载指定预设
├── setActiveModel(_ model: InstalledModel)// 切换活跃模型
├── validateModel(at: URL) -> ValidationResult
├── repairModel(_ model: InstalledModel)  // 校验修复
├── deleteModel(_ model: InstalledModel)   // 删除
└── chooseModelFolder()                    // 手动添加（保持现有）
```

### 2.5 交互细节

#### 活跃模型切换

"已安装模型"列表中，当前**正在使用**的模型显示 `●` 实心圆 + "使用中"标签。点击另一个已安装模型 → 弹出确认："切换模型后需重新转写当前视频。是否继续？" → 切换 → 标记活跃。

这样做的好处：(1) 用户可以在不同档位之间切换（轻量用于快速草剪，高精度用于最终导出）；(2) 切换行为是显式的，不会意外触发重转写。

#### 删除确认

删除已安装模型时区分：
- **活跃模型** → 警告："这是当前正在使用的模型。删除后将无法转写。"
- **唯一模型** → 警告："这是唯一已安装的模型。删除后需重新下载或选择本地模型。"
- **非活跃模型** → 普通确认

#### 进度显示

下载中在对应卡片内显示进度条 + 文件名，不阻塞其他模型的信息查看。

---

## 3. 实现步骤

### 第 1 步：模型发现与校验框架（Core/Installer 层，纯 Foundation）

1. 新增 `InstalledModel` 结构体 → `Sources/AirTrimCore/` 或 `AirTrimInstaller/`
2. 新增 `ModelValidator.validate(at:against:) → ValidationResult` → `AirTrimInstaller/`
3. 新增 `AppModel.discoverInstalledModels() → [InstalledModel]`
4. 新增 `AppModel.activeModel: InstalledModel?` 属性
5. 删除旧的 `modelFolder: URL?`（或保留为 activeModel 的派生属性用于向后兼容）

### 第 2 步：Manifest 预设系统

1. 新增 `ModelPreset` 结构体 → `AirTrimInstaller/`
2. 新增 `ModelManifest.tiny` / `.largeV3Turbo`（如果能拿到 CoreML 编译版 URL）
3. 若暂无其他档位的编译版，只保留 large-v3 + 两个"即将推出"占位

### 第 3 步：设置窗口 UI 改造

1. 重构 `SettingsView` → 侧边栏 + 内容区布局
2. 创建 `AIServiceSettingsView`（从当前 `llmSection` 提取）
3. 创建 `ModelManagementView`（全新）：
   - `InstalledModelsSection`：模型列表 + 操作按钮
   - `PresetCardsSection`：档位卡片 + 下载按钮
   - `ManualAddSection`：选择目录按钮
4. 调整 `SettingsWindowManager` 窗口尺寸：580×440（min 520×400）

### 第 4 步：SetupView 集成

1. 首次启动的下载引导页保持 large-v3 默认推荐
2. 在 SetupView 增加"查看更多模型档位 →"链接，点击跳转设置窗口的语音模型页

### 第 5 步：验证

- `swift build` + `swift test` + `scripts/check-architecture.sh` 三绿
- 手动测试：
  - 自动发现已安装模型
  - 多模型场景（large-v3 + tiny 共存）
  - 下载 tiny / turbo / large-v3
  - 活跃模型切换 + 重转写
  - 损坏模型检测 + 修复
  - 外部模型手动添加 + 校验

---

## 4. 模块边界检查

| 检查项 | 状态 |
|---|---|
| Settings UI 在 `AirTrimApp/` | 通过 |
| `AirTrimCore` 不 import SwiftUI | 通过 — `InstalledModel` 是纯值类型 |
| `ModelValidator` 在 `AirTrimInstaller/` | 通过 — 纯 Foundation |
| 网络代码仅在 `AirTrimInstaller/` | 通过 — `ModelInstaller` 已在此 |
| `AirTrimCore` 不 import SwiftUI/AppKit | 通过 |
| 单一真相源 | 通过 — `AppModel` 持有 `installedModels` |
| 不修改源媒体 | 通过 |

---

## 5. 风险与后续

| 风险 | 缓解 |
|---|---|
| tiny / turbo 的 CoreML 编译版可能不存在 | v1 只放 large-v3（已确认可用），其余占位"即将推出" |
| 多模型切换导致 WhisperKit 重新加载（耗内存） | Swift 6 `Sendable` + actor 隔离；切换时显式释放旧模型 |
| 多模型共占用大量磁盘 | 磁盘占用在 UI 中透明展示；档位卡片包含大小信息 |

**后续产品能力**（不在本设计范围）：
- 模型自动更新（检测 manifest 版本变化）
- 自定义模型导入（用户自己的微调模型）
- 模型性能 bench（同一视频用不同模型转写，对比 CER）
