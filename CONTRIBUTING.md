# Contributing to AirTrim

感谢关注！当前项目处于 **文档建设阶段（pre-alpha）**，最有价值的贡献是：审阅设计文档（`docs/`）、参与 ADR 讨论、提供中文口播测试素材反馈。

## 开发环境

- macOS 14+，Xcode 15+（Swift 6.1，语言模式 v6）
- 测试框架：swift-testing（`import Testing`，不用 XCTest）

```bash
swift build
swift test
scripts/check-architecture.sh   # 分层守卫，PR 必须全绿
```

## 提交规范

- Conventional Commits：`<type>(<scope>): <summary>`
  - type：`feat` / `fix` / `docs` / `refactor` / `test` / `chore` / `perf`
  - 例：`feat(analysis): pause analyzer with adjustable min-gap`
- 一个意图一个 commit；先绿再 commit。

## PR 要求

1. `swift build` + `swift test` + `scripts/check-architecture.sh` 全绿。
2. 遵守 `CLAUDE.md` 的职责边界与禁止事项（人和 AI Agent 同样适用）。
3. 涉及架构边界 / 状态归属的改动，先提 ADR（`docs/adr/`，沿用现有编号与格式）讨论，再动代码。
4. 不引入 GPL 系依赖（本项目 MIT，见 ADR-0001）；不引入 ffmpeg（ADR-0002）。

## 测试素材

真实口播视频不入库（`Fixtures/private/` 已忽略）。可公开的短小样例放 `Fixtures/public/` 并注明来源与许可。
