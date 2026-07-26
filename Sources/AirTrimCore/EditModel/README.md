# EditModel（占位 · 未实现）

**职责**：剪辑状态唯一真相源——`EditList`（有序不重叠的 cut 区间）、`EditSuggestion` 生命周期（proposed → accepted/rejected）、undo 快照栈、源时间轴 ↔ 成片时间轴换算。

**边界**：纯值类型层，无系统框架依赖（CoreMedia 除外）。"接受建议"是区间进入 `EditList` 的唯一路径；verbosity 建议永不自动接受。

首个实现在 M2。不变量清单见 `.claude/skills/edit-model/` 与 ADR-0004。
