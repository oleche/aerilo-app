#!/bin/zsh
# End-to-end test of the iPhone app on a real photo library, in the simulator:
# erase a dedicated simulator, load generated media, then let XCUITest scan, review and delete.
set -e
cd "$(dirname "$0")/.."
NAME="Aerilo Test iPhone"
MEDIA=build-ios/test-media
xcrun simctl list devices | grep -q "$NAME" || xcrun simctl create "$NAME" "iPhone 18 Pro" >/dev/null
xcrun simctl shutdown "$NAME" 2>/dev/null || true
xcrun simctl erase "$NAME"
swift scripts/make-test-media.swift "$MEDIA"
# A video over the 50 MB threshold: moving noise does not compress.
[[ -f "$MEDIA/big.mp4" ]] || ffmpeg -loglevel error -y -f lavfi -i "testsrc2=s=1920x1080:r=30,noise=alls=60:allf=t" -t 14 -c:v h264_videotoolbox -b:v 40M -pix_fmt yuv420p "$MEDIA/big.mp4"
xcrun simctl boot "$NAME"
xcrun simctl bootstatus "$NAME" -b >/dev/null
# The same bytes under a second name: Photos merges a file imported twice under one name.
cp "$MEDIA/duplicate.jpg" "$MEDIA/duplicate-copy.jpg"
xcrun simctl addmedia "$NAME" "$MEDIA/duplicate.jpg" "$MEDIA/duplicate-copy.jpg" "$MEDIA"/burst-*.jpg "$MEDIA"/single-*.jpg "$MEDIA/screenshot.png" "$MEDIA/big.mp4"
sleep 5   # let Photos finish importing
# Photo access is given here; the system prompt itself belongs to iOS, not to Aerilo.
xcrun simctl privacy "$NAME" grant photos app.aerilo.Aerilo
xcodebuild test -project Aerilo.xcodeproj -scheme AeriloMobile -destination "platform=iOS Simulator,name=$NAME" -derivedDataPath build-ios "$@" 2>&1 \
  | grep -E "Test Case|error:|passed|failed|TEST|Executed" | sed -E 's#/Users/[^ ]*/aerilo-app/##'
xcrun simctl shutdown "$NAME" 2>/dev/null || true
