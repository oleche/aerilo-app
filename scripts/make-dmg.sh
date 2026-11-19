#!/bin/zsh
# Builds the direct edition and packs it into build/Aerilo.dmg: a window with Aerilo and a shortcut
# to Applications, so installing is one drag.
#
#   scripts/make-dmg.sh             build, sign with whatever identity Xcode has, make the DMG
#   scripts/make-dmg.sh --notarize  also sign with Developer ID, notarize and staple
#
# --notarize needs:
#   - a "Developer ID Application" certificate in the keychain
#   - the App Store Connect API key as a fastlane JSON file (key_id, issuer_id) with its
#     AuthKey_<key_id>.p8 beside it. Default: ~/.appstoreconnect/samio-asc-key.json, the same
#     team key the Samio project uses. Override with ASC_API_KEY_PATH.
set -euo pipefail
cd "$(dirname "$0")/.."
NOTARIZE=${1:-}
OUT="$PWD/build"
STAGE="$OUT/dmg"
DMG="$OUT/Aerilo.dmg"

xcodebuild -project Aerilo.xcodeproj -scheme AeriloDirect -configuration Release -derivedDataPath "$OUT" build -quiet
APP="$OUT/Build/Products/Release/Aerilo.app"

if [[ "$NOTARIZE" == "--notarize" ]]; then
  IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')
  [[ -n "$IDENTITY" ]] || { echo "No Developer ID Application certificate in the keychain."; exit 1; }
  codesign --force --deep --options runtime --timestamp --entitlements Config/Direct.entitlements --sign "$IDENTITY" "$APP"
fi

mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Aerilo.app"
ln -sfn /Applications "$STAGE/Applications"
hdiutil create -volname "Aerilo" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

if [[ "$NOTARIZE" == "--notarize" ]]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
  KEY_JSON=${ASC_API_KEY_PATH:-$HOME/.appstoreconnect/samio-asc-key.json}
  [[ -f "$KEY_JSON" ]] || { echo "No App Store Connect key at $KEY_JSON"; exit 1; }
  KEY_ID=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['key_id'])" "$KEY_JSON")
  ISSUER=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['issuer_id'])" "$KEY_JSON")
  xcrun notarytool submit "$DMG" --key "$(dirname "$KEY_JSON")/AuthKey_$KEY_ID.p8" --key-id "$KEY_ID" --issuer "$ISSUER" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
fi

VERSION=$(defaults read "$APP/Contents/Info" CFBundleShortVersionString)
echo "Made $DMG (Aerilo $VERSION, $(du -h "$DMG" | cut -f1 | tr -d ' '), sha256 $(shasum -a 256 "$DMG" | cut -d' ' -f1))"
