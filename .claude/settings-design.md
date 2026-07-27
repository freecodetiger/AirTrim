# AirTrim 设置界面设计方案

> 状态：设计稿（待评审）
> 背景：上一版 `Settings {}` + `TabView` 因 TextField 焦点 bug 五次修复失败后已全部删除。
> 当前 LLM 配置仅支持环境变量注入（wrapper 脚本），模型管理入口在 onboarding 页面后不可再访问。

---

## 1. 问题回顾：旧版为什么失败

旧版架构：

```
Settings { TabView { LLMSettingsView() / ModelSettingsView() } }
```

五个已知的 SwiftUI `Settings {}` 场景 bug，按出现顺序：

| 尝试 | 方案 | 失败原因 |
|---|---|---|
| 1 | `TextField` + `@State` | 在 Settings 窗口中无法获得键盘焦点——点击后光标一闪即消失 |
| 2 | `SecureField` + `@State` | Keychain 自动填充弹窗与 SecureField 焦点争抢，两者皆不可用 |
| 3 | `@ObservableObject` + `@Published` | 每次 key stroke 触发 `objectWillChange` → Settings 窗口重建视图树 → 焦点丢失 |
| 4 | `NSTextField` 桥接 (`NSViewRepresentable`) | 获得焦点成功，但焦点会"绑架"到 Settings 窗口——用户切回主窗口打字时，按键仍发往 Settings 的 NSTextField |
| 5 | `@Observable` (iOS 17+) + `@FocusState` | 官方新 API 在 macOS Settings 场景中仍不稳定，间歇性失效 |

**根因**：macOS 的 `Settings {}` 场景由 `_SettingsWindow` 私有类实现，其 `NSWindow` 层级与常规 `WindowGroup` 不同——`makeFirstResponder`、field editor 生命周期、窗口 resign/becomes key 时机都有差异。Apple 从未正式承诺 Settings 场景支持编辑型控件，macOS 14 仍未修复。

**教训**：
- 不要在 Settings 场景中放置需要键盘输入的控件。
- 不要为设置页引入第二个 `ObservableObject`（与 AppModel 形成"两种真相源"）。
- 不要用 `NSViewRepresentable` 桥接绕过 SwiftUI 焦点系统——副作用更大。

---

## 2. 架构选型：UI 容器方案对比

### 方案 A：Settings 场景（只读信息展示）

```
Settings { SettingsView() }
```

- 只放不可编辑内容的展示（模型状态、LLM 配置状态、磁盘占用），不放置任何 TextField/SecureField。
- 如需编辑，通过按钮打开独立的编辑窗口。

| 维度 | 评价 |
|---|---|
| macOS 原生感 | 最优——Cmd+, 自动绑定，独立设置窗口 |
| TextField 安全 | 安全——不放编辑控件 |
| 可编辑配置 | 不支持——需另开窗口 |

**适用场景**：只读仪表盘 + "打开编辑器"按钮。可以作为方案 E 的补充，但不应承载完整设置功能。

### 方案 B：独立 Settings 场景（维持旧架构，加 workaround）

```
Settings { TabView { ... } }
```

- 继续用 Settings 场景，但用 `NSPopover` / `NSTokenField` / WebView 等非标准方式接收输入。
- 本质是 hack 绕 bug，不可靠。

| 维度 | 评价 |
|---|---|
| macOS 原生感 | 优 |
| TextField 安全 | 危险——5 次失败的历史数据 |
| 实现复杂度 | 高——需要绕过 5 个已知 bug |

**结论**：不推荐。五次失败不应再有第六次。

### 方案 C：Sheet（模态表单）

```
.sheet(isPresented: $showSettings) { SettingsView() }
```

- 在主窗口上方弹出模态表单。
- 避免 Settings 场景的焦点 bug，因为 Sheet 运行在主窗口的视图层级中。

| 维度 | 评价 |
|---|---|
| macOS 原生感 | 中——macOS 不常用 sheet 做设置 |
| TextField 安全 | 安全——主窗口层级，焦点正常 |
| 阻塞编辑 | 是——模态表单会挡住主编辑器 |
| 空间 | 受限——sheet 默认尺寸较小 |

**适用场景**：轻量级设置（3-5 个控件）。不适合需要同时查看编辑器状态的场景。

### 方案 D：工具栏 Popover

