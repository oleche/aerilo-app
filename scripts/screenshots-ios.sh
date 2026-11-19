#!/bin/zsh
# App Store screenshots for iPhone and iPad, taken in the simulator from the app's demo mode
# (drawn sample pictures; no photo library is read).
#   artwork/raw/ios/  ->  fastlane/screenshots-ios/en-US/ (finished by scripts/make-art.swift)
set -e
cd "$(dirname "$0")/.."
OUT=artwork/raw/ios
BUNDLE=app.aerilo.Aerilo
mkdir -p "$OUT"
run() { # simulator name, file prefix
  local device=$1 prefix=$2
  xcodebuild -project Aerilo.xcodeproj -scheme AeriloMobile -configuration Debug -destination "platform=iOS Simulator,name=$device" -derivedDataPath build-ios build -quiet
  xcrun simctl boot "$device" 2>/dev/null || true
  xcrun simctl bootstatus "$device" -b >/dev/null
  xcrun simctl status_bar "$device" override --time "9:41" --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3 2>/dev/null || true
  xcrun simctl ui "$device" appearance light
  xcrun simctl install "$device" build-ios/Build/Products/Debug-iphonesimulator/Aerilo.app
  # One launch to get past the first-start delay before any picture is taken.
  xcrun simctl launch "$device" $BUNDLE --demo >/dev/null; sleep 6
  local n=1
  for shot in exhale result similar videos device log; do
    xcrun simctl terminate "$device" $BUNDLE 2>/dev/null || true
    xcrun simctl launch "$device" $BUNDLE --demo --shot $shot -AppleLanguages "(en)" -AppleLocale en_US >/dev/null
    if [[ $shot == exhale ]]; then sleep 2.3; else sleep 3.2; fi   # catch the ripples mid-flight
    xcrun simctl io "$device" screenshot --type=png "$OUT/$prefix-$n-$shot.png" 2>/dev/null
    n=$((n + 1))
  done
  xcrun simctl terminate "$device" $BUNDLE 2>/dev/null || true
  xcrun simctl shutdown "$device"
}
run "iPhone 18 Pro Max" iphone
run "iPad Pro 13-inch (M5)" ipad
# Headline, description and the finished look, into fastlane/screenshots-ios/en-US.
swift scripts/make-art.swift shots
