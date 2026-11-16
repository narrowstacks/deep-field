#!/bin/zsh
# Builds DeepField.app (menu bar only, no Dock icon) into ./build.
#
# Optional env:
#   MARKETING_VERSION  version string (default: contents of ./VERSION)
#   BUILD_NUMBER       CFBundleVersion (default: number of commits on HEAD)
#   UNIVERSAL=1        build arm64 + x86_64 (release builds); default is this Mac's arch only
#   SIGNING_IDENTITY   "Developer ID Application: ..." to sign for distribution with the
#                      hardened runtime and a secure timestamp; empty means ad-hoc (local use)
set -euo pipefail
cd "${0:a:h}"

VERSION="${MARKETING_VERSION:-$(tr -d '[:space:]' < VERSION)}"
BUILD="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
IDENTITY="${SIGNING_IDENTITY:-}"

# Swift const values feed the App Intents metadata below (Focus filters and Shortcuts actions)
CONST_FLAGS=(-Xswiftc -emit-const-values -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file
             -Xswiftc -Xfrontend -Xswiftc "$PWD/Resources/AppIntentsProtocols.json")
if [[ "${UNIVERSAL:-0}" == 1 ]]; then
  swift build -c release --arch arm64 --arch x86_64 "${CONST_FLAGS[@]}"
  PRODUCTS=.build/out/Products/Release
  [[ -d $PRODUCTS ]] || PRODUCTS=.build/apple/Products/Release
else
  swift build -c release "${CONST_FLAGS[@]}"
  PRODUCTS=.build/release
fi

APP=build/DeepField.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$PRODUCTS/DeepField" "$APP/Contents/MacOS/DeepField"
SPARKLE=$(find "$PRODUCTS" .build/artifacts -maxdepth 6 -name Sparkle.framework -type d | head -1)
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"

# App Intents metadata: without it macOS doesn't list the Focus filter or the Shortcuts actions.
# Xcode runs this step itself; SwiftPM doesn't, so it's run here on the compiler's const values.
CONSTVALS=$(find .build -name 'DeepField*.swiftconstvalues' -newer Package.swift -path '*Release*' | head -1)
if [[ -n "$CONSTVALS" ]] && xcrun --find appintentsmetadataprocessor >/dev/null 2>&1; then
  LISTS=$(mktemp -d)
  find "$PWD/Sources/DeepField" -name '*.swift' > "$LISTS/sources"
  echo "$PWD/$CONSTVALS" > "$LISTS/constvals"
  xcrun appintentsmetadataprocessor --quiet-warnings \
    --output "$APP/Contents/Resources" \
    --toolchain-dir "$(dirname "$(dirname "$(dirname "$(xcrun --find swift)")")")" \
    --module-name DeepField --sdk-root "$(xcrun --show-sdk-path)" \
    --xcode-version "$(xcodebuild -version | awk '/Build version/ {print $3}')" \
    --platform-family macOS --deployment-target 14.0 --target-triple arm64-apple-macos14.0 \
    --bundle-identifier com.narrowstacks.DeepField --binary-file "$APP/Contents/MacOS/DeepField" \
    --source-file-list "$LISTS/sources" --swift-const-vals-list "$LISTS/constvals" >/dev/null
  [[ -f "$APP/Contents/Resources/Metadata.appintents/extract.actionsdata" ]] || { echo "App Intents metadata missing" >&2; exit 1; }
else
  echo "warning: no App Intents metadata (needs Xcode); Focus filters and Shortcuts actions won't show" >&2
fi

# app icon: Design/Icons/AppIcon.png (1024x1024) -> AppIcon.icns
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size Design/Icons/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) Design/Icons/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>DeepField</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>com.narrowstacks.DeepField</string>
    <key>CFBundleName</key><string>Deep Field</string>
    <key>CFBundleDisplayName</key><string>Deep Field</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>NSHumanReadableCopyright</key><string>Copyright © $(date +%Y) Aaron Anderson</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.entertainment</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPhotoLibraryAddUsageDescription</key><string>Deep Field adds the phone wallpapers you export to Photos, so they sync to your iPhone.</string>
    <key>NSPhotoLibraryUsageDescription</key><string>Deep Field only adds the phone wallpapers you export to Photos; it doesn't read your library.</string>
    <key>SUFeedURL</key><string>https://github.com/narrowstacks/deep-field/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key><string>zZlAdBsH5Y6Gn563Ep70h1K1jL8lw43UkvZDo0fV7c8=</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUScheduledCheckInterval</key><integer>86400</integer>
</dict>
</plist>
PLIST

if [[ -n "$IDENTITY" ]]; then
  # Sparkle's helpers first (inside out), then the framework, then the app.
  sign() { codesign --force --timestamp --options runtime --sign "$IDENTITY" "$@"; }
  FW="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
  sign "$FW/XPCServices/Installer.xpc"
  sign --preserve-metadata=entitlements "$FW/XPCServices/Downloader.xpc"
  sign "$FW/Autoupdate"
  sign "$FW/Updater.app"
  sign "$APP/Contents/Frameworks/Sparkle.framework"
  sign --entitlements Resources/DeepField.entitlements "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
else
  codesign --force --deep --sign - "$APP"
fi
echo "Built $APP ($VERSION, build $BUILD)"
