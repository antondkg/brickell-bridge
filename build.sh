#!/bin/bash
# Build BrickellBridge.app. INSTALL=1 also copies it to /Applications and relaunches.
set -e
cd "$(dirname "$0")"

APP="BrickellBridge.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -target arm64-apple-macos14.0 main.swift Stats.swift -o "$APP/Contents/MacOS/BrickellBridge" \
  -framework Cocoa -framework AVKit -framework ServiceManagement -framework UserNotifications

cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Brickell Bridge</string>
    <key>CFBundleExecutable</key><string>BrickellBridge</string>
    <key>CFBundleIdentifier</key><string>com.antondkg.brickellbridge</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force -s - "$APP" 2>/dev/null && echo "ad-hoc signed" || echo "codesign skipped"
echo "Built ./$APP"

if [ "${INSTALL:-}" = "1" ]; then
  pkill -x BrickellBridge 2>/dev/null || true
  rm -rf "/Applications/$APP"
  cp -R "$APP" /Applications/
  open "/Applications/$APP"
  echo "Installed to /Applications and launched"
fi
