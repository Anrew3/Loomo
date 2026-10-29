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
3. **Notarization credentials**, stored in your keychain once:
   ```sh
   xcrun notarytool store-credentials loomo-notary --apple-id you@example.com --team-id TEAMID
   ```
   It asks for an app-specific password, which you make at account.apple.com ▸ Sign-In and Security.
4. **iCloud (optional).** The first signed build registers the iCloud container `iCloud.com.loomo.Loomo` for
   your team. If you fork Loomo under another team, change the container id in `App/Resources/*.entitlements`,
   `App/Resources/Info.plist`, `CloudDocuments.swift` and `TeamLibrary.swift`; iCloud container ids are global.

## Making a release

1. Set the version: `MARKETING_VERSION` in Loomo.xcodeproj (the build number is the commit count).
2. Build, sign and notarize:
   ```sh
   LOOMO_NOTARY_PROFILE=loomo-notary scripts/make-dmg.sh
   ```
   It archives a universal build (Apple silicon and Intel), signs it with Developer ID, notarizes and staples
   the app, builds the disk image (Loomo plus an Applications shortcut), then signs, notarizes and staples the
   image. Output: `build/dmg/Loomo-<version>.dmg` and its SHA-256.
3. Create a GitHub release for the tag (`git tag v0.5.0 && git push --tags`), attach the DMG, and paste the
   SHA-256 into the notes.

`scripts/make-dmg.sh --test` builds the same disk image unsigned, to check the layout locally. Don't publish it:
on other Macs, Gatekeeper blocks it. `LOOMO_DMG_LAYOUT=1` arranges the DMG window (it scripts Finder, which
macOS asks permission for once).

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

- **Automatic updates.** [Sparkle](https://sparkle-project.org) is the standard for apps distributed outside
  the App Store: it reads an appcast feed (which can live in GitHub Releases) and installs signed updates.
- **CI releases.** A GitHub Actions workflow can run `make-dmg.sh` on a macOS runner from a tag. It needs the
  Developer ID certificate (exported as a .p12) and an App Store Connect API key as repository secrets.

## Mac App Store (optional)

The code also builds a sandboxed App Store version: `scripts/release.sh appstore`, with `LOOMO_UPLOAD=1` to
upload to App Store Connect for TestFlight. It sandboxes the app, its extensions and `crimp`, which share
data through an App Group. Not needed for GitHub distribution.
