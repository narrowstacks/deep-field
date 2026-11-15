#!/bin/zsh
# Packages build/DeepField.app into build/release/DeepField.dmg (drag to Applications).
# Env: SIGNING_IDENTITY (optional) signs the DMG with Developer ID.
set -euo pipefail
cd "${0:a:h}/../.."
APP=build/DeepField.app
OUT=build/release
DMG="$OUT/DeepField.dmg"
[[ -d $APP ]] || { echo "error: $APP not found; run ./build.sh first" >&2; exit 1; }
command -v create-dmg >/dev/null || { echo "error: create-dmg not installed (brew install create-dmg)" >&2; exit 1; }
mkdir -p "$OUT"
rm -f "$DMG"
# create-dmg can exit non-zero after succeeding (e.g. no Finder on a headless runner),
# so check for the file instead of trusting the exit code
make_dmg() {
  create-dmg --volname "Deep Field" --volicon "$APP/Contents/Resources/AppIcon.icns" \
    --window-pos 200 120 --window-size 600 340 --icon-size 128 \
    --icon "DeepField.app" 150 160 --app-drop-link 450 160 --no-internet-enable \
    "$@" "$DMG" "$APP" || true
}
make_dmg
if [[ ! -f $DMG ]]; then
  # Finder's layout script can time out without a logged-in desktop; fall back to a plain
  # window (still has the Applications link)
  rm -f "$OUT"/rw.*.dmg
  make_dmg --skip-jenkins
fi
[[ -f $DMG ]] || { echo "error: create-dmg did not produce $DMG" >&2; exit 1; }
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
  codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG"
  codesign --verify --verbose=2 "$DMG"
fi
echo "Packaged $DMG"
