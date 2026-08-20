---
name: edit-model
description: 改动剪辑状态（EditList/EDL）、建议(EditSuggestion)生命周期、undo、接受/拒绝流程时使用。覆盖唯一真相源不变量与时间权威规则。
---

# EditModel 域知识

## 不变量（违反即 bug）

1. `EditList` 是剪辑状态唯一真相源。UI/预览/导出只消费从它派生的不可变快照，绝不自持区间副本。
2. `EditList.cuts` 始终**有序且互不重叠**——合并发生在"接受建议"入口处，不是消费方兜底。
3. 源媒体只读；`EditList` 里的区间全部落在源时间轴上（不是成片时间轴）。
4. Undo = 快照栈（`EditSession.history`），值类型整体入栈。不做增量 diff、不做 command pattern——除非量化出内存问题并写 ADR。
5. 权威时间是 `CMTime`。`Double` 秒只准出现在 UI 格式化层，出现在 EditModel 内即违规。

## Suggestion 生命周期

```
分析器产出 proposed
   → 用户接受 accepted   → 区间合并进 EditList
   → 用户拒绝 rejected   → 保留记录（重跑分析时不重复打扰）
```

- 区间进 EditList 有两个入口：建议 accept（含一键全收）与手动精确剪（剪刀模式）。都经 `EditList.add` 归并、都走 `EditSession.apply` 入 undo。
- 建议不是剪辑：`EditSuggestion` 与 `EditList` 分离存储。手动剪的 in 点是瞬态 UI 状态，不进 EditList。
- verbosity 建议**永不自动接受**；pause 可"一键全收"，但同样走 accept 路径（可撤销）。
- 重跑分析器时：新建议与已 rejected 的按区间去重，避免"拒绝过的又冒出来"。

## 时间换算规则

- 源时间轴 → 成片时间轴的换算是纯函数（扣掉 cuts 前缀和），放 EditModel，供字幕导出（SRT 时间要的是成片轴）与预览 seek 使用。
- LLM 只给句编号；句编号 → 词下标区间 → `CMTime` 的反查也在本地完成（见 ADR-0003）。