```
.popover(isPresented: $showPopover) { SettingsPopover() }
```

- 点击工具栏按钮弹出 Popover，类似很多 macOS 专业工具（如 Xcode 的 Schemes 弹窗）。

| 维度 | 评价 |
|---|---|
| macOS 原生感 | 中——常见于工具型 app |
| TextField 安全 | 安全——Popover 在主窗口层级 |
| 空间 | 受限——适合信息展示 + 少数操作 |
| 持久性 | 低——失焦即消失，不适合长表单 |

**适用场景**：快速查看模型状态、下载进度、LLM 连接测试。不适合完整配置表单。

### 方案 E：独立 Window 场景（推荐）

```
Window("设置", id: "settings") {
    SettingsView().environmentObject(model)
}
.windowResizability(.contentSize)
```

- 用 `Window` 场景（macOS 14+）而非 `Settings`，获得完整的主窗口级焦点管理。
- 标题栏显示"设置"，视觉上与 Settings 窗口无异。
- 手动绑定 Cmd+, 快捷键（`.keyboardShortcut(",", modifiers: .command)`）。

| 维度 | 评价 |
|---|---|
| macOS 原生感 | 良——独立窗口，与 Settings 视觉无异 |
| TextField 安全 | 安全——常规 NSWindow，焦点完全正常 |
| 可编辑配置 | 完全支持 |
| Cmd+, | 需要手动绑定，稍增代码 |
| 多实例 | 需防重复打开（`.defaultSize` + 单例管理） |

**结论**：**推荐方案 E 作为主方案**。方案 D 可作为辅助（工具栏 Popover 快速查看模型状态），方案 A 可用于只读仪表盘补充。

---

## 3. 推荐方案：独立 Window + 可选工具栏 Popover

### 3.1 整体架构

```
AirTrimApp
├── WindowGroup("AirTrim")          ← 主编辑器窗口（现有）
│   └── 工具栏：设置按钮（齿轮图标）
│       └── 点击 → 打开设置窗口（方案 E）
│           OR 按住 Option → Popover 快速面板（方案 D）
│
└── Window("设置", id: "settings")   ← 独立设置窗口（新增）
    └── SettingsView()
        ├── LLMConfigSection        ← AI 服务配置
        │   ├── 状态指示（已配置/未配置）
        │   ├── TextField: API Key (SecureField)
        │   ├── TextField: Base URL
        │   ├── TextField: Model
        │   ├── "测试连接" 按钮
        │   └── 环境变量优先说明
        │
        └── ModelSection             ← 模型管理
            ├── 状态（已就绪/未安装/下载中）
            ├── 磁盘占用
            ├── 下载 / 校验修复 / 删除
            └── 位置信息 + 在访达中显示
```

### 3.2 为什么这是一个好的折衷

1. **彻底避开 Settings 场景的焦点 bug**——`Window` 场景使用常规 `NSWindow`，五类 bug 全部不存在。
2. **共享 AppModel**——不引入第二个 ObservableObject，状态只有一份。
3. **Cmd+, 仍可用**——手动绑定 keyboard shortcut。
4. **非阻塞**——设置窗口与编辑器窗口可同时可见，用户调整参数后立即看到效果。
5. **无跨窗口焦点绑架**——每个窗口有独立的 field editor，不会出现旧版 NSTextField 桥接的焦点漏洞。

---

## 4. 详细设计

### 4.1 窗口定义（AirTrimApp.swift 新增）

```swift
Window("设置", id: "settings") {
    SettingsView()
        .environmentObject(model)
}
.windowResizability(.contentSize)
.defaultSize(width: 520, height: 480)
.keyboardShortcut(",", modifiers: .command)  // Cmd+,
```

打开设置的动作（从工具栏按钮触发）：

```swift
// 工具栏按钮
Button {
    // 打开设置窗口（Window API 自动管理单例，重复调用同类 id 会激活已有窗口）
    if #available(macOS 14, *) {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
} label: {
    Label("设置", systemImage: "gearshape")
}
```

或者使用 SwiftUI 的 `openWindow` 环境值（macOS 14+）：

```swift
@Environment(\.openWindow) private var openWindow

Button {
    openWindow(id: "settings")
} label: {
    Label("设置", systemImage: "gearshape")
}
```

### 4.2 LLM 配置：持久化策略

