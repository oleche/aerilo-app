# Aerilo

One button, **Breathe**. On a Mac it clears what the Mac no longer needs, finds what is slowing it down, and uses Apple's on-device model to say which fix helps most. On iPhone, iPad, Apple TV and Vision Pro the same button tidies the photo library. Free, open source, and nothing leaves your device.

Native SwiftUI with Liquid Glass. Apple frameworks only, no third-party code. Needs macOS, iOS, tvOS or visionOS 26 or later.

**Download for Mac:** [latest release](https://github.com/oleche/aerilo-app/releases/latest/download/Aerilo.dmg) · **Site:** aerilo.app

## What it does

| | Mac download | Mac App Store | iPhone, iPad, Apple TV, Vision Pro |
|---|---|---|---|
| One-tap Breathe with step-by-step status | yes | yes | yes |
| Health score out of 100, with reasons | yes | yes | |
| Memory and processor use per app; stuck apps; growing memory | yes | yes | not allowed by the system |
| Quit an app from Aerilo | yes | brings it forward for you to quit | |
| Look inside an app: tabs, extensions, language tools, each with its memory | yes, and end one | yes, to see | |
| Network use per app | yes | not allowed by the sandbox | |
| Clear caches in the Home folder, including caches of apps that are closed | yes | after you allow the folder | |
| Large-file finder (moving to the Trash is always your click) | yes | yes | |
| Clear the Chrome signing copy and test leftovers | yes | after you allow the temp folder | |
| Remove unusable simulators and unused simulator versions | yes | not allowed by the sandbox | |
| Photo tidying: duplicates, similar shots, old screenshots, WhatsApp media, screen recordings, large videos | yes | yes | yes |
| On-device assistant | yes | yes | yes, where the device has Apple Intelligence |
| Activity log with export | yes | yes | yes |
| Menu bar panel, low-space notification | yes | yes | |
| Siri and Shortcuts actions | yes | yes | yes |
| Widget | health, memory, storage | health, memory, storage | free storage and memory (iPhone, iPad) |
| Update check | daily, against aerilo.app | by the App Store | by the App Store |

"Not allowed" rows were checked by running a probe inside the sandbox; see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Safety

- Aerilo measures first, then deletes, and reports what was actually removed.
- It deletes only inside known cache locations, never through a symlinked folder, and skips an item while the app that owns it is working.
- Breathe never quits an app and never touches documents. Photos are deleted only after you review them and the system confirms; they stay in Recently Deleted for 30 days.
- No keyboard shortcut starts a clean-up. The Siri and Shortcuts action opens Aerilo and asks before it clears anything.
- The assistant can reorder and explain findings; it cannot add an action.
- Every measurement, clean-up, skip and deletion is written to a log. Each entry is chained to the one before, which shows accidental damage and casual edits; it is a consistency check, not a tamper-proof seal.

## For developers

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): how the code works, file by file, including [what photo tidying does and how](docs/ARCHITECTURE.md#photo-tidying-all-platforms).
- [docs/DEVELOPING.md](docs/DEVELOPING.md): building, the tests, screenshots, and releasing.
- [docs/PUBLISHING.md](docs/PUBLISHING.md): what is published, what is left, and the steps to the App Store.

Quick start:

```sh
xcodebuild -project Aerilo.xcodeproj -scheme AeriloDirect -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/Aerilo.app --args --demo          # sample data: reads and deletes nothing
build/Build/Products/Debug/Aerilo.app/Contents/MacOS/Aerilo --selftest
build/Build/Products/Debug/Aerilo.app/Contents/MacOS/Aerilo --breathe-test
scripts/test-ios.sh
```

Without `--demo` the Mac app is live: Breathe really clears caches.

## Support

info@geekcow.com
