# ADR-0001 · 开源（MIT）与分发方式

- 状态：已接受
- 日期：2026-07-26

## 背景

项目定位为开源社区项目（非商业产品、非自用脚本）。开源定位反过来约束技术选型：不能替用户付云端账单、依赖必须许可兼容、构建必须对贡献者友好（clone 即可跑）。

## 决策

1. 许可证 **MIT**。
2. 依赖只允许 MIT / Apache-2.0 / BSD 系；**禁止 GPL/LGPL 依赖**（这直接排除了 ffmpeg 常见构建，见 ADR-0002）。
3. 分发走 **Notarized DMG + Homebrew Cask**，不进 Mac App Store（避开沙盒对文件访问/辅助能力的限制；开源用户习惯 brew）。
4. 仓库不 vendor 任何二进制；ASR 模型运行时下载到 `~/Library/Application Support/AirCut/Models/`。
5. 云端 AI 一律 **BYOK**（用户自带 Key，见 ADR-0003）。

## 后果

- ✅ `git clone && swift build` 零门槛；无二进制供应链风险。
- ✅ 许可干净，企业用户可放心用。
- ⚠️ 无 MAS 曝光渠道，靠 GitHub/社区传播。
- ⚠️ 每次引入依赖需检查许可证（进 PR checklist）。
