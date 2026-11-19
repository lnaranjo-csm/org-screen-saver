#!/bin/bash
# Builds "Org Screen Saver.app" into ./dist
# Env: CODESIGN_IDENTITY (default "-" = ad-hoc), UPDATE_REPO (default OWNER/org-screen-saver)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(tr -d '[:space:]' < VERSION)"
# Prefer an explicit identity, then the first "Apple Development" cert in the keychain
# (a stable signature keeps Accessibility/Screen Recording/Camera grants across rebuilds),
# then fall back to ad-hoc ("-"), which resets grants on every build.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -1)"
fi
IDENTITY="${IDENTITY:--}"
if [[ "$IDENTITY" == "-" ]]; then
  echo "warning: ad-hoc signing; macOS permission grants will reset on each rebuild. See README (stable signing)."
fi
REPO="${UPDATE_REPO:-OWNER/org-screen-saver}"
APP="dist/Org Screen Saver.app"

echo "==> Building release binary (v$VERSION)"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/OrgScreenSaver"

echo "==> Assembling app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/OrgScreenSaver"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sed -e "s|__VERSION__|$VERSION|g" -e "s|__UPDATE_REPO__|$REPO|g" scripts/Info.plist.template > "$APP/Contents/Info.plist"

echo "==> Signing (identity: $IDENTITY)"
codesign --force --deep --sign "$IDENTITY" --identifier com.orgscreensaver.app "$APP"
codesign --verify --deep "$APP"
echo "==> Done: $APP"
