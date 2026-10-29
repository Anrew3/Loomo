#!/usr/bin/env bash
# Builds the Loomo disk image people download: Loomo.app next to an Applications shortcut, so installing is one
# drag. Signed with Developer ID and notarized, so macOS opens it with only the usual "downloaded from the
# internet" question: no "unidentified developer" or "can't be checked for malicious software" errors.
#
#   scripts/make-dmg.sh           Release DMG: archive, Developer ID signing, notarize and staple the app,
#                                 build the DMG, sign it, notarize and staple it. Output: build/dmg/Loomo-<version>.dmg
#   scripts/make-dmg.sh --test    The same DMG from a local build, unsigned and not notarized, to check the
#                                 layout. macOS will warn about it on other Macs; never publish it.
#
# Release needs (once): Config/Local.xcconfig with your team (copy Config/Local.xcconfig.example), and Xcode signed
# in to that team's Apple account (Xcode ▸ Settings ▸ Accounts). Xcode then signs with a cloud-managed Developer ID
# certificate and sends the app to Apple's notary service with that account: no passwords or keys to set up.
#
# Optional: with a local Developer ID certificate and LOOMO_NOTARY_PROFILE (a notarytool keychain profile from
# xcrun notarytool store-credentials), the disk image itself is signed and notarized too.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$HOME/Downloads/Xcode-beta.app/Contents/Developer}"
TEST=0
[ "${1:-}" = "--test" ] && TEST=1

