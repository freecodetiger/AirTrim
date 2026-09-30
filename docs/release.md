# 发布流程（M1.3 起）

> 本地开发用 `make-app.sh`（ad-hoc 签名）即可。**对外发布**必须走
> Developer ID 签名 + 公证，否则用户侧 Gatekeeper 直接拦截。
> 发布统一走 `scripts/release-dmg.sh`——本地与 CI 是同一条路径，避免两套流程漂移。

## 0. 前置（一次性）

1. Apple Developer Program 会员（99 USD/年）。
2. **Developer ID Application** 证书已在登录钥匙串里：
   `Developer ID Application: pengcheng zhang (U6Y3X5W7T2)`（**2027-02-01 到期**，续期前要换）。
3. App 专用密码存入钥匙串供 notarytool 使用：

```bash
# --password 故意不写：会走安全输入框，密码不进 shell 历史
xcrun notarytool store-credentials airtrim-notary \
  --apple-id "<你的 Apple ID>" --team-id "U6Y3X5W7T2"
```

## 1. 签名 + 公证 + 装订（一条命令）

```bash
AIRTRIM_SIGN_IDENTITY="Developer ID Application: pengcheng zhang (U6Y3X5W7T2)" \
  scripts/release-dmg.sh 0.1.6
```

脚本跑完全套：`make-app.sh` 签 .app（hardened runtime `--options runtime` +
安全时间戳 `--timestamp`，两者都是公证的硬要求）→ 打 DMG → 签 DMG →
`notarytool submit --wait` → `stapler staple` → `spctl` 校验 → 打印 sha256。

**判据：最后 spctl 必须输出 `accepted`。** 若输出
`rejected` + `source=Unnotarized Developer ID`，说明签名是好的但公证没生效。
产物在 `build/AirTrim-<版本>.dmg`。

> 不用 `codesign --deep`：Apple 只推荐它做校验，用于签名会让嵌套项的责任归属变模糊。

## 2. GitHub Release

CI（`.github/workflows/release.yml`）在 `v*` tag push 时跑同一条 `release-dmg.sh`，
自动签名 + 公证后把 DMG 传上 release。需要的仓库 secrets：

| Secret | 内容 |
|---|---|
| `MACOS_CERT_P12` | Developer ID 证书导出的 .p12，`base64` 成一行 |
| `MACOS_CERT_PASSWORD` | 导出 .p12 时设的密码 |
| `KEYCHAIN_PASSWORD` | CI 临时钥匙串密码（任意，仅本次运行用） |
| `APPLE_SIGN_IDENTITY` | `Developer ID Application: 名字 (TEAMID)` |
| `APPLE_ID` / `APPLE_TEAM_ID` / `APPLE_APP_PASSWORD` | notarytool 公证凭据 |

导出证书：钥匙串访问 → 登录 → 我的证书 → 该 Developer ID 证书 → 导出为 `.p12`，
然后 `base64 -i cert.p12 | gh secret set MACOS_CERT_P12`。

> ⚠️ 这条 CI 路径**尚未在真实 runner 上验证过**（首次带 tag 发版要盯 run 日志）。

发版：`git tag v<版本> && git push origin v<版本>`（push 需 owner 明确执行）。
Release notes 按「新增/修复/已知问题」三段写。

## 3. Homebrew Cask

首发后建 tap 仓库 `freecodetiger/homebrew-airtrim`，放入：

```ruby
# Casks/airtrim.rb
cask "airtrim" do
  version "0.1.0"
  sha256 "<DMG 的 sha256>"

  url "https://github.com/freecodetiger/AirTrim/releases/download/v#{version}/AirTrim-#{version}.dmg"
  name "AirTrim"
  desc "Transcript-driven subtitle & trim tool for talking-head videos, local-first"
  homepage "https://github.com/freecodetiger/AirTrim"

  depends_on macos: ">= :sonoma"

  app "AirTrim.app"

  zap trash: [
    "~/Library/Application Support/AirTrim",
  ]
end
```

用户安装：`brew install --cask freecodetiger/airtrim/airtrim`。

## 4. 发版判据

`docs/release-checklist.md` 全绿 + owner 人工验收（SRT 质量、烧录成片、AI 断句）。
