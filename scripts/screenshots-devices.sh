#!/bin/zsh
# App Store screenshots for Apple TV and Apple Vision Pro, from the app's demo mode in the simulator.
#   fastlane/screenshots-tvos/en-US/   fastlane/screenshots-visionos/en-US/
set -e
cd "$(dirname "$0")/.."
BUNDLE=app.aerilo.Aerilo
run() { # simulator name, platform, products folder, output folder, seconds to settle
  local device=$1 platform=$2 products=$3 out=$4 settle=$5
  mkdir -p "$out"
  xcodebuild -project Aerilo.xcodeproj -scheme AeriloMobile -configuration Debug -destination "platform=$platform Simulator,name=$device" -derivedDataPath build-ios build -quiet
  xcrun simctl boot "$device" 2>/dev/null || true
  xcrun simctl bootstatus "$device" -b >/dev/null
  xcrun simctl install "$device" "build-ios/Build/Products/$products/Aerilo.app"
  # One launch to get past the first-start splash before any picture is taken.
  xcrun simctl launch "$device" $BUNDLE --demo >/dev/null; sleep 8
  local n=1
  for shot in exhale result similar videos device; do
    xcrun simctl terminate "$device" $BUNDLE 2>/dev/null || true
    xcrun simctl launch "$device" $BUNDLE --demo --shot $shot -AppleLanguages "(en)" -AppleLocale en_US >/dev/null
    if [[ $shot == exhale ]]; then sleep 2.6; else sleep "$settle"; fi
    xcrun simctl io "$device" screenshot --type=png "$out/$n-$shot.png" 2>/dev/null
    n=$((n + 1))
  done
  xcrun simctl terminate "$device" $BUNDLE 2>/dev/null || true
  xcrun simctl shutdown "$device"
}
run "Apple TV 4K (4th generation)" tvOS Debug-appletvsimulator artwork/raw/tvos 4
run "Apple Vision Pro" visionOS Debug-xrsimulator artwork/raw/visionos 6

# Headline, description and the finished look, into the fastlane folders.
swift scripts/make-art.swift shots