**核心矛盾**：应用在运行时无法修改自己的环境变量（`setenv` 只影响子进程），而 wrapper 脚本注入的值在应用启动后已固定。

**解决**：引入**本地持久化**作为常规路径，环境变量作为**覆盖层**。

```
加载优先级：环境变量 > 本地持久化 > 硬编码默认值
保存目标：仅本地持久化（UserDefaults + Keychain）
```

具体实现：

- `API Key` → **Keychain**（`kSecClassGenericPassword`，service: `dev.airtrim.llm`）
- `Base URL` → **UserDefaults**（key: `llm.baseURL`）
- `Model` → **UserDefaults**（key: `llm.model`）

修改 `LLMConfig.load()`：

```swift
public static func load() -> LLMConfig? {
    let env = ProcessInfo.processInfo.environment
    
    // 1. 环境变量优先（wrapper 脚本用户）
    if let envKey = env[envAPIKey], !envKey.isEmpty {
        let urlString = env[envBaseURL] ?? defaultBaseURL
        guard let url = URL(string: urlString) else { return nil }
        return LLMConfig(baseURL: url,
                         model: env[envModel] ?? defaultModel,
                         apiKey: envKey)
    }
    
    // 2. 回退到本地持久化
    guard let storedKey = KeychainStore.load(), !storedKey.isEmpty else {
        return nil
    }
    let defaults = UserDefaults.standard
    let urlString = defaults.string(forKey: urlKey) ?? defaultBaseURL
    guard let url = URL(string: urlString) else { return nil }
    return LLMConfig(baseURL: url,
                     model: defaults.string(forKey: modelKey) ?? defaultModel,
                     apiKey: storedKey)
}
```

**这解决了"两种真相源"问题**：保存只写一个地方（Keychain + UserDefaults），加载时 env 透明覆盖。没有冲突，没有同步问题。

### 4.3 设置窗口布局

```
┌─────────────────────────────────────────────────┐
│  设置                                           │
├─────────────────────────────────────────────────┤
│                                                 │
│  AI 服务                                        │
│  ─────────────────────────────────────────────  │
│  状态     [● 已配置] 或 [○ 未配置]               │
│                                                 │
│  配置来源 [环境变量 AIRTRIM_LLM_*] 或 [应用内设置] │
│                                                 │
│  API Key  [••••••••••••••••]  (SecureField)    │
│  Base URL [https://api.deepseek.com            ] │
│  Model    [deepseek-chat                       ] │
│                                                 │
│  [测试连接]   [保存]                             │
│                                                 │
│  ℹ️ 设置环境变量 AIRTRIM_LLM_API_KEY 会覆盖      │
│    以上配置。启动脚本 airtrim 用户无需在此重复配置。 │
│                                                 │
│  ─────────────────────────────────────────────  │
│                                                 │
│  语音识别模型（本地，转写全程离线）                │
│  ─────────────────────────────────────────────  │
│  状态     [● 已就绪] 或 [○ 未安装]               │
│  类型     Whisper large-v3                      │
│  位置     ~/Library/Application Support/...     │
│  磁盘占用  3.1 GB                               │
│                                                 │
│  [在访达中显示] [校验修复] [下载模型…] [删除模型…]  │
│                                                 │
│  下载进度（仅下载中显示）：                        │
│  [████████████░░░░░░] 67% · 18/27 文件           │
│                                                 │
└─────────────────────────────────────────────────┘
```

- **不使用 `TabView`**——两个 Section 纵向排列在 `Form` 中，总高度约 480pt，无需 tab 切换。
- 因为 LLM 配置字段不多（3 个），模型管理信息紧凑，一页完全放得下，避免旧版 tab 切换引入的额外焦点问题。
- 如果日后内容增长（如字幕样式模板），再考虑用 `Picker` 或 `TabView` 做导航——届时 TextField 焦点问题已在独立 Window 中解决。

### 4.4 LLM 配置 Section 详细交互

#### 状态指示器

```
● 已配置（来源：环境变量）  → 显示当前 baseURL/model，API Key 显示掩码
○ 未配置                   → 引导用户填写或运行 wrapper 脚本
```

- "已配置"的判断：`LLMConfig.load() != nil`
- 来源显示：环境变量存在 → "环境变量"，否则 → "应用内设置"

#### TextField 行为

