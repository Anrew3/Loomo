#!/bin/bash
# Builds Loomo.app with Xcode (Loomo.xcworkspace, scheme Loomo) into ./build.
# Usage: scripts/build-app.sh [debug|release] [--test] [--install]
#   --test     run the test plan first
#   --install  copy the app to /Applications (replacing any previous copy)
# Version, bundle id, signing, Info.plist, icon and entitlements all come from the Xcode project.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="Release"
INSTALL=0
TEST=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --test) TEST=1 ;;
    debug) CONFIG="Debug" ;;
    release) CONFIG="Release" ;;
  esac
done

# Use full Xcode when xcode-select points at the Command Line Tools: try the selected one, then common locations.
if [[ -z "${DEVELOPER_DIR:-}" ]] && [[ "$(xcode-select -p)" == *CommandLineTools* ]]; then
  for x in /Applications/Xcode.app /Applications/Xcode-beta.app "$HOME/Applications/Xcode.app" "$HOME/Downloads/Xcode-beta.app" "$HOME/Downloads/Xcode.app"; do
    if [[ -d "$x/Contents/Developer" ]]; then export DEVELOPER_DIR="$x/Contents/Developer"; break; fi
  done
fi
echo "Toolchain: ${DEVELOPER_DIR:-$(xcode-select -p)}"

DERIVED="build/DerivedData.noindex"   # ".noindex": Spotlight and the app launcher skip it
mkdir -p build && touch build/.metadata_never_index   # keep Spotlight from listing build copies
XCB=(xcodebuild -workspace Loomo.xcworkspace -scheme Loomo -derivedDataPath "$DERIVED" -destination "platform=macOS,arch=$(uname -m)" -allowProvisioningUpdates -quiet)

if [[ "$TEST" == 1 ]]; then
  "${XCB[@]}" test
fi
"${XCB[@]}" -configuration "$CONFIG" build

APP="$DERIVED/Build/Products/$CONFIG/Loomo.app"
codesign --verify --strict "$APP"

# Xcode registers every app it builds with Launch Services, and Launchpad/Spotlight then list each copy
# (Debug, Release, old build folders) as another Loomo. Forget every copy that isn't /Applications.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
forget_build_copies() {
  "$LSREGISTER" -dump 2>/dev/null | sed -n 's/^path: *\(.*Loomo\.app\) (0x[0-9a-f]*)$/\1/p' | sort -u |
    while IFS= read -r copy; do
      [ "$copy" = "/Applications/Loomo.app" ] && continue
      "$LSREGISTER" -u "$copy" 2>/dev/null || true
    done
}
forget_build_copies
echo "Built $APP ($(defaults read "$PWD/$APP/Contents/Info" CFBundleShortVersionString) build $(defaults read "$PWD/$APP/Contents/Info" CFBundleVersion))"

if [[ "$INSTALL" == 1 ]]; then
  if pgrep -f "/Applications/Loomo.app/Contents/MacOS/Loomo" >/dev/null; then
    osascript -e 'quit app "Loomo"' || true
    sleep 2
    # Never replace the app under open documents: an unsaved one keeps it running behind a save prompt.
    if pgrep -f "/Applications/Loomo.app/Contents/MacOS/Loomo" >/dev/null; then
      echo "Loomo is still open (probably an unsaved document). Save or close it, quit, and run this again." >&2
      exit 1
    fi
  fi
  rm -rf /Applications/Loomo.app
  ditto "$APP" /Applications/Loomo.app
  "$LSREGISTER" -f /Applications/Loomo.app 2>/dev/null || true
  forget_build_copies
  touch /Applications/Loomo.app   # Finder and the Dock pick up a changed icon
  echo "Installed /Applications/Loomo.app"
fi
