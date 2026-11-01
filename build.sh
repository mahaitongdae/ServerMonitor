#!/bin/bash
# 编译并打包成 ServerMonitor.app；加 --install 则复制到 ~/Applications 并启动
set -e
cd "$(dirname "$0")"
APP=ServerMonitor.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
swiftc -O main.swift -o "$APP/Contents/MacOS/ServerMonitor"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>ServerMonitor</string>
  <key>CFBundleIdentifier</key><string>com.haitongma.servermonitor</string>
  <key>CFBundleExecutable</key><string>ServerMonitor</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Open ssh sessions in iTerm2.</string>
</dict></plist>
PLIST
if [ -f hosts.conf ]; then mkdir -p "$APP/Contents/Resources"; cp hosts.conf "$APP/Contents/Resources/"; else echo "warning: no hosts.conf (see hosts.conf.example)"; fi
codesign -s - --force -r='designated => identifier "com.haitongma.servermonitor"' "$APP" >/dev/null 2>&1 || true
echo "built $PWD/$APP"
if [ "$1" = "--install" ]; then
  mkdir -p ~/Applications
  pkill -x ServerMonitor || true
  rm -rf ~/Applications/$APP && cp -R "$APP" ~/Applications/
  open ~/Applications/$APP
  echo "installed ~/Applications/$APP"
fi
