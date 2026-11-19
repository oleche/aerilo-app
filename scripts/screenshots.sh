#!/bin/zsh
# Makes screenshots of the real app window (title bar, toolbar and all) from the app's demo mode.
# Demo mode uses sample data; it reads and deletes nothing.
#   artwork/raw/mac-store/  App Store mode (--as-store)      -> fastlane/screenshots/en-US/
#   artwork/raw/mac/        the download edition             -> marketing/screenshots/
# The raw window pictures are then finished by scripts/make-art.swift.
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
  local win; win=$(awk '/WINDOW/{print $2}' "$log")
  # The window server sometimes needs a moment after the window appears.
  local try
  for try in 1 2 3 4; do
    screencapture -o -x -l "$win" "$out/$name.png" 2>/dev/null && break
    sleep 1
  done
  [[ -s "$out/$name.png" ]] || { echo "Could not capture $name"; kill $pid; return 1; }
  kill $pid; wait $pid 2>/dev/null || true
  sips -z 1800 2880 "$out/$name.png" >/dev/null   # the Mac App Store accepts 2880x1800
  return 0
}
STORE=artwork/raw/mac-store
FULL=artwork/raw/mac
shot $STORE 1-breathe  exhale --as-store
shot $STORE 2-result   result --as-store
shot $STORE 3-activity activity --as-store
shot $STORE 4-storage  storage --as-store
shot $STORE 5-photos   photos --as-store
shot $STORE 6-log      log --as-store
shot $STORE 7-dark     result --appearance dark --as-store

shot $FULL 1-breathe  exhale
shot $FULL 2-result   result
shot $FULL 3-activity activity
shot $FULL 4-storage  storage
shot $FULL 5-network  network
shot $FULL 6-photos   photos
shot $FULL 7-log      log
shot $FULL 8-dark     result --appearance dark

# Headline, description and the finished look.
swift scripts/make-art.swift shots
