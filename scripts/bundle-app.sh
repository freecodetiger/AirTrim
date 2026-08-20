#!/usr/bin/env bash
# 将裸 swift build 产物组装为 macOS .app bundle。
# macOS 要求 GUI 应用必须是 .app bundle，否则窗口服务器拒绝将辅助窗口
# 识别为常规 NSWindow（表现为 NSPanel：canBecomeKey=NO、浮在桌面之上）。
#
# 用法：scripts/bundle-app.sh [build-dir] [app-name]
set -euo pipefail

BUILD_DIR="${1:-.build/debug}"
APP_NAME="${2:-AirTrimApp}"
BUNDLE_ROOT="${BUILD_DIR}/${APP_NAME}.app"
EXEC_SRC="${BUILD_DIR}/${APP_NAME}"
EXEC_DST="${BUNDLE_ROOT}/Contents/MacOS/${APP_NAME}"
PLIST="${BUNDLE_ROOT}/Contents/Info.plist"

mkdir -p "${BUNDLE_ROOT}/Contents/MacOS"

cp "${EXEC_SRC}" "${EXEC_DST}"
chmod +x "${EXEC_DST}"

cat > "${PLIST}" <<'PLISTEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>PLACEHOLDER_EXEC</string>
    <key>CFBundleIdentifier</key>
    <string>dev.airtrim.app</string>
    <key>CFBundleName</key>
    <string>AirTrim</string>
    <key>CFBundleDisplayName</key>
    <string>AirTrim</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>
PLISTEOF

# 写入真实 executable 名
sed -i '' "s/PLACEHOLDER_EXEC/${APP_NAME}/" "${PLIST}"

# 图标：assets/app-icon-source.png → build/icon/AppIcon.icns（首次生成），拷入 bundle
if [[ ! -f build/icon/AppIcon.icns ]]; then
  swift scripts/make-icon.swift build/icon
  iconutil -c icns build/icon/AppIcon.iconset -o build/icon/AppIcon.icns
fi
mkdir -p "${BUNDLE_ROOT}/Contents/Resources"
cp build/icon/AppIcon.icns "${BUNDLE_ROOT}/Contents/Resources/AppIcon.icns"

echo "✅ ${BUNDLE_ROOT}"
