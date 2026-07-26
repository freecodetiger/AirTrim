# 发布流程（M1.3 起）

> 本地开发用 `make-app.sh`（ad-hoc 签名）即可。**对外发布**必须走
> Developer ID 签名 + 公证，否则用户侧 Gatekeeper 直接拦截。

## 0. 前置（一次性，需要 owner 操作）

1. Apple Developer Program 会员（99 USD/年）。
2. Xcode → Settings → Accounts 创建 **Developer ID Application** 证书。
3. 生成 App 专用密码，存入钥匙串供 notarytool 使用：

```bash
xcrun notarytool store-credentials airtrim-notary \
  --apple-id "<你的 Apple ID>" --team-id "<TEAM_ID>" --password "<app 专用密码>"
```

## 1. 构建 + 签名

```bash
scripts/make-app.sh release
codesign --force --deep --options runtime --timestamp \
  --sign "Developer ID Application: <名字> (<TEAM_ID>)" build/AirTrim.app
codesign --verify --strict --verbose=2 build/AirTrim.app
```

> hardened runtime（`--options runtime`）是公证的硬要求。

## 2. 公证 + 装订

```bash
scripts/make-dmg.sh
xcrun notarytool submit build/AirTrim-*.dmg --keychain-profile airtrim-notary --wait
xcrun stapler staple build/AirTrim-*.dmg
spctl -a -t open --context context:primary-signature -v build/AirTrim-*.dmg   # 应输出 accepted
```

## 3. GitHub Release

1. 版本号：改 `scripts/make-app.sh` 里的 `CFBundleShortVersionString`（语义化版本）。
2. `git tag v<版本> && git push origin v<版本>`（push 需 owner 明确执行）。
3. Release 附件：装订后的 DMG + `shasum -a 256` 校验值。
4. Release notes 按「新增/修复/已知问题」三段写；首版附 README 的功能列表。

## 4. Homebrew Cask

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

## 5. 发版判据

`docs/release-checklist.md` 全绿 + owner 人工验收（SRT 质量、烧录成片、AI 断句）。
