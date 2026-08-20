# M4 设计 · 项目管理页

> 状态：设计稿（2026-07-29，分支 feature/project-management）。
> 范围：进入 App 首先展示「项目管理页」，用户从项目列表选择/新建项目后再进
> 编辑器。只动 App 层路由 + ProjectStore 只读扩展，不触碰 Core 各模块；
> 存储格式与指纹规则完全不变（D7 决策沿用，向后兼容）。

## 1. 背景与现状

- 当前单 WindowGroup + `AppModel.stage` 状态机路由：`.environmentSetup` → 环境准备页、
  `.idle` → ImportView、`.transcribing` → 进度页、`.editor` → 编辑器、
  `.failed` → 错误页。
- ProjectStore 以指纹（SHA256(path|size|mtime)）为键，把转写结果 + 修订补丁
  持久化为 JSON 到 `~/Library/Application Support/AirTrim/Projects/<指纹>.json`；
  同级 `last-opened.txt` 记录最近一个项目路径——**只支持"继续上次"单项目**，
  历史项目缓存其实都在盘上，只是没有入口。
- 启动时 `AppModel.init()` 读 `lastOpenedURL()` 自动恢复上次项目直接进编辑器，
  用户想换素材要先手动关闭视频。

## 2. 关键设计决策

### D-M4-1 · 首屏改为项目管理页（.idle 的语义升级）

`.idle` 状态由新的 `ProjectHomeView` 取代 ImportView，成为模型就绪后的默认
首屏。**取消启动时自动恢复上次项目的行为**——多项目场景下"启动即进编辑器"
反而抢走选择权；上次项目降级为项目管理页的"继续上次"**置顶卡片**，一次点击
即达，老用户成本仅 +1 击。`AIRTRIM_AUTOLOAD` 环境变量自动加载**保留**
（自动化冒烟/回归钩子，不走首屏）。环境准备门槛（`.environmentSetup` → 环境准备页：语音模型 + LLM 双就绪，D-EAS-1）
仍然优先于一切，顺序不可改。

### D-M4-2 · 数据层最小扩展（ProjectStore 只加只读扫描 + 删除）

```swift
struct ProjectMetadata: Identifiable {
    let fingerprint: String     // 即文件名主干，也是 id
    let sourcePath: String
    let fileName: String        // sourcePath 末段（列表主标题）
    let savedAt: Date           // 最后编辑时间（排序键，倒序）
    let projectSizeBytes: Int64 // 缓存 JSON 大小
    let sourceExists: Bool      // 源文件还在不在（灰态标记）
}

// ProjectStore 新增（枚举静态方法，与现有 API 同风格）
static func listAllProjects() -> [ProjectMetadata]   // 扫 Projects/ 目录解码
static func deleteProject(fingerprint: String)       // 删单个缓存 JSON
```

`listAllProjects()` 扫描 `Projects/` 目录逐个解码 JSON，取 sourcePath /
savedAt，文件大小走 FileManager 属性。项目 JSON 约 100KB、量级预期几十个，
**v1 容忍全量解码**（见风险表）；解码失败的文件跳过不入列表。
存储格式与指纹规则**完全不变**——老缓存无需迁移即出现在列表里。

### D-M4-3 · 单一真相源：列表状态归 AppModel，Store 只管 I/O

`AppModel` 新增 `@Published var projects: [ProjectMetadata]`、`loadProjects()`、
`deleteProjectCache(fingerprint:)`；ProjectStore 保持无状态枚举，**不新建第二个
ObservableObject**（避免列表与 stage 两处状态各自为政）。项目管理页就在主窗口
`.idle` 状态内渲染，**不使用独立 NSWindow**（区别于设置窗口——设置是跨状态
的全局面板，项目管理是主流程的一站）。

### D-M4-4 · 编辑器返回入口

编辑器工具栏 + 文件菜单提供"关闭视频/返回项目"（复用现有 `closeVideo()`，
它本就把 stage 归位 `.idle`）；返回时调 `loadProjects()` 刷新列表，刚保存的
项目按 savedAt 自然置顶。

## 3. 功能范围

| 优先级 | 内容 |
|---|---|
| P0 | 项目列表展示（文件名、源路径、最后编辑时间、缓存大小、源文件是否存在标记）；点击打开项目（走现有 `start(url:)` 缓存秒开）；新建项目入口（保留拖拽导入 + "打开视频…"按钮，置于页面顶部区域）；"继续上次"置顶卡片 |
| P1 | 右键菜单（打开 / 在访达中显示源文件 / 删除项目缓存——需确认弹窗）；源文件已丢失的项目灰态显示 + 提示；空列表空状态引导（一句话 + 指向顶部导入区） |
| P2（本期不做，仅列出） | 搜索过滤、批量删除、项目重命名 |

