#!/bin/zsh
# Notarizes and staples build/release/DeepField.dmg with an App Store Connect API key.
# Env: NOTARY_KEY_PATH (.p8), NOTARY_KEY_ID, NOTARY_ISSUER_ID; DMG_PATH (optional).
set -euo pipefail
cd "${0:a:h}/../.."
DMG="${DMG_PATH:-build/release/DeepField.dmg}"
: "${NOTARY_KEY_PATH:?set NOTARY_KEY_PATH}" "${NOTARY_KEY_ID:?set NOTARY_KEY_ID}" "${NOTARY_ISSUER_ID:?set NOTARY_ISSUER_ID}"
# on rejection, `xcrun notarytool log <id> --key ...` lists the offending files
RESULT=$(xcrun notarytool submit "$DMG" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --wait)
print -r -- "$RESULT"
[[ $RESULT == *"status: Accepted"* ]] || { echo "error: notarization was not accepted" >&2; exit 1; }
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
echo "Notarized $DMG"
