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
# Three short videos with the same length, picture size, capture time and file size. "same" is a true copy
# of "clip"; "other" has one byte of its picture data changed, so only its contents differ.
rm -f "$MEDIA/clip.mp4" "$MEDIA/clip-same.mp4" "$MEDIA/clip-other.mp4"
ffmpeg -loglevel error -y -f lavfi -i "testsrc2=s=640x360:r=30" -t 3 -c:v h264_videotoolbox -b:v 2M -pix_fmt yuv420p -metadata creation_time=2026-01-05T10:00:00Z "$MEDIA/clip.mp4"
cp "$MEDIA/clip.mp4" "$MEDIA/clip-same.mp4"
python3 - "$MEDIA/clip.mp4" "$MEDIA/clip-other.mp4" <<'PY'
import sys
data = bytearray(open(sys.argv[1], "rb").read())
start = data.index(b"mdat")
at = start + (len(data) - start) // 2   # the middle of the picture data
data[at] ^= 0xFF
open(sys.argv[2], "wb").write(data)
PY
xcrun simctl boot "$NAME"
xcrun simctl bootstatus "$NAME" -b >/dev/null
# The same bytes under a second name: Photos merges a file imported twice under one name.
cp "$MEDIA/duplicate.jpg" "$MEDIA/duplicate-copy.jpg"
xcrun simctl addmedia "$NAME" "$MEDIA/duplicate.jpg" "$MEDIA/duplicate-copy.jpg" "$MEDIA"/single-*.jpg "$MEDIA"/IMG-*-WA*.jpg "$MEDIA/screenshot.png" "$MEDIA/big.mp4" "$MEDIA"/clip*.mp4
sleep 5   # let Photos finish importing
# Photo access is given here; the system prompt itself belongs to iOS, not to Aerilo.
xcrun simctl privacy "$NAME" grant photos app.aerilo.Aerilo
xcodebuild test -project Aerilo.xcodeproj -scheme AeriloMobile -destination "platform=iOS Simulator,name=$NAME" -derivedDataPath build-ios "$@" 2>&1 \
  | grep -E "Test Case|error:|passed|failed|TEST|Executed" | sed -E 's#/Users/[^ ]*/aerilo-app/##'
xcrun simctl shutdown "$NAME" 2>/dev/null || true