VERSION="$(grep -m1 'MARKETING_VERSION = ' Loomo.xcodeproj/project.pbxproj | sed 's/.*= *\(.*\);/\1/')"
BUILD_NUMBER="${LOOMO_BUILD_NUMBER:-$(git rev-list --count HEAD)}"
OUT="$ROOT/build/dmg"
STAGE="$OUT/stage.noindex"   # ".noindex": Spotlight never lists the staged copy as a second Loomo
SUFFIX=""
[ $TEST = 1 ] && SUFFIX="-test" || true
DMG="$OUT/Loomo-$VERSION$SUFFIX.dmg"
die() { echo "error: $*" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$STAGE"

if [ $TEST = 1 ]; then
  echo "Building Loomo $VERSION ($BUILD_NUMBER) for a test DMG…"
  xcodebuild -workspace Loomo.xcworkspace -scheme Loomo -configuration Release -destination "generic/platform=macOS" \
    -derivedDataPath build/DerivedData.noindex CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    CONFIGURATION_BUILD_DIR="$OUT/app.noindex" build 2>&1 | grep -E "error:|\*\* BUILD" || true
  APP="$OUT/app.noindex/Loomo.app"
  [ -d "$APP" ] || die "build failed"
else
  TEAM="${LOOMO_TEAM_ID:-$(sed -n 's/^DEVELOPMENT_TEAM *= *\([A-Z0-9]*\).*/\1/p' Config/Local.xcconfig 2>/dev/null | head -1)}"
  [ -n "$TEAM" ] || die "set your team in Config/Local.xcconfig (see Config/Local.xcconfig.example)"
  echo "Archiving Loomo $VERSION ($BUILD_NUMBER), universal (Apple silicon and Intel)…"
  xcodebuild archive -workspace Loomo.xcworkspace -scheme Loomo -configuration Release -destination "generic/platform=macOS" \
    -archivePath "$OUT/Loomo.xcarchive" -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic \
    CODE_SIGN_IDENTITY="Apple Development" LOOMO_ICLOUD_SUFFIX= CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    | grep -E "error:|\*\* ARCHIVE" || true
  [ -d "$OUT/Loomo.xcarchive" ] || die "archive failed"
  options() {  # $1: export | upload
    cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>$1</string>
</dict></plist>
EOF
  }
  if [ -z "${LOOMO_NOTARY_PROFILE:-}" ]; then
    echo "Signing with Developer ID and sending to Apple's notary service (Xcode's account)…"
    options upload
    xcodebuild -exportArchive -archivePath "$OUT/Loomo.xcarchive" -exportPath "$OUT/upload.noindex" \
      -exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates | grep -E "error:|Uploaded|\*\* EXPORT" || true
    echo "Waiting for Apple to notarize (usually a few minutes)…"
    for _ in $(seq 1 60); do
      if xcodebuild -exportNotarizedApp -archivePath "$OUT/Loomo.xcarchive" -exportPath "$OUT/notarized.noindex" >/dev/null 2>&1; then break; fi
      sleep 30
    done
    APP="$OUT/notarized.noindex/Loomo.app"
    [ -d "$APP" ] || die "notarization didn't finish within 30 minutes; check Xcode ▸ Window ▸ Organizer"
  else
    echo "Signing with Developer ID…"
    options export
    xcodebuild -exportArchive -archivePath "$OUT/Loomo.xcarchive" -exportPath "$OUT/export.noindex" \
      -exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates | grep -E "error:|\*\* EXPORT" || true
    APP="$OUT/export.noindex/Loomo.app"
    [ -d "$APP" ] || die "export failed"
    echo "Notarizing the app…"
    ditto -c -k --keepParent "$APP" "$OUT/app.zip"
    xcrun notarytool submit "$OUT/app.zip" --keychain-profile "$LOOMO_NOTARY_PROFILE" --wait
    rm "$OUT/app.zip"
  fi
  # Stapled, so the first launch passes Gatekeeper even offline.
  xcrun stapler staple "$APP" >/dev/null 2>&1 || true
  xcrun stapler validate "$APP" >/dev/null || die "the app has no notarization ticket"
  spctl --assess --type execute "$APP" || die "Gatekeeper rejects the app"
fi

echo "Building the disk image…"
ditto "$APP" "$STAGE/Loomo.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Loomo" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$OUT/rw.dmg" >/dev/null 2>&1
ATTACH="$(hdiutil attach -readwrite -noverify -noautoopen -nobrowse "$OUT/rw.dmg" 2>/dev/null)"
DEVICE="$(echo "$ATTACH" | awk '/Apple_HFS/ {print $1; exit}')"
[ -n "$DEVICE" ] || die "couldn't mount the disk image"
# Optional window layout (LOOMO_DMG_LAYOUT=1): the app on the left, Applications on the right. It scripts Finder,
# which macOS asks permission for the first time, so it's off by default; the plain layout works the same.
if [ "${LOOMO_DMG_LAYOUT:-}" = 1 ]; then osascript <<EOF >/dev/null 2>&1 || echo "note: couldn't arrange the DMG window; using the default layout"
tell application "Finder"
  tell disk "Loomo"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 120, 760, 460}
    set opts to icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set position of item "Loomo.app" of container window to {140, 160}
    set position of item "Applications" of container window to {420, 160}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF
fi
sync
hdiutil detach "$DEVICE" -quiet 2>/dev/null || hdiutil detach "$DEVICE" -force -quiet
hdiutil convert "$OUT/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null 2>&1 || die "couldn't compress the disk image"
rm -rf "$OUT/rw.dmg" "$STAGE"

if [ $TEST = 0 ]; then
  # The app inside is notarized and stapled, which is what Gatekeeper checks. Sign and notarize the disk image
  # too when a local Developer ID certificate and notarytool profile are available.
  if security find-identity -v -p codesigning | grep -q "Developer ID Application" && [ -n "${LOOMO_NOTARY_PROFILE:-}" ]; then
    echo "Signing and notarizing the disk image…"
    codesign --sign "Developer ID Application" --timestamp "$DMG"
    xcrun notarytool submit "$DMG" --keychain-profile "$LOOMO_NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
  fi
fi

shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "Ready: $DMG"
[ $TEST = 1 ] && echo "(test build: not signed with Developer ID or notarized; don't publish it)"
exit 0
