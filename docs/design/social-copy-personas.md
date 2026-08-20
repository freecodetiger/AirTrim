# M5 设计 · 抖音文案多人设化（Social Copy Personas）

> 状态：设计稿（2026-08-20，分支 feat/social-copy-personas）。
> 范围：把「抖音文案」从写死的单一人设（程序员/技术成长）升级为「人设模板
> 系统」——6 个预设赛道（通用/技术成长/职场/美妆/健身/育儿）+ 面板选择 +
> 持久化。只动 `LLMProvider/`（prompt 组合）与 `AirTrimApp/`（UI），不触碰
> MediaEngine / SpeechPipeline / EditModel。输出契约（【】分区）保持不变。
> 人设模板源：`docs/design/personas/{slug}.md`（由外部 prompt 生成器产出，
> 见文末字段规范），经转换内嵌为 Swift 值类型。

## 1. 背景与现状

- `SocialCopywriter.swift` 只有**一个** `static let systemPrompt`，整段写死为
  「程序员/技术成长」：目标人群（计算机学生 / 1–3 年开发者 / AI 焦虑者）、
  标题五型（共鸣/反差/趋势/经验/极简）、文案五版、标签三类全是程序员语境。
- 输入只有剪辑后的有效字幕文字稿；输出为一段长 markdown（10 标题 + 5 文案 +
  15 标签 + 最终推荐），`SocialCopyPanel.parseSections` 按【】区块解析渲染。
- **问题**：
  1. 人设写死——美妆/健身/育儿等口播内容生成结果严重违和；
  2. 任务与人设交织在同一段 prompt 里，无法单独替换人设；
  3. 单次输出过载，10 标题 + 5 文案超出 LLM 长输出质量拐点，用户阅读负担大；
  4. 无记忆——每次生成都是同一人设，无法按赛道切换。

## 2. 目标与非目标

**目标（本轮）**
- 6 个预设人设模板，选择即换调性，模板可低成本扩展（新增 = 加一个 md + 一个值）。
- 面板顶部人设选择器；选择**持久化**（下次打开仍是上次的人设）。
- 本地关键词粗扫文字稿，给出「推荐人设」默认值（零 LLM 成本，可覆盖）。
- 输出精简到「每组 3 个精选」，仍走【】解析。
- 架构：人设 = 纯值类型（可单测）；网络调用仍只在 `LLMProvider/`。

**非目标（本轮不做）**
- 目标导向（涨粉/互动/带货）第三轴 —— P1
- 封面字生成（抖音 CTR 第一杠杆）—— P1
- 分块「换一批」（标题/文案/标签独立重生成）—— P1
- 平台适配（小红书 / B 站 / 视频号）—— P1
- 热门标签池（LLM 编的标签常不在热搜池，需数据源）—— P2
- 财经 / 医疗赛道（合规红线更重，框架跑通后再补）—— 后补

## 3. 关键设计决策

### D-SCP-1 · 人设 = 纯值类型 + 内嵌模板表

`SocialCopyPersona` 放在 `LLMProvider/`（Core 内，不依赖 AVFoundation）：

```swift
public struct SocialCopyPersona: Sendable, Identifiable {
    public let id: String            // slug：tech-growth 等（md 标题里的 slug）
    public let displayName: String   // 「技术成长派」
    public let description: String   // 选择器副标题（一句话）
    // —— 以下字段与 md 各节一一对应 ——
    public let audience: String      // 受众画像
    public let valueTypes: String    // 内容价值类型
    public let titleHooks: String    // 标题钩子（类型 × 范例）
    public let copyTones: String     // 文案语气（角度 × 范例）
    public let tags: String          // 标签方向（精准/泛流量/身份）
    public let platformAnchor: String // 抖音平台锚点（3 秒钩子/口播风格/封面字）
    public let redLines: String      // 红线（禁止 + 反例）
    public let tasteCheck: String    // 语感判据（自测句）
}

extension SocialCopyPersona {
    public static let all: [SocialCopyPersona] = [
        .general, .techGrowth, .career, .beauty, .fitness, .parenting,
    ]
}
```

