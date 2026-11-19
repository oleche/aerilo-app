#!/bin/zsh
# Makes screenshots of the real app window (title bar, toolbar and all) from the app's demo mode.
# Demo mode uses sample data; it reads and deletes nothing.
#   fastlane/screenshots/en-US/  App Store set: only what the App Store edition can do
#   marketing/screenshots/       full set for aerilo.app (direct edition)
# Needs Screen Recording permission for the terminal that runs it. Each shot brings a window to
# the front for about three seconds.
set -e
cd "$(dirname "$0")/.."
APP=build/Build/Products/Debug/Aerilo.app/Contents/MacOS/Aerilo
shot() { # folder, name, screen, extra args...
  local out=$1 name=$2 screen=$3; shift 3
  mkdir -p "$out"
  local log; log=$(mktemp)
  "$APP" --demo --capture --shot "$screen" -AppleLanguages "(en)" -AppleLocale en_US "$@" > "$log" 2>/dev/null &
  local pid=$!
  for i in {1..40}; do grep -q WINDOW "$log" && break; sleep 0.25; done
  screencapture -o -x -l "$(awk '/WINDOW/{print $2}' "$log")" "$out/$name.png"
  kill $pid; wait $pid 2>/dev/null || true
  sips -z 1800 2880 "$out/$name.png" >/dev/null   # the Mac App Store accepts 2880x1800
  # App Store screenshots may not be transparent: fill the window's rounded corners.
  [[ "$out" == fastlane/* ]] && swift scripts/flatten.swift "$out/$name.png"
  return 0
}
STORE=fastlane/screenshots/en-US
FULL=marketing/screenshots
shot $STORE 1-breathe exhale  --edition store
shot $STORE 2-result  result  --edition store
shot $STORE 3-storage storage --edition store
shot $STORE 4-log     log     --edition store
shot $STORE 5-dark    result  --edition store --appearance dark

shot $FULL 1-breathe  exhale
shot $FULL 2-result   result
shot $FULL 3-activity activity
shot $FULL 4-storage  storage
shot $FULL 5-network  network
shot $FULL 6-log      log
shot $FULL 7-dark     result --appearance dark
