#!/usr/bin/env bash
# 把 SPM 可执行产物打成可双击的 AirTrim.app（本地开发/分发前置）。
# 产物在 build/AirTrim.app；发布版的 notarize/DMG 流程后续在此基础上加。
set -euo pipefail
cd "$(dirname "$0")/.."

CONF="${1:-release}"
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
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key>          <string>1</string>
    <key>LSMinimumSystemVersion</key>   <string>14.0</string>
    <key>NSHighResolutionCapable</key>  <true/>
    <key>NSHumanReadableCopyright</key> <string>MIT License · AirTrim contributors</string>
</dict>
</plist>
PLIST

# 本地 ad-hoc 签名（发布版换 Developer ID + notarize）
codesign --force --deep --sign - "$APP"
echo "✅ $APP（open build/AirTrim.app 启动）"
