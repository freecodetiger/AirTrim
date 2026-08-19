# 手动精确剪（Manual Precise Cut）Spec

> 状态：设计待实现 · 目标：最小可用——剪刀模式 + 轨道两击成剪 + 每次 cut 可 ⌘Z 撤回。
> 背景：手动删句只剪词区间（`Transcript.sentenceRange` = 首词 start ~ 末词 end），句间静音不在任何句子范围内，删句后残留的「缝隙」剪不掉。本功能提供任意两次点击即可剪除区间的通用解法。

## 1. 交互流程（最小）

1. 点 TightenBar「✂️」进入剪刀模式：按钮高亮，轨道区域光标变剪刀。
2. 鼠标在轨道上**始终有一条跟手细线**指示当前位置；底部时码显示鼠标位置的毫秒时间（不在剪刀模式也显示）。
3. 轨道上第一次点击 = 设剪起点（in），画一条起点标记线；之后起点 → 鼠标之间出现**半透明区间预览**，第二击前先看到要剪什么。
4. 第二次点击 = 剪终点（out）→ 立即执行 cut，回到「等起点」状态（可连续剪）。
5. 每执行一次 cut = 恰好一步 undo（⌘Z 逐次撤回）。
6. 再点「✂️」退出剪刀模式，同时清空未完成的起点；Esc 只清空未完成起点。

## 2. 判定与守卫

- 第二次点击早于起点（out < in）：自动交换，取 `[min, max]`。
- 两次点击同一位置 / 区间零时长：忽略，不产生 cut，仍处于「等起点」。
- 点击位置 → 源时间轴秒，`CMTime(seconds:, preferredTimescale: 600)`（与现有 scrub 同款换算，`TimelineView.swift` 的 `x / pps`）。
- **磁吸（ManualCutSnap）**：落点距最近候选边界（全部词边界 + 静音沿）≤ ±250ms 时吸附到该边界；附近无边界则原样（词中自由剪是用户明确意图）。起点与终点都吸附；存储的起点是吸附后的值，UI 对齐。
- 不设最小剪除阈值——手动就是手动。

## 3. 数据路径（唯一真相源不破坏）

- 起点（in）是**瞬态 UI 状态**：`AppModel.manualCutStart: CMTime?`。不进 EditList、不持久化、不进 undo。
- 执行 cut（AppModel）：

```swift
session.apply { $0.edits.add(CMTimeRange(start: lo, end: hi)) }
refreshDerived()
```

- `EditList.add` 是唯一写入口：自带排序、重叠归并、零时长守卫（`EditList.swift:13`）。两次点击之间不写 EditList，中途退出不留脏区间。
- undo 走现有 `EditSession` 快照栈，一次 `session.apply` = 一步 undo，与删句 / 接受建议同一机制。
- 成片预览同步：`refreshDerived()` 触发已有重建逻辑，不新增。

## 4. UI 落地

| 项 | 实现 |
|---|---|
| 入口 | TightenBar 加「✂️」按钮，`model.toggleManualCutMode()` |
| 模式状态 | `@Published private(set) var isManualCutMode`（AppModel） |
| 光标 | 剪刀模式下轨道 hover 用 `NSCursor(image: NSImage(systemSymbolName: "scissors", …), hotSpot:)` |
| 手势 | 剪刀模式挂 SpatialTapGesture（点击 → `manualCut(at: x / pps)`），普通模式保留现有 scrub DragGesture；两者条件互斥 |
| 悬停细线 | `.onContinuousHover` 常驻追踪鼠标位置，任意模式下轨道内都有跟手细线；剪刀模式细线显示**吸附后**位置 |
| 区间预览 | 剪刀模式且已设 in：起点 → 吸附后鼠标位置之间半透明橙色蒙层 |
| 时码 | 悬停时底部时码切换为鼠标位置（毫秒精度）；剪刀模式起点标记线画在吸附后位置 |
| 起点标记 | 剪刀模式且已设 in 时画一条竖线（同 playhead 位置换算） |
| 提示 | 按钮 help「精确剪：点击定起点，再点剪掉」；已设起点时按钮旁提示「点终点剪掉」 |
| 清理 | 退出剪刀模式 / Esc 时 `manualCutStart = nil`（避免残留 in 下次误剪） |

## 5. 涉及文件与文档同步

- `Sources/AirTrimCore/EditModel/ManualCutSnap.swift`：磁吸纯函数（词界 + 静音沿候选、±250ms 阈值）+ 单测
- `Sources/AirTrimApp/AppModel.swift`：`isManualCutMode` / `manualCutStart` / `toggleManualCutMode()` / `manualCut(at:)`（落点经 ManualCutSnap 吸附）
- `Sources/AirTrimApp/TimelineView.swift`：条件手势、悬停细线、区间预览、吸附后位置、光标、毫秒时码
- `Sources/AirTrimApp/TimelineView.swift`（TightenBar）：剪刀按钮
- `.claude/skills/edit-model/SKILL.md`：不变量 1 文案从「accept 是区间进 EditList 的唯一路径」改为「建议 accept 与手动精确剪是区间进 EditList 的两个入口」
- 本文档即设计记录；不改 overview 数据流（EditList 仍是唯一真相源）

## 6. 不做（本轮）

- ❌ redo。应用当前无全局 redo（`EditSession` 只有 undo 栈、`AppModel` 只有 undo）。撤回由 undo 保证；要 redo 是另一处小改。
- ❌ 拖选 / 微调 / 试听 / min-gap 校验 / 磁吸旁路（⇧ 自由剪）。
- ❌ 不新增 `EditSuggestion` 类型、不新增持久化字段、不碰源媒体。

## 7. 验收（回归清单）

- [ ] 剪刀模式：第一击画起点线、区间预览随鼠标实时更新、第二击剪掉；成片预览听不到爆音 / 吞字
- [ ] 点击落在词界 / 静音沿 ±250ms 内被磁吸（剪的是整段静音而非词中）
- [ ] 鼠标在轨道上任意时刻都有跟手细线 + 毫秒时码；离开轨道消失
- [ ] ⌘Z 逐次撤回每次 cut；连续多次全部可撤回
- [ ] 连续剪多个区间不残留状态；Esc 清空未完成起点
- [ ] 退出剪刀模式再进：第一击设起点而非立刻剪（无残留 in）
- [ ] 剪刀模式外 scrub 行为不变
- [ ] `swift build` + `swift test` + `scripts/check-architecture.sh` 全绿
