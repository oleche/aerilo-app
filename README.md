# Aerilo

A Mac app with one button. **Breathe** clears what the Mac no longer needs, finds what is slowing it down, and uses Apple's on-device model to say which fix helps most. Native SwiftUI with Liquid Glass, macOS 26 or later.

## Two editions, one codebase

| | `Aerilo` (Mac App Store) | `AeriloDirect` (aerilo.app) |
|---|---|---|
| Sandbox | on | off, hardened runtime, notarized |
| One-tap Breathe, health score, menu bar, Siri and Shortcuts | yes | yes |
| On-device assistant | yes | yes |
| Step-by-step status, activity log with export | yes | yes |
| Low-space notification, open at login | yes | yes |
| Daily update check | App Store updates it | yes, against `aerilo.app/appcast.json` |
| Clear caches in the Home folder | yes, after the user allows the folder | yes |
| Memory and processor use per app, stuck apps, growing memory | no | yes |
| Network use per app | no | yes |
| Unusable simulators, unused simulator versions, per-user temp folders | no | yes |

The App Store sandbox hides other processes' usage (`proc_pid_rusage` answers only for Aerilo itself) and cannot run `nettop` or `simctl`. The code checks this at run time (`Env.isSandboxed`) and hides what it cannot do.

## Layout

- `Aerilo/Core/Probes.swift`: memory, processor, storage, network, and per-process sampling.
- `Aerilo/Core/Cleaner.swift`: what can be cleared, when it must be skipped, and the delete guard.
- `Aerilo/Core/Engine.swift`: findings (rules), the Breathe sequence, actions.
- `Aerilo/Core/Advisor.swift`: the on-device model (`SystemLanguageModel`) and the Siri and Shortcuts actions.
- `Aerilo/Core/Audit.swift`: the activity log (`~/Library/Logs/Aerilo/audit.jsonl`), hash-chained so later edits show.
- `Aerilo/Core/Services.swift`: permissions, the low-space notification, and the update check.
- `Aerilo/UI/`: the sky, the orb and its ripples, the detail screens, Log, Settings and the welcome sheet.
- `Aerilo/App/`: app entry, menu bar panel, demo data, self-test.
- `Config/`: entitlements for each edition.

## Safety rules the code enforces

- Measure first, then delete; report what was actually removed.
- Delete only inside known cache locations (`Cleaner.isSafeTarget`), never through a symlinked folder.
- Skip an item while its owner is working (Xcode, npm, Homebrew, Chrome, a Gradle daemon, an updater).
- Simulators only through `simctl delete unavailable`.
- The button never quits an app. Quitting is always a separate click; force quit asks first.
- No keyboard shortcut starts a clean-up, and the first run explains what Breathe does.
- The model can only reorder and explain findings the rules produced.
- Every measurement, clean-up, skip and quit request is written to the activity log; the Log screen exports it as a report.
- Permissions are optional and asked on first launch (macOS has no install-time permissions): Home folder or Full Disk Access, notifications, open at login.

## Build and check

```sh
xcodebuild -project Aerilo.xcodeproj -scheme AeriloDirect -configuration Debug -derivedDataPath build build
build/Build/Products/Debug/Aerilo.app/Contents/MacOS/Aerilo --selftest        # measures, tests the guard, deletes nothing of yours
build/Build/Products/Debug/Aerilo.app/Contents/MacOS/Aerilo --selftest --ai   # also asks the on-device model for a plan
open build/Build/Products/Debug/Aerilo.app --args --demo                      # sample data; reads and deletes nothing
scripts/screenshots.sh                                                         # App Store and marketing screenshots
swift scripts/make-icon.swift Aerilo/Assets.xcassets/AppIcon.appiconset        # redraw the icon
```

## Release

Direct edition (open source download):

```sh
scripts/make-dmg.sh                 # build/Aerilo.dmg, signed with whatever identity Xcode has (for testing)
scripts/release.sh "What changed."  # notarized DMG -> GitHub release v<version> -> ../aerilo-site/appcast.json
```

`release.sh` needs a Developer ID Application certificate, the team's App Store Connect API key (default `~/.appstoreconnect/samio-asc-key.json`, shared with the Samio project; override with `ASC_API_KEY_PATH`), and the GitHub CLI. The site's download button points at `releases/latest/download/Aerilo.dmg`, so it follows each release by itself. Without notarization macOS refuses to open the download.

App Store edition: see `fastlane/Fastfile`. `fastlane mac release` uploads the build, the text in `fastlane/metadata` and the screenshots in `fastlane/screenshots`; it does not submit for review.

Bump `MARKETING_VERSION` in the project before each release; the update check compares it with `appcast.json`.
