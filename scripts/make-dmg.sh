#!/usr/bin/env bash
# 把 build/AirTrim.app 打成可分发 DMG（发布流程见 docs/release.md）。
# 用法：scripts/make-dmg.sh [版本号]（缺省从 app 的 Info.plist 读）
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/AirTrim.app
[[ -d "$APP" ]] || { echo "先跑 scripts/make-app.sh"; exit 1; }

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")}"
DMG="build/AirTrim-${VERSION}.dmg"
STAGE=build/dmg-stage

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "AirTrim ${VERSION}" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

shasum -a 256 "$DMG"
echo "✅ $DMG"
