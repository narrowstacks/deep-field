#!/bin/zsh
# Writes build/release/appcast.xml: a one-item Sparkle feed for this release, signed with
# the EdDSA key. It ships as a release asset; the app reads
# https://github.com/narrowstacks/deep-field/releases/latest/download/appcast.xml,
# which always points at the newest release's copy.
# Env: SPARKLE_ED_PRIVATE_KEY (the key itself; locally, export it once with
#      `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account deep-field -x <file>`),
#      MARKETING_VERSION, BUILD_NUMBER, SIGN_UPDATE (optional path).
set -euo pipefail
cd "${0:a:h}/../.."
DMG=build/release/DeepField.dmg
VERSION="${MARKETING_VERSION:-$(tr -d '[:space:]' < VERSION)}"
BUILD="${BUILD_NUMBER:?set BUILD_NUMBER}"
SIGN="${SIGN_UPDATE:-.build/artifacts/sparkle/Sparkle/bin/sign_update}"
: "${SPARKLE_ED_PRIVATE_KEY:?set SPARKLE_ED_PRIVATE_KEY}"
ATTRS=$(print -rn -- "$SPARKLE_ED_PRIVATE_KEY" | "$SIGN" --ed-key-file - "$DMG")
URL="https://github.com/narrowstacks/deep-field/releases/download/v$VERSION/DeepField.dmg"
NOTES=$(scripts/release/notes.sh "$VERSION" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
cat > build/release/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Deep Field</title>
    <item>
      <title>Deep Field $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description sparkle:format="plain-text">$NOTES</description>
      <enclosure url="$URL" type="application/octet-stream" $ATTRS />
    </item>
  </channel>
</rss>
XML
echo "Wrote build/release/appcast.xml"
