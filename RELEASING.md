# Releasing Loomo

Loomo ships as a signed, notarized disk image on GitHub Releases. People drag it to Applications and it opens
with only macOS's usual "downloaded from the internet" question. There's no server: parts search runs in the
app with each user's own API keys, and the MCP tools run on their Mac.

## One-time setup

1. **Signing team.** Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set your Team ID
   (developer.apple.com ▸ Account ▸ Membership details). Git ignores that file.
2. **Developer ID certificate.** Xcode ▸ Settings ▸ Accounts ▸ your team ▸ Manage Certificates ▸ + ▸
   **Developer ID Application**. Only the account holder can create one. It's what lets a downloaded app open
   without "unidentified developer" warnings.
3. **Update signing key.** Sparkle checks every update against the public key in `App/Resources/Info.plist`
   (`SUPublicEDKey`). The private half lives in your login keychain; make your own with
   `generate_keys --account loomo` (in Sparkle's `bin` folder) if you fork Loomo, and put its public key in
   Info.plist. Back it up with `generate_keys --account loomo -x loomo-sparkle.key`: without it, existing
   installs can't take updates.
4. **Notarization credentials (optional)**, only for signing the disk image itself, stored in your keychain once:
   ```sh
   xcrun notarytool store-credentials loomo-notary --apple-id you@example.com --team-id TEAMID
   ```
   It asks for an app-specific password, which you make at account.apple.com ▸ Sign-In and Security.
5. **iCloud (optional).** The first signed build registers the iCloud container `iCloud.com.loomo.Loomo` for
   your team. If you fork Loomo under another team, change the container id in `App/Resources/*.entitlements`,
   `App/Resources/Info.plist`, `CloudDocuments.swift` and `TeamLibrary.swift`; iCloud container ids are global.

## Making a release

1. Set the version: `MARKETING_VERSION` in Loomo.xcodeproj (the build number follows from it: 0.4.1 is 401).
2. Build, sign and notarize:
   ```sh
   scripts/make-dmg.sh
   ```
   It archives a universal build (Apple silicon and Intel), signs it with Developer ID through Xcode's account,
   notarizes and staples the app, and builds the disk image (Loomo plus an Applications shortcut). It then signs
   the image for Sparkle and writes `appcast.xml`. With `LOOMO_NOTARY_PROFILE` and a local Developer ID
   certificate it signs and notarizes the image too. Output: `build/dmg/Loomo-<version>.dmg`, `appcast.xml`
   and the SHA-256.
3. Create a GitHub release for the tag `v<version>` and attach **both** the DMG and `appcast.xml`. Installed
   copies read `releases/latest/download/appcast.xml`, so an update reaches people as soon as it's the latest
   release.

### From GitHub Actions

`.github/workflows/release.yml` does all of this when you push a tag (`git tag v0.5.0 && git push origin v0.5.0`).
It needs these repository secrets: `TEAM_ID`; an App Store Connect API key with the Admin role (`ASC_KEY_P8`, the
.p8 file's contents, plus `ASC_KEY_ID` and `ASC_ISSUER_ID`), which signs with the cloud-managed Developer ID
certificate and notarizes; and `SPARKLE_PRIVATE_KEY`, the exported update key.

`scripts/make-dmg.sh --test` builds the same disk image unsigned, to check the layout locally. Don't publish it:
on other Macs, Gatekeeper blocks it. The DMG window shows an arrow from Loomo to Applications (`Design/DMG/background.tiff`, drawn by
`Design/DMG/make-background.swift`). Arranging it scripts Finder, which macOS asks permission for once;
`LOOMO_DMG_LAYOUT=0` skips it.

## What makes installation smooth

- **Developer ID signing and notarization**: no "unidentified developer" or "can't check for malicious
  software" blocks. Stapling means the first launch works offline too.
- **Hardened runtime** on every executable, including the embedded `crimp` tool.
- **Universal binaries**: one download for every Mac.
- **No installers, helpers or login items**: nothing for macOS to ask permission for at install.
- **Move to Applications**: run from the disk image or Downloads, Loomo offers to move itself, so macOS stops
  running it from a hidden temporary copy and Claude's path to its MCP tool stays put.
- **Keychain**: API keys are stored as the app's own Keychain items, so there are no password prompts.

## Later

- **Delta updates.** Sparkle can ship small binary diffs between versions with `generate_appcast`.

## Mac App Store (optional)

The code also builds a sandboxed App Store version: `scripts/release.sh appstore`, with `LOOMO_UPLOAD=1` to
upload to App Store Connect for TestFlight. It sandboxes the app, its extensions and `crimp`, which share
data through an App Group. Not needed for GitHub distribution.
