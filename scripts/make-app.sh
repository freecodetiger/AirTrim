#!/usr/bin/env bash
# 把 SPM 可执行产物打成可双击的 AirTrim.app（本地开发/分发前置）。
# 产物在 build/AirTrim.app；对外发布再走 scripts/release-dmg.sh（签名+公证+装订）。
set -euo pipefail
cd "$(dirname "$0")/.."

CONF="${1:-release}"
VERSION="${2:-0.1.6}"
swift build -c "$CONF" --product AirTrimApp

APP=build/AirTrim.app
BIN=".build/$CONF/AirTrimApp"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AirTrim"

# 图标：脚本绘制（源头是 scripts/make-icon.swift，仓库不存二进制）
if [[ ! -f build/icon/AppIcon.icns ]]; then
  swift scripts/make-icon.swift build/icon
  iconutil -c icns build/icon/AppIcon.iconset -o build/icon/AppIcon.icns
fi
cp build/icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>       <string>AirTrim</string>
    <key>CFBundleIdentifier</key>       <string>dev.airtrim.app</string>
    <key>CFBundleName</key>             <string>AirTrim</string>
    <key>CFBundleDisplayName</key>      <string>AirTrim</string>
    <key>CFBundlePackageType</key>      <string>APPL</string>
    <key>CFBundleIconFile</key>         <string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>0.0.0</string>
    <key>CFBundleVersion</key>          <string>1</string>
    <key>LSMinimumSystemVersion</key>   <string>14.0</string>
    <key>NSHighResolutionCapable</key>  <true/>
    <key>NSHumanReadableCopyright</key> <string>MIT License · AirTrim contributors</string>
</dict>
</plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$APP/Contents/Info.plist"

# 签名：AIRTRIM_SIGN_IDENTITY 有值 → Developer ID + hardened runtime + 安全时间戳
# （对外发布用，公证的硬要求）；无值 → ad-hoc（本地开发/手测，不需要证书）。
# 不用 --deep：Apple 只推荐它做校验，签名会让嵌套项的责任归属变模糊；
# 本 bundle 除主可执行文件外无嵌套代码，逐个签即可。
if [[ -n "${AIRTRIM_SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp \
    --sign "$AIRTRIM_SIGN_IDENTITY" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
  echo "✅ ${APP} · Developer ID 签名（hardened runtime + 时间戳）"
else
  codesign --force --sign - "$APP"
  echo "✅ ${APP} · ad-hoc 签名（open build/AirTrim.app 启动）"
fi
