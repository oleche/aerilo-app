#!/bin/zsh
# Publishes a version of the direct edition:
#   1. builds, signs, notarizes and staples build/Aerilo.dmg   (scripts/make-dmg.sh --notarize)
#   2. creates the GitHub release v<version> with the DMG attached
#   3. writes ../aerilo-site/appcast.json, which the app's "Check for Updates" reads
#
# The site's download button points at
#   https://github.com/oleche/aerilo-app/releases/latest/download/Aerilo.dmg
# so it always serves the newest release with no further change.
#
# Needs the GitHub CLI, signed in (gh auth login), and the notarization setup in make-dmg.sh.
#   scripts/release.sh "What changed in this version."
set -euo pipefail
cd "$(dirname "$0")/.."
NOTES=${1:?Give the release notes as the first argument.}
command -v gh >/dev/null || { echo "Install the GitHub CLI first: https://cli.github.com"; exit 1; }

scripts/make-dmg.sh --notarize
VERSION=$(defaults read "$PWD/build/Build/Products/Release/Aerilo.app/Contents/Info" CFBundleShortVersionString)

gh release create "v$VERSION" build/Aerilo.dmg --repo oleche/aerilo-app --title "Aerilo $VERSION" --notes "$NOTES"

python3 - "$VERSION" "$NOTES" <<'PY'
import json, sys
json.dump({"version": sys.argv[1],
           "url": f"https://github.com/oleche/aerilo-app/releases/download/v{sys.argv[1]}/Aerilo.dmg",
           "notes": sys.argv[2]},
          open("../aerilo-site/appcast.json", "w"), indent=2)
PY
# The download buttons' fallback number (the page also reads appcast.json when it loads).
sed -i '' -E "s#(<span data-version>)[^<]*#\\1$VERSION#" ../aerilo-site/index.html ../aerilo-site/best-mac-cleaner.html
echo "Released v$VERSION. Commit and publish ../aerilo-site/appcast.json so existing copies see the update."