- **直接可用**：在独立 `Window` 场景中，`TextField` 和 `SecureField` 焦点完全正常，不存在旧 Settings 场景的五类 bug。
- **延迟保存**：用户编辑后点击"保存"才写入 Keychain + UserDefaults，不是每次 key stroke 都写（减少 Keychain 写入次数，避免触发 macOS 的 Keychain 访问确认弹窗）。
- **或自动保存**：使用 `.onSubmit` + 去抖 500ms 自动保存，与"保存"按钮并存。

```
用户编辑 TextField → @State 暂存 → 点击"保存"或失焦去抖 → 写入 Keychain/UserDefaults
```

#### 测试连接

- 发送一个最小化 API 请求（如 `models.list` 或简单 echo）验证配置有效性。
- 结果显示在按钮右侧："连接成功 · deepseek-chat" 或 "连接失败：HTTP 401 Unauthorized"
- 不阻塞 UI，结果用短暂 toast 或内联文本展示。

### 4.5 模型管理 Section 详细交互

#### 需要新增到 AppModel 的方法

当前 AppModel 已有：`modelFolder`、`installProgress`、`installError`、`downloadModel()`、`chooseModelFolder()`。

需要新增：

```swift
/// 模型目录磁盘占用（字节，nil = 未安装）
var modelDiskBytes: Int64? {
    guard let folder = modelFolder else { return nil }
    // 递归计算目录总大小
}

/// 在访达中显示模型目录
func revealModelInFinder() {
    guard let folder = modelFolder else { return }
    NSWorkspace.shared.activateFileViewerSelecting([folder])
}

/// 校验模型文件完整性并按清单修复（下载缺失/损坏文件）
func repairModel() {
    // 复用 ModelInstaller.plan() 检查文件完整性
    // 对损坏/缺失的文件重新下载
}

/// 删除应用自管目录下的模型（外部目录仅解除引用）
func deleteModel() {
    guard let folder = modelFolder else { return }
    let managed = Self.appSupportModels
    if folder.path.hasPrefix(managed.path) {
        try? FileManager.default.removeItem(at: folder)
    }
    modelFolder = Self.discoverModel()
    if modelFolder == nil { stage = .needsModel }
}
```

#### 按钮状态逻辑

| 模型状态 | 显示按钮 |
|---|---|
| 已就绪 | 在访达中显示 / 校验修复 / 删除模型… |
| 下载中 | 进度条 + 取消（可选，v1 先不做）|
| 下载失败 | 重试（从断点继续）/ 选择目录… |
| 未安装 | 下载模型（3.1 GB）/ 已有模型？选择目录… |

#### 校验修复流程

```
用户点击"校验修复"
→ 遍历 manifest.files，比对本地文件尺寸
→ 缺损列表展示（如有）→ 用户确认 → 下载缺失文件
→ 全部完好 → "模型完整，无需修复"
```

### 4.6 状态管理：单一真相源

```
设置窗口 (@State 暂存编辑值)
     │ 读取初始值
     ▼
AppModel (ObservableObject · 主窗口持有)
     │ LLMConfig.load()          ← 读取 Keychain + UserDefaults + env
     │ modelFolder / installProgress  ← 已有
     │ modelDiskBytes / repair / delete ← 新增方法
     │
     ▼
Keychain / UserDefaults / FileManager
```

**关键规则**：
1. **设置窗口不持有独立的设置模型**——所有状态读自 AppModel，所有变更通过 AppModel 方法写入。
2. **UserDefaults 只由 AppModel 写入**——设置窗口不直接操作 `UserDefaults.standard`。
3. **编辑暂存用 `@State`**——设置窗口内的 TextField 绑定到 `@State`，保存时才同步到 AppModel，避免每次 key stroke 都触发 Keychain 写入。
4. **AppModel 是唯一可观测的真相源**——设置窗口通过 `@EnvironmentObject` 读取，不创建第二份配置状态。

### 4.7 兼容性：环境变量用户不被干扰

**场景 1**：用户通过 `airtrim` wrapper 脚本启动，已设环境变量。

- 设置窗口显示"来源：环境变量"，API Key 显示掩码 (sk-****...)
- 编辑控件仍然可用，但保存时弹出提示："环境变量会覆盖此设置。如需使用应用内配置，请移除启动环境变量。"
- 用户不需要做任何事——LLM 功能继续正常工作。

