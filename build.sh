#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="ProcessViewer"
DISPLAY="进程查看器"
BUNDLE_ID="com.zhaohe.processviewer"
SDK="$(xcrun --show-sdk-path)"
BUILD="build"
APP="$BUILD/$APP_NAME.app"

echo "==> 编译 Swift 源码"
rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -parse-as-library -O \
  -sdk "$SDK" \
  -target arm64-apple-macos13.0 \
  sources/*.swift \
  -o "$APP/Contents/MacOS/$APP_NAME"

echo "==> 拷贝图标资源"
if [ -f assets/AppIcon.icns ]; then
  cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  echo "    AppIcon.icns 已放入 Resources"
else
  echo "    (未找到 assets/AppIcon.icns，跳过图标)"
fi

echo "==> 写入 Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$DISPLAY</string>
  <key>CFBundleDisplayName</key><string>$DISPLAY</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>© zhaohe</string>
</dict>
</plist>
PLIST

echo "==> ad-hoc 签名"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "(签名跳过)"

echo "==> 完成: $APP"
echo "运行: open \"$APP\""