- **md 是 authoring 源，Swift 字面量由 md 手写转换**（仅 6 份，不引入代码生成）。
  md 保留在仓库 `docs/design/personas/`，作为文档与后续再生成的基础。
- 为什么存结构化字段而非整段 prompt 字符串：字段与 md 契约一一对应、可按节
  单测、为 P1 的「分块换一批」与「目标轴」留好接缝。
- 为什么内嵌而非运行时读文件：零 I/O、随版本分发、可单测；编辑走 md → 改值。

### D-SCP-2 · Prompt 组合 = 共享任务 prompt + 人设块

把现有 `systemPrompt` 拆成两层，`generate` 时拼装：

```
systemPrompt(for persona) = taskPrompt + "\n\n" + persona.promptBlock
```

- **taskPrompt（共享，不随人设变）**：任务目标（「把口播字幕转成适合抖音发布的
  标题 + 文案 + 标签」）、五段流程、输出格式契约（【内容定位】【标题方案】
  【发布文案】【标签】【最终推荐】）、全局约束（标题 15–25 字、文案 50–150 字、
  不制造虚假焦虑、不做低质标题党、每组 3 个精选）。
- **persona.promptBlock（人设专属）**：把 8 个字段渲染成指令块，固定句式开头
  「你是一名深耕『<displayName>』赛道的内容运营专家，面向 <受众一句话>…」，
  然后依次给出受众画像 / 价值类型 / 标题钩子（每类出一个方案）/ 文案语气 /
  标签方向 / 平台锚点 / 红线 / 语感判据。

- 关键约束：**人设块只定义「表达方式」，不重复任务流程、不改输出数量、不改【】结构**。
  红线合并进指令的「禁止」区，但保留赛道特有措辞（如育儿「不贩卖年龄焦虑」）。

### D-SCP-3 · 输出契约不变 + 数量精简

- 面板 `parseSections` 按【】解析——**解析器一行不改**，输出结构保持。
- 数量从「10 标题 + 5 文案 + 15 标签」降为「每组 3 个精选」：标题 3、文案 3、
  标签 3 类各 3 个。理由：人设选择场景下用户要的是「挑最对味的那条」，且 LLM
  长输出必然前优后劣。最终推荐保留。
- 这是 taskPrompt 的改动，与人设正交，但随本轮一并落地（否则 6 人设 × 大输出
  阅读负担更重）。

### D-SCP-4 · UI：面板顶部人设 Picker + 持久化 + 推荐

- `SocialCopyPanel` header 左侧（「抖音文案」标题旁）加一个 `Picker`（menu 式，
  `.menu`），列出 6 个 persona，显示 `displayName`，副标题用 `description`。
- 选择写入 `UserDefaults`（key `socialCopyPersona`，存 slug），`AppModel` 持有
  `socialCopyPersona: SocialCopyPersona`（默认 `.general`）。持久化归属 App 层，
  **不进 Core**。
- **推荐默认**：`AppModel.suggestedPersona(for transcript)` 用本地关键词表
  （slug → 5~10 个词，如 tech-growth: 代码/编程/程序员/架构/算法；beauty:
  护肤/底妆/卡粉/成分…）粗扫文字稿前 ~500 字。命中则：
  - 首次打开面板且无已保存人设时，作为初始选择；
  - 始终在 Picker 命中项上标「推荐」角标（不覆盖用户已保存的选择）。
  - 零 LLM 成本；猜错可一键换。

### D-SCP-5 · 生成入口带人设参数

```swift
public func generate(from text: String,
                     persona: SocialCopyPersona) async throws -> String
```

`AppModel.requestSocialCopy()` 改为用 `model.socialCopyPersona` 传入。
`model.showSocialPanel` / result / error / running 状态机与面板渲染逻辑不变。

## 4. 数据流

```
Panel Picker ──► model.socialCopyPersona（UserDefaults 持久化 slug）
                      │
                      ▼
requestSocialCopy ──► SocialCopywriter.generate(text, persona)
                      │   systemPrompt = taskPrompt + persona.promptBlock
                      ▼
                  LLMProvider（唯一联网点）→ 长 md
                      ▼
SocialCopyPanel.parseSections（【】分区，不变）→ 区块渲染 / 一键复制
```