## 4. 流程

```
启动 ─▶ 无模型? ──是──▶ SetupView（下载引导，不变）
          │否
          ▼
    ProjectHomeView (.idle)
      ├ 拖入/打开新视频 ──▶ start(url:) ─▶ .transcribing ─▶ .editor
      ├ 点击列表项目   ──▶ start(url:) ─▶ 缓存命中秒开 .editor
      │                        └ 指纹失效 ─▶ 提示后 forceRetranscribe 重转
      └ 右键删除缓存   ──▶ deleteProjectCache ─▶ loadProjects() 刷新
    .editor ──"关闭视频/返回项目"（closeVideo()）──▶ 回 .idle + 刷新列表
```

打开路径**全部复用 `start(url:)`**：缓存命中/未命中/重转的分支逻辑一行不改，
项目管理页只是给这个入口多接了一个来源。

## 5. 错误处理

- **源文件被删除/移动**：列表项标灰（`sourceExists == false`）+ 次要文字提示
  "源文件已丢失"；点击不进转写而是弹说明，右键仍允许删除缓存清理残留。
- **指纹失效**（源文件被修改，路径仍在但 size/mtime 变了）：`start(url:)`
  缓存不命中，提示"源文件已变动，需重新转写"后走现有 `forceRetranscribe`
  流程；旧缓存 JSON 在重转成功保存时被新指纹文件取代，孤儿文件可手动删除。
- **Projects/ 目录扫描失败**（目录不存在/无权限/单文件损坏）：降级为空列表
  或跳过坏文件，**绝不崩溃**——项目管理页兜底永远可用作导入页。

## 6. 界面（ProjectHomeView）

```
┌────────────────────────────────────────────────┐
│  ┌──────────────────────────────────────────┐  │
│  │   ⬇ 拖入视频文件，或  [ 打开视频… ]        │  │  ← 导入区（顶部）
│  └──────────────────────────────────────────┘  │
│  继续上次                                       │
│  ┌ 🎬 koubo-01.mov      昨天 22:41 · 96 KB ──┐ │  ← 置顶卡片
│  项目（按最后编辑倒序）                          │
│  ┌ 🎬 vlog-0715.mov     7-15 · 88 KB ────────┐ │
│  │    ~/Movies/vlog-0715.mov                 │ │
│  ┌ 🎬 intro.mov ⚠源文件已丢失  7-02 · 91 KB ─┐ │  ← 灰态行
│  └───────────────────────────────────────────┘ │
└────────────────────────────────────────────────┘
```

- 列表行：图标 + 文件名（主标题）+ 源路径（次要文字）+ 时间与缓存大小 +
  灰态/丢失标记；单击整行打开，右键出 P1 菜单。
- 交互流程：点击 → `start(url:)` → 缓存命中直接 `.editor` 秒开，否则
  `.transcribing` 进度页；删除缓存需确认，成功后列表就地刷新。

## 7. 验证标准

三绿标准：`swift build` + `swift test` + `scripts/check-architecture.sh`。

手动测试清单：

- 首启无模型：先见 SetupView（顺序不可改），装完模型落到项目管理页；
- 模型就绪后启动：首屏为项目管理页，**不再**自动进编辑器；
- "继续上次"置顶卡片指向 last-opened 项目，点击秒开；
- 点击历史项目缓存秒开；源文件被改动的项目提示后重转；
- 右键删除缓存 → 确认 → 列表刷新，该项消失；
- 移走源文件后重启：对应项目灰态 + 提示，点击不崩溃；
- 编辑器"关闭视频/返回项目"回到列表，刚编辑的项目排首位；
- `AIRTRIM_AUTOLOAD` 冒烟钩子仍直达编辑器。

## 8. 风险

| 风险 | 对策 |
|---|---|
| 列表扫描全量解码 JSON（单个约 100KB）项目多时变慢 | v1 容忍全量解码（几十项 × 100KB 毫秒级，换实现简单）；若实测超 100ms 再改为只解码头部元数据（JSONSerialization 取 sourcePath/savedAt 两键）或独立 sidecar 索引 |
| 取消启动自动恢复，打破老用户"开即用"习惯 | "继续上次"置顶卡片一击直达；发布说明明确提示行为变更 |
| last-opened.txt 兼容 | 读写逻辑不动，仅消费方从"启动自动加载"改为"置顶卡片数据源"；旧版写的文件新版直接可用，反向亦然 |

## 9. 明确不做（防蔓延）

搜索过滤 · 批量删除 · 项目重命名（均 P2）· 项目缩略图/封面帧 ·
多窗口多项目并行编辑 · 项目导出/迁移工具。
