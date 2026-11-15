#!/bin/zsh
# Builds DeepField.app (menu bar only, no Dock icon) into ./build.
set -euo pipefail
cd "${0:a:h}"

swift build -c release
APP=build/DeepField.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/DeepField "$APP/Contents/MacOS/DeepField"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>DeepField</string>
    <key>CFBundleIdentifier</key><string>local.deepfield.wallpaper</string>
    <key>CFBundleName</key><string>Deep Field</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"
