#!/usr/bin/env bash
# 对外发版：Developer ID 签名 → 打包 DMG → 签名 → 公证 → 装订 → 校验。
# 本地发版与 GitHub Actions 走同一条路径（避免两套流程漂移）。
#
# 前置：
#   1. 钥匙串里有 "Developer ID Application: ..." 证书
#   2. notarytool 凭据已存：xcrun notarytool store-credentials <profile> \
#        --apple-id <Apple ID> --team-id <TEAM_ID> --password <App 专用密码>
#
# 用法：AIRTRIM_SIGN_IDENTITY="Developer ID Application: ..." \
#         scripts/release-dmg.sh <版本号> [keychain-profile]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?用法: scripts/release-dmg.sh <版本号> [keychain-profile]}"
PROFILE="${2:-airtrim-notary}"
: "${AIRTRIM_SIGN_IDENTITY:?未设置 AIRTRIM_SIGN_IDENTITY（形如 "Developer ID Application: 名字 (TEAMID)"）}"

DMG="build/AirTrim-${VERSION}.dmg"

# .app 由 make-app.sh 按同一个 identity 签（hardened runtime + 时间戳）
scripts/make-app.sh release "$VERSION"
scripts/make-dmg.sh "$VERSION"

# DMG 容器也签：公证要能把这个分发容器归到同一个开发者产物上
codesign --force --timestamp --sign "$AIRTRIM_SIGN_IDENTITY" "$DMG"
codesign --verify --strict --verbose=2 "$DMG"

xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

# 应输出 accepted（不是 rejected/unknown）
spctl -a -t open --context context:primary-signature -v "$DMG"
shasum -a 256 "$DMG"
echo "✅ 签名 + 公证 + 装订完成：$DMG"
