#!/bin/zsh
# Points TeleNotch at your GitHub repo, in every place that needs it.
# Usage: ./scripts/set-repo.sh your-github-name/telenotch
set -euo pipefail
cd "${0:A:h}/.."
REPO="${1:?usage: ./scripts/set-repo.sh owner/repo}"
[[ "$REPO" == */* ]] || { echo "Use the form owner/repo"; exit 1; }
echo "$REPO" > github-repo.txt
# The app checks this feed for updates; "latest" always points at the newest release.
echo "https://github.com/$REPO/releases/latest/download/appcast.xml" > feed-url.txt
# The landing page reads releases (and their notes) from this repo.
printf 'window.TELENOTCH_REPO = "%s";\n' "$REPO" > site/config.js
echo "Repo set to $REPO. Rebuild the app (./build.sh) so it checks this feed."
