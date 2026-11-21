# TeleNotch

A teleprompter that lives in your MacBook's notch, with a meeting copilot.

- **Teleprompter:** your script scrolls in a black panel that grows out of the notch, right under the camera. The panel asks macOS to leave it out of screen shares and recordings.
- **Copilot:** TeleNotch listens to your mic (**Me**) and to everything your Mac plays (**Others**: Zoom, Meet, Teams, anything), and transcribes both on your Mac. Every 45 s it updates running notes of the meeting with Claude. When you lose the thread and get asked something, press **⌃⌥↩**: Claude writes, as you and in the first person, a short answer that takes a clear side. You read it straight off the notch.

## Shortcuts
| | |
|---|---|
| ⌃⌥Space | Show / hide the panel |
| ⌃⌥P | Play / pause the script (or close an answer) |
| ⌃⌥↑ / ⌃⌥↓ | Scroll faster / slower |
| ⌃⌥← | Jump back a few lines |
| ⌃⌥E | Edit the script |
| ⌃⌥L | Start / stop listening |
| ⌃⌥↩ | **Answer for me.** Press again to go back to the script |
| ⌃⌥C | Catch me up (what's going on?) |
| ⌃⌥/ | Show every shortcut in the notch |
| ⌃⌥, | Settings |

You rarely need to remember these: the bottom of the notch always shows the keys that make sense right now, and the notch has clickable buttons (Listen, play/pause, Answer, and a ⋯ menu with everything else). Scroll speed is in words per minute (⌃⌥↑/↓ change it by 10).

## Setup
`./build.sh` then `open build/TeleNotch.app`. The first launch opens a Welcome guide that walks through the API key (with a test), microphone / system audio / speech model (each with a check), the shortcuts, consent, and a demo answer. Reopen it any time from the ⋯ menu or Settings.

Errors and status (no API key, permission off, mic-only mode, offline…) show up as a message at the bottom of the notch, with a button to fix them.

## Releases, updates and the landing page
Everything is hosted on GitHub: each version is a GitHub Release (the app zip + the update feed), and the landing page in `site/` runs on GitHub Pages and shows release notes straight from those releases.

**One-time setup**
1. Create a **public** GitHub repo (e.g. `telenotch`) and push this folder to it.
2. `./scripts/set-repo.sh your-name/telenotch`: points the app's update feed, the release script and the landing page at it.
3. Install and sign in to the GitHub CLI: `brew install gh` then `gh auth login`.
4. In the repo: Settings → Pages → Source: **GitHub Actions**. The page goes live at `https://your-name.github.io/telenotch/` after the next push.

**Every release**
1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Info.plist`.
2. Write `release-notes/<version>.md` (Markdown).
3. `./release.sh` builds, signs, and publishes GitHub release `v<version>` with `TeleNotch.zip` + `appcast.xml`. (`./release.sh --dry-run` does everything but publish.)

Installed copies check daily and install the update when they quit; the landing page's download button and release notes update by themselves.

Updates are signed with the Sparkle key in your login Keychain (account `telenotch`); installed copies only accept updates signed with it, so keep the backup safe.

Until TeleNotch is signed with a Developer ID and notarized, other people's Macs will block it (the download section on the page explains *Open Anyway*). When you have one: `./release.sh "Developer ID Application"` plus a notarization step.

Use headphones: with speakers, the mic also picks up the other people.

## Self-test
Each part of the pipeline can be run on its own; results go to the text file you name.
```
say -o /tmp/q.aiff "Should we go four days in the office or two anchor days? What do you think?"
open -W -n build/TeleNotch.app --args --selftest claude /tmp/claude.txt      # notes, answers, catch-up (uses your API key)
open -W -n build/TeleNotch.app --args --selftest speech /tmp/speech.txt /tmp/q.aiff
open -W -n build/TeleNotch.app --args --selftest system /tmp/system.txt /tmp/q.aiff   # plays through the speakers
open -W -n build/TeleNotch.app --args --selftest mic    /tmp/mic.txt    /tmp/q.aiff
open -W -n build/TeleNotch.app --args --selftest full   /tmp/full.txt   /tmp/q.aiff   # everything together
```

## Privacy
Audio never leaves the Mac. Transcript text goes to the Claude API when you press Answer / Catch up, and every 45 s for the running notes while listening. Recording laws differ: in some places everyone on a call has to agree to it.

Requires macOS 26+. MIT licensed; notch and panel code adapted from [NotchPeek](https://github.com/morehavoc/notchpeek).
