#!/bin/zsh
# Builds DeepField.app (menu bar only, no Dock icon) into ./build.
set -euo pipefail
cd "${0:a:h}"

swift build -c release
APP=build/DeepField.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/DeepField "$APP/Contents/MacOS/DeepField"

# app icon: Design/Icons/AppIcon.png (1024x1024) -> AppIcon.icns
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET" "$APP/Contents/Resources"
for size in 16 32 128 256 512; do
  sips -z $size $size Design/Icons/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) Design/Icons/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>DeepField</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>local.deepfield.wallpaper</string>
    <key>CFBundleName</key><string>Deep Field</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPhotoLibraryAddUsageDescription</key><string>Deep Field adds the phone wallpapers you export to Photos, so they sync to your iPhone.</string>
    <key>NSPhotoLibraryUsageDescription</key><string>Deep Field only adds the phone wallpapers you export to Photos; it doesn't read your library.</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"
