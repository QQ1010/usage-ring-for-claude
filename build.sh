#!/bin/zsh
# 編譯成 build/Usage Ring for Claude.app
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Usage Ring for Claude.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/UsageRing" main.swift

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Usage Ring for Claude</string>
  <key>CFBundleIdentifier</key><string>io.github.qq1010.usage-ring-for-claude</string>
  <key>CFBundleExecutable</key><string>UsageRing</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

codesign --force --sign - "$APP" >/dev/null 2>&1
echo "Built: $PWD/$APP"
