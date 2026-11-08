# In-app updates

GameEdge updates itself with [Sparkle 2](https://sparkle-project.org), the same setup as Flusso and Immich Gallery.

## What users see

- **Menu bar › Check for Updates…** and **General › Updates › Check for Updates…** check right away and show the result.
- In **General › Updates**:
  - *Check for updates automatically* (on by default): one check at launch and one a day.
  - *Download and install automatically* (off by default): the update is downloaded silently and installed when the app quits.
- When a new version is available, Sparkle's window opens with the release notes and *Install*, *Remind Me Later* and *Skip This Version*.

Everything lives in `App/Sources/App/AppUpdater.swift`. Debug builds never update.

## How it works

- `App/Info.plist`: `SUFeedURL` (from the `SPARKLE_FEED_URL` build setting), `SUPublicEDKey`, `SUEnableAutomaticChecks`.
- The feed is `https://github.com/IGOLz/GameEdge/releases/latest/download/appcast.xml`: the `appcast.xml` attached to the **latest** GitHub release. Prereleases and drafts are never "latest".
- Each update is the release's `.zip`, signed with an EdDSA key. Sparkle rejects an update whose signature doesn't match `SUPublicEDKey`, or whose Developer ID team differs.
- Sparkle compares `CFBundleVersion` (`CURRENT_PROJECT_VERSION` in `project.yml`): **increase the build number on every release**, together with `MARKETING_VERSION`.

## Publishing a version

```sh
RELEASE_NOTES=notes.md ./scripts/release.sh   # universal build, signing, notarization, appcast.xml
./scripts/publish.sh                          # GitHub release with dmg, zip, appcast, checksums
```

`release.sh` signs Sparkle's helpers with the Developer ID, notarizes the app and the DMG, downloads the published feed and adds the new version with `generate_appcast` (earlier entries are kept). `publish.sh` creates the release as a draft, uploads the files and only then publishes it, so installed apps never see a feed pointing at a `.zip` that isn't uploaded yet. Use `--prerelease` for a test version that installed apps must not receive.

Notarization uses the `quotadeck-notary` Keychain profile by default. To use another profile or an App Store Connect API key, put the settings in `.release.env` at the repository root (Git ignores it) and keep the `.p8` key in `~/.appstoreconnect/private_keys/`:

```sh
: "${NOTARY_KEY:=$HOME/.appstoreconnect/private_keys/AuthKey_YOUR_KEY_ID.p8}"
: "${NOTARY_KEY_ID:=YOUR_KEY_ID}"
: "${NOTARY_ISSUER:=YOUR_ISSUER_ID}"
```

The DMG is built by `scripts/create-dmg.sh` (background drawn by `scripts/dmg/background.swift`). Finder saves the window layout through AppleScript, so the release must run in a logged-in desktop session with Finder automation allowed.

## Homebrew

After a stable release is published, `publish.sh` runs `scripts/update-homebrew.py` to update the GameEdge cask in `IGOLz/homebrew-tap`. It downloads the published DMG, verifies its SHA-256 against `SHA256SUMS.txt`, and updates the version and checksum. The GitHub CLI account needs write access to the tap. Prereleases skip this step.

If the tap update fails, the GitHub release is already published. Retry only the tap update:

```sh
python3 scripts/update-homebrew.py vX.Y.Z
```

The updater accepts only the latest published stable release and makes no commit if the cask is already current. GameEdge keeps its Sparkle updates; the cask declares `auto_updates true`, so Homebrew users can explicitly update with `brew upgrade --cask --greedy igolz/tap/gameedge`.

## The signing key

The EdDSA private key is in the release Mac's login keychain (item "Private key for signing Sparkle updates", account `ed25519`), shared with Flusso and Immich Gallery. The first time `generate_appcast` uses it, macOS asks for access: choose **Always Allow**.

**Back it up**: if it's lost, installed apps can no longer update themselves.

```sh
build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle-private-key.txt
```
