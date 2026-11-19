# Publishing Aerilo

What is already done, what is left, and who does each step. Commands are explained in [DEVELOPING.md](DEVELOPING.md).

## Where things stand

| Channel | State |
|---|---|
| Mac download (DMG) | Published. Signed, notarized, on GitHub Releases. Anyone can download and run it. |
| Website | Written, not hosted yet. |
| App Store listing (Mac, iPhone and iPad, Apple TV, Vision Pro) | Text, categories, screenshots and review notes are uploaded. Version 1.0.1, "Prepare for Submission". |
| App Store builds | Uploaded for all four platforms (version 1.0.1) and processed. Not yet attached to the listing. |
| App Store review | Not submitted. |

## What each edition can do

| | Downloaded from aerilo.app | From the App Store |
|---|---|---|
| Platforms | Mac | Mac, iPhone, iPad, Apple TV, Vision Pro |
| Mac: Breathe, health score, per-app memory and processor, stuck apps, growing memory, photo tidying, assistant, log | yes | yes |
| Mac: quit an app from Aerilo | yes | no: it brings the app forward |
| Mac: network use per app | yes | no |
| Mac: remove unusable Xcode simulators | yes | no |
| Mac: clear caches | yes | after allowing the Home folder once |
| Devices: photo tidying, device screen, log | | yes |
| Updates | checks aerilo.app daily and offers the new download | through the App Store |
| Price | free | free |

The three "no" rows are Apple's rules for App Store apps, confirmed by testing inside the sandbox.

## Permissions each edition asks for

Nothing is requested at install. Each permission is asked the first time it is needed, and every one except the first row of each edition is optional.

| Edition | Permission | Why | How it is asked |
|---|---|---|---|
| Mac App Store | Home folder | To measure and clear caches inside it | A folder chooser, once |
| Mac App Store | Temporary folder (optional) | To clear leftovers outside the Home folder | A folder chooser, once |
| Mac download | none required | It runs with the user's own file access | |
| Mac download | Full Disk Access (optional) | Avoids a prompt per app when clearing other apps' leftovers | The user turns it on in System Settings |
| Both Mac editions | Photos (optional) | Only when the user opens Photos and starts a look | System prompt |
| Both Mac editions | Notifications (optional) | Low-space warning | System prompt, when switched on |
| Both Mac editions | Open at login (optional) | Keeps the menu bar icon after a restart | A switch in Settings |
| iPhone, iPad, Apple TV, Vision Pro | Photos | The whole purpose of the app | System prompt on the first breath |

Declared to Apple: the photo-library purpose text, the App Sandbox with user-selected files, bookmarks and Photos (Mac App Store), and a privacy manifest that says no data is collected and names the three system readings used (free storage, time since restart, the app's own settings).

## What could get it rejected, and what was done about each

Nobody can promise an approval; this is the list of known causes and where Aerilo stands.

| Risk | Status |
|---|---|
| Private or undocumented system calls | None. Photo sizes use documented calls; the Mac readings use the public process-information calls. |
| Mentioning another, fuller edition or an outside download | Removed from the App Store text and from the App Store build's interface. |
| Self-updating code in an App Store build | Compiled out; the App Store build contains no update check. |
| Claiming to speed up an iPhone or free its memory | The device text says plainly that it does not. |
| Asking for a whole folder on the Mac | Still the most likely question. The review note explains it, and nothing is read before the user chooses the folder. |
| Too little function on Apple TV or Vision Pro | A real risk: there the app is photo tidying and a device screen only. Submit iPhone and Mac first; if Apple objects to these two, they can be withdrawn without affecting the others. |
| Screenshots that don't match the app | They are taken from the app itself; the App Store Mac set is taken in App Store mode. |
| Support or privacy page not reachable | Blocks submission until the site is hosted. |
| Missing export-compliance answer | Declared in the build (only standard hashing is used). |
| Crash on launch during review | Each build launches in its simulator; the Mac editions pass their self-tests. No TestFlight run by a person yet. |

## Steps left

### 1. Host the website
The app's Help links, the App Store listing (support and privacy pages) and the update check all point at aerilo.app. Apple opens the support and privacy pages during review.

- The site is plain files in the `aerilo-site` repository; there is nothing to build.
- Point the aerilo.app domain at any static host (GitHub Pages, Cloudflare Pages, Netlify). The `CNAME` file already says `aerilo.app`.
- After it is live, open `https://aerilo.app/support.html`, `/privacy.html` and `/appcast.json` to check them.

### 2. Upload the builds (done for 1.0.1)
All four builds are in App Store Connect. To upload a newer one, run these at the Mac, signed in, and answer any keychain dialog with "Always Allow":

```sh
fastlane mac beta                       # Mac
fastlane devices_beta platform:ios      # iPhone and iPad
fastlane devices_beta platform:tvos     # Apple TV
fastlane devices_beta platform:visionos # Vision Pro
```

A build appears under TestFlight after a few minutes of processing.

### 3. Try the builds from TestFlight
Things that have not been checked by a person on a real device:

- Mac App Store edition: allow the Home folder, run Breathe, open Activity, press "Show" on an app.
- iPhone: run Breathe on your own photo library, review a group, delete one item.
- Apple TV and Vision Pro: open the app and run a breath.

### 4. Fill in what only the account holder can
In App Store Connect, on the Aerilo app:

- **App Privacy**: choose "Data Not Collected".
- **Age Rating**: answer the questionnaire (everything "None").
- **Pricing and Availability**: Free, and the countries you want.
- **App Review Information**: check the contact name and phone. They were copied from another app on the team; the email is info@geekcow.com.
- For each platform's version: under **Build**, select the uploaded build.

### 5. Submit
On each platform's version page, press **Add for Review**, then **Submit**. Platforms are reviewed separately, so one can go first.

Review usually takes one to three days. The likeliest question is about the Mac edition asking for the Home folder; the review note already explains it.

### 6. After approval
- Put the App Store link on the site: `https://apps.apple.com/app/id6836768428` (there is a marked place in `index.html`).
- Announce it.

## Releasing an update later

1. Change `VERSION` and `BUILD` in `scripts/make-project.py` and run it.
2. Run the tests (`--selftest`, `--breathe-test`, `scripts/test-ios.sh`).
3. `scripts/release.sh "What changed."` publishes the DMG and rewrites `appcast.json` in the site repository; commit and publish the site so existing copies see the update.
4. `fastlane mac release` and `fastlane devices_release platform:…` upload the store builds and listing; then submit in App Store Connect.
