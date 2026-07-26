# Release 回归清单

> 每次对外发版（tag 之前）逐项过。自动化项直接跑命令；人工项 owner 亲测。
> 全绿 + 人工验收通过才允许 tag（流程见 [release.md](release.md)）。

## A. 自动化（每项必须绿）

| # | 项 | 命令 |
|---|---|---|
| A1 | 构建 | `swift build -c release` |
| A2 | 全量测试 | `swift test` |
| A3 | 架构守卫 | `scripts/check-architecture.sh` |
| A4 | 打包 | `scripts/make-app.sh`（产物含图标 + 签名） |
| A5 | release 冒烟：转写直达编辑器 | 见下方 A5 命令；进程存活 ≥60s 且生成项目缓存 |
| A6 | 词级时间戳回归（干净素材） | spike `transcribe` + `evaluate` vs `koubo-01.truth.json`：中位 ≤80ms · P95 ≤200ms · CER ≤8% |
| A7 | BGM 抗性回归 | `tools/mix_bgm.py` 混音后重跑 A6（[基准](spikes/results/koubo-01-bgm-regression.md)） |
| A8 | 烧录回归 | spike `burn --dump-frame` 出帧：字幕可见、位置正确、≤2 行 |

A5 冒烟（release bundle 直接跑二进制，专抓 dead-strip 类 release-only 崩溃）：

```bash
mv ~/Library/Application\ Support/AirTrim/Projects{,.bak}   # 挪走缓存，逼真转写路径
AIRTRIM_AUTOLOAD=Fixtures/private/koubo-01.mov build/AirTrim.app/Contents/MacOS/AirTrim &
sleep 90 && kill %1
ls ~/Library/Application\ Support/AirTrim/Projects/*.json    # 缓存已生成 = 全链路跑通
rm -rf ~/Library/Application\ Support/AirTrim/Projects
mv ~/Library/Application\ Support/AirTrim/Projects{.bak,}    # 恢复原缓存
```

A8 烧录回归：

```bash
swift run -c release airtrim-spike burn \
  --video Fixtures/private/koubo-01.mov \
  --project ~/Library/Application\ Support/AirTrim/Projects/<指纹>.json \
  --output /tmp/burn-check.mp4 --dump-frame 3 45 130
```

### A-M2（一键紧凑，2026-07-27 起）

| # | 项 | 命令/判据 |
|---|---|---|
| A9 | 紧凑样片回归 | `airtrim-spike burn --tighten`（或 `--tighten-intensity 0.5`）出片成功、时长 = 源 − 已剪 |
| A10 | 视觉冒烟 | `AIRTRIM_SNAPSHOT=<png> open build/AirTrim.app`：卡片/轨道/建议块/波形齐全 |
| A11 | EditModel/Analyzer 单测 | `swift test`（含 EditList 换算往返、建议生命周期、PauseAnalyzer 参数缩放） |

## B. 人工验收（owner）

- [ ] B1 冷启动恢复上次会话（秒开，不重转写）
- [ ] B2 完整走一遍：拖入视频 → 真实进度条 → 编辑（改字/拆合句/试听）→ ⌘Z
- [ ] B3 AI 断句：配 Key 后语义断句合理；无 Key 时报错文案可行动
- [ ] B4 SRT 导出：时间轴与试听对齐，播放器（IINA/QuickTime+挂载）验证
- [ ] B5 烧录导出：成片字幕样式/时序正确；**源文件未被修改**（mtime/大小不变）
- [ ] B6 模型管理：设置页显示占用；「校验并修复」可跑；删除后回到 onboarding
- [ ] B7 错误路径：导入纯音频（可转写）、无音轨视频（明确报错）、下载中断点重试
- [ ] B8 图标在 Dock/访达/关于窗口显示正常
- [ ] B9 一键紧凑耳测：成片无爆音、无吞字、停顿保留自然（听感不变量，cut-quality skill）
- [ ] B10 建议审阅：跳听/接受/拒绝/⌘Z 整体回退；紧凑度滑杆重跑不打扰已拒绝项
- [ ] B11 成片预览开关：播放头映射正确，卡片/轨道高亮跟随成片播放

## C. 已知素材缺口（不阻塞发版，但记录在案）

- 快语速素材：无真实样本，合成拉伸不可信（[说明](spikes/results/koubo-01-bgm-regression.md)）。
  收集到后跑 A6 流程并把结果记入 `docs/spikes/results/`。
- 真实音乐 BGM 素材：当前 A7 用合成代理。
- 长素材（>30min）：M1 只承诺提示，不承诺体验；M2 优化。

## D. 发布产物

- [ ] D1 Developer ID 签名 + 公证 + 装订（`release.md` §1–2）
- [ ] D2 DMG sha256 记入 Release notes
- [ ] D3 Homebrew Cask version/sha256 同步更新
- [ ] D4 README 功能列表与实际一致；截图用**可公开素材**重录（私有素材绝不入库）
