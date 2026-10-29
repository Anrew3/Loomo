#!/usr/bin/env bash
# Builds Loomo for release. One codebase, two channels:
#
#   scripts/release.sh appstore       Mac App Store / TestFlight: sandboxed, App Group, exported for App Store Connect.
#                                     With LOOMO_UPLOAD=1 it uploads the build, which then appears in TestFlight.
#   scripts/release.sh direct         Use scripts/make-dmg.sh instead: it builds the notarized DMG for GitHub Releases.
#   scripts/release.sh sandbox-test   The App Store build (sandbox and App Group), development-signed and not
#                                     installed, to try locally. Output: build/SandboxTest.noindex/Loomo.app
#
# Account settings come from the environment, never from this repo:
#   LOOMO_TEAM_ID         Apple Developer Team ID; defaults to the one in Config/Local.xcconfig.
#   LOOMO_NOTARY_PROFILE  direct: a notarytool keychain profile, made once with
#                         xcrun notarytool store-credentials loomo-notary --apple-id YOU --team-id TEAM
#   LOOMO_UPLOAD=1        appstore: upload to App Store Connect after exporting.
#   LOOMO_ASC_KEY_ID, LOOMO_ASC_ISSUER_ID, LOOMO_ASC_KEY_PATH
#                         appstore: optional App Store Connect API key for the upload; otherwise the Apple ID
#                         signed in to Xcode ▸ Settings ▸ Accounts is used.
#   LOOMO_BUILD_NUMBER    Override the build number (default: the number of commits, which only goes up).
set -euo pipefail

CHANNEL="${1:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$HOME/Downloads/Xcode-beta.app/Contents/Developer}"
OUT="$ROOT/build/Release-$CHANNEL"
BUILD_NUMBER="${LOOMO_BUILD_NUMBER:-$(git rev-list --count HEAD)}"
VERSION="$(grep -m1 'MARKETING_VERSION = ' Loomo.xcodeproj/project.pbxproj | sed 's/.*= *\(.*\);/\1/')"

die() { echo "error: $*" >&2; exit 1; }
# Your team, from Config/Local.xcconfig (see Config/Local.xcconfig.example), unless LOOMO_TEAM_ID names another.
LOOMO_TEAM_ID="${LOOMO_TEAM_ID:-$(sed -n 's/^DEVELOPMENT_TEAM *= *\([A-Z0-9]*\).*/\1/p' Config/Local.xcconfig 2>/dev/null | head -1)}"
need_team() { [ -n "${LOOMO_TEAM_ID:-}" ] || die "set LOOMO_TEAM_ID to your Apple Developer Team ID"; }

if [ -n "$(git status --porcelain -- App Packages Extensions Loomo.xcodeproj)" ]; then
  echo "warning: uncommitted changes in the app's sources; the build number won't identify this build" >&2
fi

case "$CHANNEL" in
  appstore)
    need_team
    SETTINGS=(LOOMO_ENTITLEMENTS_SUFFIX=-AppStore 'LOOMO_APP_GROUP=$(TeamIdentifierPrefix)com.loomo.shared' LOOMO_ICLOUD_SUFFIX=)
    METHOD=app-store-connect
    ;;
  direct)
    exec "$ROOT/scripts/make-dmg.sh"
    need_team
    [ -n "${LOOMO_NOTARY_PROFILE:-}" ] || die "set LOOMO_NOTARY_PROFILE (see the top of this script)"
    SETTINGS=(LOOMO_ICLOUD_SUFFIX=)
    METHOD=developer-id
    ;;
  sandbox-test)
    need_team
    rm -rf "$ROOT/build/SandboxTest.noindex"
    xcodebuild -workspace Loomo.xcworkspace -scheme Loomo -configuration Release \
      -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath build/DerivedData.noindex -allowProvisioningUpdates \
      LOOMO_ENTITLEMENTS_SUFFIX=-AppStore 'LOOMO_APP_GROUP=$(TeamIdentifierPrefix)com.loomo.shared' LOOMO_ICLOUD_SUFFIX= \
      DEVELOPMENT_TEAM="$LOOMO_TEAM_ID" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
      CONFIGURATION_BUILD_DIR="$ROOT/build/SandboxTest.noindex" build 2>&1 | grep -E "error:|\*\* BUILD" || true
    APP="$ROOT/build/SandboxTest.noindex/Loomo.app"
    [ -d "$APP" ] || die "build failed"
    codesign --verify --deep --strict "$APP"
    echo "Built $APP (sandboxed, development-signed, not installed)"
    exit 0
    ;;
  *)
    sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac

rm -rf "$OUT"
mkdir -p "$OUT"
ARCHIVE="$OUT/Loomo.xcarchive"

echo "Archiving Loomo $VERSION ($BUILD_NUMBER) for $CHANNEL…"
xcodebuild archive -workspace Loomo.xcworkspace -scheme Loomo -configuration Release \
  -destination "generic/platform=macOS" -archivePath "$ARCHIVE" -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$LOOMO_TEAM_ID" CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" ${SETTINGS[@]+"${SETTINGS[@]}"} \
  | grep -E "error:|warning: .*(sign|provision|entitlement)|\*\* ARCHIVE" || true
[ -d "$ARCHIVE" ] || die "archive failed (run the xcodebuild line above without the grep to see why)"

DESTINATION=export
[ "$CHANNEL" = appstore ] && [ "${LOOMO_UPLOAD:-}" = 1 ] && DESTINATION=upload
cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>$METHOD</string>
  <key>teamID</key><string>$LOOMO_TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>$DESTINATION</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
EOF

AUTH=()
if [ -n "${LOOMO_ASC_KEY_ID:-}" ]; then
  AUTH=(-authenticationKeyID "$LOOMO_ASC_KEY_ID" -authenticationKeyIssuerID "$LOOMO_ASC_ISSUER_ID" -authenticationKeyPath "$LOOMO_ASC_KEY_PATH")
fi
echo "Exporting ($METHOD, $DESTINATION)…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT/export" -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} | grep -E "error:|\*\* EXPORT|Upload" || true

if [ "$CHANNEL" = appstore ]; then
  if [ "$DESTINATION" = upload ]; then
    echo "Uploaded $VERSION ($BUILD_NUMBER). It appears in App Store Connect ▸ TestFlight after processing (usually 10–30 minutes)."
  else
    echo "Exported to $OUT/export. Upload with LOOMO_UPLOAD=1, or drag the .pkg into Transporter."
  fi
  exit 0
fi

# Direct download: notarize, staple, zip.
APP="$OUT/export/Loomo.app"
[ -d "$APP" ] || die "export failed"
ZIP="$OUT/Loomo-$VERSION-$BUILD_NUMBER.zip"
ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
echo "Notarizing…"
xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile "$LOOMO_NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose "$APP"
ditto -c -k --keepParent "$APP" "$ZIP"
rm "$OUT/notarize.zip"
echo "Ready to publish: $ZIP"