**场景 2**：用户从 Finder/Dock 直接启动（无 env vars），但在设置中保存了配置。

- `LLMConfig.load()` 读不到环境变量 → 回退到 Keychain + UserDefaults → 正常加载。
- 用户完全不需要了解 wrapper 脚本的存在。
- 只需在设置中填写一次，后续启动自动恢复。

**场景 3**：用户既有环境变量，又在设置中修改了值。

- 环境变量优先——行为不变。
- 设置窗口的"来源"指示器告知用户当前生效的是环境变量。
- 不会出现"改了设置但不生效"的困惑。

---

## 5. 附加方案：工具栏 Popover 快速面板（可选）

作为方案 E 的补充，可以在工具栏齿轮按钮上支持两种交互：

- **单击** → 打开独立设置窗口（方案 E）
- **右键 / 长按** → 弹出 Popover 快速面板（方案 D）

Popover 内容（精简版，无 TextField）：

```
┌──────────────────────────────────┐
│  AI 服务                         │
│  ● 已配置 · deepseek-chat       │
│                                  │
│  模型                            │
│  ● 已就绪 · 3.1 GB              │
│                                  │
│  [打开完整设置…]                 │
│  [管理模型…]                     │
└──────────────────────────────────┘
```

这是一个 nice-to-have，v1 实现可以省略，直接单击齿轮按钮打开设置窗口即可。

---

## 6. 模块边界检查

对照 CLAUDE.md 和 ownership-map：

| 检查项 | 状态 |
|---|---|
| 设置 UI 在 `AirTrimApp/` | 通过——SettingsView 是 SwiftUI View |
| AirTrimCore 不 import SwiftUI | 通过——`LLMConfig.load()` 是纯 Foundation |
| 网络代码只在 LLMProvider/ | 通过——Keychain 操作在 LLMProvider/，测试连接走现有 `OpenAIChatClient` |
| 单一真相源 | 通过——AppModel 唯一持有配置状态，无第二份 |
| 不修改源媒体 | 通过——设置不涉及媒体文件 |

---

## 7. 实现步骤

### 第 1 步：LLM 持久化层（Core 侧，纯 Foundation）

- 恢复 `KeychainStore` 到 `Sources/AirTrimCore/LLMProvider/LLMConfig.swift`（或独立文件）
- 修改 `LLMConfig.load()` 加入 env → Keychain+UserDefaults 回退逻辑
- 新增 `LLMConfig.save(apiKey:baseURL:model:)` 方法
- 新增 `LLMConfig.delete()` 方法（清除本地配置）
- 新增 `LLMConfig.effectiveSource` 属性（返回 .environment 或 .stored）
- 单测覆盖：env 优先、回退、save/load roundtrip

### 第 2 步：AppModel 模型管理方法

- 新增 `modelDiskBytes` 计算属性
- 新增 `revealModelInFinder()` 方法
- 新增 `repairModel()` 方法（复用 `ModelInstaller.plan()` 检查 + 断点续传下载缺损文件）
- 新增 `deleteModel()` 方法（仅删除自管目录下的模型；外部模型解除引用）
- 新增 `isModelManaged` 判断属性（目录是否在 `appSupportModels` 下）

### 第 3 步：设置窗口 UI（App 侧）

- 创建 `Sources/AirTrimApp/SettingsView.swift`
- 实现 `LLMConfigSection`：状态指示 + 三个 TextField + 测试连接 + 保存 + env 来源提示
- 实现 `ModelSection`：状态 + 磁盘占用 + 四个按钮 + 进度条
- 无 TabView——两个 Section 纵向 Form 布局

### 第 4 步：窗口注册与工具栏入口

- 在 `AirTrimApp.swift` 添加 `Window("设置", id: "settings")` 场景
- 在编辑器工具栏添加齿轮按钮
- 验证 Cmd+, 快捷键

### 第 5 步：验证

- `swift build` + `swift test` + `scripts/check-architecture.sh` 三绿
- 手动测试：
  - 从 Finder 启动 → 设置窗口编辑 API Key → 保存 → AI 断句可用
  - 从 wrapper 启动 → 设置窗口显示"环境变量"来源 → AI 断句仍可用
  - 模型下载/暂停/校验修复/删除全流程
  - TextField 焦点正常，无旧版五类 bug 复发
