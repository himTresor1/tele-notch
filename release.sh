#!/bin/zsh
# Publishes a TeleNotch release on GitHub: the app, its update feed, and release notes.
#
#   1. Bump CFBundleShortVersionString (e.g. 0.3.0) and CFBundleVersion (e.g. 3) in Info.plist.
#   2. Write the notes in release-notes/<version>.md (Markdown; shown on the landing page and in the update window).
#   3. ./release.sh            → builds, signs, and publishes release v<version> on GitHub.
#      ./release.sh --dry-run  → does everything except publishing; files land in release/.
#
# Needs: ./scripts/set-repo.sh owner/repo (once), and the GitHub CLI signed in (brew install gh; gh auth login).
# Signing identity: "Apple Development" for now; pass "Developer ID Application" once you have it.
set -euo pipefail
cd "${0:A:h}"
DRY=0; ID="Apple Development"
for a in "$@"; do [[ "$a" == "--dry-run" ]] && DRY=1 || ID="$a"; done

[ -f github-repo.txt ] || { echo "Run ./scripts/set-repo.sh owner/repo first."; exit 1; }
REPO=$(tr -d '[:space:]' < github-repo.txt)
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' Info.plist)
TAG="v$VERSION"
NOTES="release-notes/$VERSION.md"
[ -s "$NOTES" ] || { echo "Write the release notes first: $NOTES"; exit 1; }

if (( ! DRY )); then
  command -v gh >/dev/null || { echo "Install the GitHub CLI: brew install gh, then gh auth login"; exit 1; }
  gh auth status >/dev/null 2>&1 || { echo "Sign in to GitHub first: gh auth login"; exit 1; }
  if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    echo "$TAG is already released. Bump the version in Info.plist."; exit 1
  fi
fi

echo "→ Building TeleNotch $VERSION ($BUILD), signed with: $ID"
./build.sh "$ID"

# One folder per release: the zip + its notes → appcast.xml that points at this release's download.
rm -rf release && mkdir -p release
ditto -c -k --keepParent build/TeleNotch.app release/TeleNotch.zip
cp "$NOTES" release/TeleNotch.md
vendor/sparkle-tools/bin/generate_appcast --account telenotch --embed-release-notes \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
  --link "https://${REPO%%/*}.github.io/${REPO#*/}/" \
  -o release/appcast.xml release
rm release/TeleNotch.md
grep -q "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" release/appcast.xml \
  || { echo "appcast.xml doesn't list $VERSION"; exit 1; }
sig=$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' release/appcast.xml | head -1)
vendor/sparkle-tools/bin/sign_update --account telenotch --verify release/TeleNotch.zip "$sig" >/dev/null \
  && echo "→ Update signature verified"

if (( DRY )); then
  echo "Dry run done: release/TeleNotch.zip and release/appcast.xml (nothing published)."
  exit 0
fi

echo "→ Publishing $TAG to github.com/$REPO"
gh release create "$TAG" release/TeleNotch.zip release/appcast.xml \
  --repo "$REPO" --title "TeleNotch $VERSION" --notes-file "$NOTES"
echo "Done. Download: https://github.com/$REPO/releases/latest/download/TeleNotch.zip"
