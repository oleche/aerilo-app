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
#     AuthKey_<key_id>.p8 beside it. Set ASC_API_KEY_PATH, or keep one .json in ~/.appstoreconnect.
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
  # Inside out: the widget is its own sandboxed program and keeps its own entitlements.
  codesign --force --options runtime --timestamp --entitlements Config/Widgets.entitlements --sign "$IDENTITY" "$APP/Contents/PlugIns/AeriloWidgets.appex"
  codesign --force --options runtime --timestamp --entitlements Config/Direct.entitlements --sign "$IDENTITY" "$APP"
  codesign --verify --deep --strict "$APP"
fi

# Start from nothing: a leftover file from an earlier build would ship inside the app and break its signature.
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Aerilo.app"
codesign --verify --deep --strict "$STAGE/Aerilo.app"
ln -sfn /Applications "$STAGE/Applications"
hdiutil create -volname "Aerilo" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

if [[ "$NOTARIZE" == "--notarize" ]]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
  KEY_JSON=${ASC_API_KEY_PATH:-$(ls "$HOME"/.appstoreconnect/*.json 2>/dev/null | head -1)}
  [[ -n "$KEY_JSON" && -f "$KEY_JSON" ]] || { echo "No App Store Connect key: set ASC_API_KEY_PATH or put its .json in ~/.appstoreconnect"; exit 1; }
  KEY_ID=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['key_id'])" "$KEY_JSON")
  ISSUER=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['issuer_id'])" "$KEY_JSON")
  xcrun notarytool submit "$DMG" --key "$(dirname "$KEY_JSON")/AuthKey_$KEY_ID.p8" --key-id "$KEY_ID" --issuer "$ISSUER" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
fi

VERSION=$(defaults read "$APP/Contents/Info" CFBundleShortVersionString)
echo "Made $DMG (Aerilo $VERSION, $(du -h "$DMG" | cut -f1 | tr -d ' '), sha256 $(shasum -a 256 "$DMG" | cut -d' ' -f1))"