## 5. 架构边界

- ✅ 网络调用只在 `LLMProvider/`（脚本守卫不变）。
- ✅ `SocialCopyPersona` 纯值类型、`Sendable`、可单测，无 UI 依赖。
- ✅ 关键词推荐在 App 层（`AppModel`），不进 Core。
- ✅ 不引入任何新依赖（无代码生成、无资源包）。

## 6. 文件改动清单

| 文件 | 改动 |
|---|---|
| `LLMProvider/SocialCopyPersona.swift` | 新增：值类型 + 6 个模板字面量 + `promptBlock` 渲染 |
| `LLMProvider/SocialCopywriter.swift` | `systemPrompt` 拆成 `taskPrompt` + 组合函数；`generate` 加 `persona` 参数；数量改 3/3/3 |
| `App/SocialCopyPanel.swift` | header 加人设 Picker + 推荐角标 |
| `App/AppModel.swift` | `socialCopyPersona` 持久化 + `suggestedPersona(for:)` 关键词表 |
| `docs/design/personas/*.md` | 6 份人设 authoring 源（从生成器产物拷入） |
| `docs/design/social-copy-personas.md` | 本 spec |
| `Tests/AirTrimCoreTests/SocialCopyPersonaTests.swift` | 新增单测 |

## 7. 测试

- **渲染**：每个 persona 的 `promptBlock` 包含全部 8 个字段内容；且不含任务级
  指令（断言不出现「请按以下格式输出」「你的任务是」）。
- **组合**：`systemPrompt(for:)` 同时含 taskPrompt 关键锚点（【标题方案】、
  「每组 3 个」）与 persona 语感判据；不同 persona 生成的 prompt 互不相同。
- **解析联测**：用一份样例 LLM 输出跑 `parseSections`，与现有结构兼容。
- **推荐**：关键词表命中/未命中/多命中取首个 的用例。
- 全量 `swift test`（现有 140 + 新增）＋ `scripts/check-architecture.sh` 全绿。

## 8. 实施步骤

1. **Phase 1（Core，可测）**：拷入 6 份 md → 建 `SocialCopyPersona` + 模板字面量
   + `promptBlock` 渲染 → 拆 `SocialCopywriter` taskPrompt、改 `generate` 签名
   → 写单测。
2. **Phase 2（App）**：面板人设 Picker + 持久化 + 关键词推荐。
3. **Phase 3（联调）**：输出数量精简验证、面板手测（选人设 → 生成 → 复制）、
   `swift build` + `swift test` + `check-architecture.sh` 全绿后按流程重启。
4. **Phase 4（提交）**：`feat(social-copy): …` 提交到 `feat/social-copy-personas`。

## 9. 人设模板字段规范（给 prompt 生成器的契约，用于后补赛道）

每个 md 固定字段：`display_name` / `description` / `## 受众画像` / `## 内容价值
类型` / `## 标题钩子`（类型 × 范例）/ `## 文案语气`（角度 × 范例）/ `## 标签方向`
（精准 / 泛流量 / 身份）/ `## 抖音平台锚点` / `## 红线`（≥3 条，禁止 + 反例）/
`## 语感判据`（一句自测句）。硬性要求：只定义人设块、不写任务与输出格式；受众
画像可判别；每个槽位 2–3 真实范例；效果/数据表述带免责；不预设口播主题；输入
只有文字稿。**后补新赛道 = 生成一个 md → 手写转一个值 → 进 `all`，三处改动。**

## 10. 待定 / 后续（P1+）

- 目标轴（涨粉 / 互动 / 带货）——第三根乘法轴，改变钩子与 CTA 策略。
- 封面字方案（抖音点击率第一杠杆）——并入「发布包」：封面字 + 标题 + 文案 + 标签。
- 分块「换一批」——标题/文案/标签独立重生成，不重跑整段。
- 平台适配（小红书 / B 站文案文化差异）。
- 热门标签池（需外部数据源）。
