# Building, testing and releasing Aerilo

[ARCHITECTURE.md](ARCHITECTURE.md) explains how the code works. This page is the practical side.

## Requirements

- Xcode 27 or later, on macOS 26 or later.
- Simulators for the platforms you want to run: iOS comes with Xcode; `xcodebuild -downloadPlatform tvOS` and `xcodebuild -downloadPlatform visionOS` add the others (about 4 GB and 8 GB).
- `ffmpeg` for the iOS test (it makes one large test video): `brew install ffmpeg`.
- For releases only: a Developer ID Application certificate, the team's App Store Connect API key, and the GitHub CLI.

No package manager and no third-party code: the app uses Apple frameworks only.

## Build and run

```sh
# Mac, download edition
xcodebuild -project Aerilo.xcodeproj -scheme AeriloDirect -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/Aerilo.app --args --demo        # sample data: reads and deletes nothing

# Mac, App Store edition (sandboxed)
xcodebuild -project Aerilo.xcodeproj -scheme Aerilo -configuration Release -derivedDataPath build-mas build

# iPhone and iPad, Apple TV, Vision Pro
xcodebuild -project Aerilo.xcodeproj -scheme AeriloMobile -destination "platform=iOS Simulator,name=iPhone 18 Pro" -derivedDataPath build-ios build
xcodebuild -project Aerilo.xcodeproj -scheme AeriloMobile -destination "platform=tvOS Simulator,name=Apple TV 4K (4th generation)" -derivedDataPath build-ios build
xcodebuild -project Aerilo.xcodeproj -scheme AeriloMobile -destination "platform=visionOS Simulator,name=Apple Vision Pro" -derivedDataPath build-ios build
```

Use `--demo` while working on the interface. Without it the Mac app is live: Breathe really clears caches.

To add a target or change a build setting, edit `scripts/make-project.py` and run it. Do not edit `project.pbxproj` by hand; the next run overwrites it.

## Tests

There are four, and each covers something the others can't.

| Command | What it proves |
|---|---|
| `Aerilo --selftest` | Probes work in this build; the delete guard refuses unsafe paths and accepts every catalogue path; the delete path refuses a folder behind a link and leaves a folder in use; commands return even when the tool ignores the request to stop or leaves a child holding the pipe; a pid with another start time is refused; the log detects an edited entry and entries missing from the end; the timeout returns on stuck work. Run it for both Mac editions: the App Store one runs sandboxed. |
| `Aerilo --selftest --ai` | The on-device model produces a plan and a photo sentence (needs Apple Intelligence). |
| `Aerilo --breathe-test` | The real Breathe sequence, start to finish, on a stand-in home folder: safe caches emptied, optional caches and documents untouched, amount reported, steps shown, log intact. |
| `scripts/test-ios.sh` | The iPhone app on a real photo library in the simulator: finds the planted duplicate picture pair and video pair but not a third video of the same size with different contents, groups three near-identical shots (once, although they carry WhatsApp names) without the unrelated ones, lists the large video unticked, deletes through the system confirmation, and leaves everything alone when the confirmation is declined. |
| `xcodebuild test -scheme AeriloMobile -destination "platform=tvOS Simulator,…"` | The Apple TV app is fully usable with the remote: focus reaches the orb, results, and individual pictures. |

`Aerilo` here means `build/Build/Products/Debug/Aerilo.app/Contents/MacOS/Aerilo` (or the `build-mas` path for the App Store edition).

`--selftest --photo-compare build-ios/test-media` checks both ways of comparing pictures against the generated test set (run `scripts/test-ios.sh` once first to create it).

Not covered by a test: clicking through the Mac interface by hand, the Home-folder and temp-folder permission dialogs in the App Store edition, and Vision Pro beyond launching and rendering. Check those on a device or TestFlight before a release.

## Screenshots and artwork

Two steps: the screenshot scripts photograph the app in demo mode into `artwork/raw/`, then `scripts/make-art.swift` turns each one into a finished picture with a headline and a description.

```sh
scripts/screenshots.sh           # Mac windows            -> fastlane/screenshots, marketing/screenshots
scripts/screenshots-ios.sh       # iPhone and iPad        -> fastlane/screenshots-ios
scripts/screenshots-devices.sh   # Apple TV, Vision Pro   -> fastlane/screenshots-tvos, -visionos
swift scripts/make-art.swift shots    # redo the finished pictures from the raw ones (the scripts above already do this)
swift scripts/make-art.swift header   # App Store header and search-results pictures (marketing/appstore/) and the social card
swift scripts/make-art.swift duo      # drawn artwork for the iPhone Duo's two screens, in marketing/duo/
swift scripts/make-icon.swift Aerilo/Assets.xcassets/AppIcon.appiconset     # Mac icon
swift scripts/make-icon-ios.swift AeriloMobile/Assets.xcassets/AppIcon.appiconset
swift scripts/make-icon-layers.swift AeriloMobile/Assets.xcassets           # Apple TV and Vision Pro icons
```

Headlines and descriptions live in `make-art.swift` (`macCaptions`, `deviceCaptions`). The Mac script photographs real windows, so the screen must be unlocked and the terminal needs Screen Recording permission. The simulator scripts work with the screen locked. All screenshots use demo data, with drawn sample pictures in place of photos.

The pictures in `marketing/appstore/` follow Apple's sizes exactly, which App Store Connect enforces: header 3840×1646, search results 3840×2560, universal 5244×2950, PNG with no transparency, and the artwork kept inside each one's safe area. They are uploaded by hand in App Store Connect (the version's page, "Header and Search Results"); they apply to iPhone and iPad only.

## Releasing

Set the version in one place: `VERSION` and `BUILD` at the top of `scripts/make-project.py`, then run it.

**Mac download (DMG on GitHub Releases)**

```sh
scripts/make-dmg.sh                 # build/Aerilo.dmg, for local testing
scripts/make-dmg.sh --notarize      # signed with Developer ID (widget first, then the app), notarized, stapled
scripts/release.sh "What changed."  # the above, then a GitHub release and ../aerilo-site/appcast.json
```

The site's download button points at `releases/latest/download/Aerilo.dmg`, so it follows each release. Existing copies learn about it from `appcast.json`, so commit and publish the site after a release.

**App Store**

```sh
fastlane mac beta                         # Mac App Store build to TestFlight
fastlane mac release                      # build, text (fastlane/metadata) and screenshots; does not submit
fastlane devices_beta platform:ios        # or tvos, visionos
fastlane devices_release platform:ios     # text from fastlane/metadata-devices
```

Both use the team's App Store Connect API key: set `ASC_API_KEY_PATH` to its fastlane JSON file, or keep that file in `~/.appstoreconnect`. Neither lane submits for review; that stays a deliberate step in App Store Connect.

## Conventions

- Comments say why, in plain words. If a number came from a measurement, the comment says so.
- User-facing text is plain English with no jargon: "moved to disk", not "swap".
- Anything that deletes, quits or sends must be logged with `Audit.record` and shown to the user.
- New cleanable items go in `Cleaner.items()` with a blocker, and their location must be accepted by `Cleaner.isSafeTarget`. `--selftest` fails if it isn't.
- Before changing a threshold in `PhotoScanner.alike` or `ProcessProbe.growth`, measure with the test media and say what you measured.
