#!/bin/zsh
# 編譯 AI額度看板.app 並安裝到 /Applications（不需開 Xcode）
set -euo pipefail
cd "${0:A:h}"

# .noindex 結尾的資料夾 Spotlight 不會收錄，才不會搜到兩個「AI額度看板」
BUILD="build.noindex"
APP="$BUILD/AI額度看板.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
rm -rf "$BUILD" build
mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 5 -parse-as-library Sources/*.swift \
  -target arm64-apple-macos14.0 \
  -o "$APP/Contents/MacOS/QuotaBar"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>app.tipstudio.quotabar</string>
  <key>CFBundleName</key><string>AI額度看板</string>
  <key>CFBundleDisplayName</key><string>AI額度看板</string>
  <key>CFBundleExecutable</key><string>QuotaBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.9</string>
  <key>CFBundleVersion</key><string>19</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"

if [[ "${1:-}" == "--install" ]]; then
  # 先卸載 LaunchAgent，否則砍掉後 launchd 會馬上重開舊版
  launchctl bootout "gui/$(id -u)/app.tipstudio.quotabar" 2>/dev/null || true
  pkill -x QuotaBar 2>/dev/null && sleep 1 || true
  rm -rf /Applications/AI額度看板.app
  mv "$APP" /Applications/
  "$LSREGISTER" -u "$PWD/$APP" 2>/dev/null || true
  open /Applications/AI額度看板.app   # 有開「開機啟動」時，App 會交給 launchd 接手
  echo "已安裝並啟動：/Applications/AI額度看板.app"
else
  echo "已編譯：$APP（加 --install 安裝到 /Applications）"
fi
