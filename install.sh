#!/bin/bash
# Builds Org Screen Saver from source and installs it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

echo "Org Screen Saver installer"

if [[ "$(uname)" != "Darwin" ]]; then echo "This app only runs on macOS."; exit 1; fi
MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if (( MAJOR < 13 )); then echo "macOS 13 or later is required."; exit 1; fi

if ! xcode-select -p >/dev/null 2>&1 || ! command -v swift >/dev/null 2>&1; then
  echo "Xcode Command Line Tools are required. Starting their installer..."
  xcode-select --install || true
  echo "When the installation finishes, run ./install.sh again."
  exit 1
fi

# Stop a running copy (refuses if it is currently locked: quitting is blocked then).
if pgrep -x OrgScreenSaver >/dev/null; then
  echo "Stopping the running copy..."
  osascript -e 'tell application "Org Screen Saver" to quit' >/dev/null 2>&1 || true
  sleep 1
  if pgrep -x OrgScreenSaver >/dev/null; then echo "Could not stop the running app (is the screen saver active?). Unlock it and retry."; exit 1; fi
fi

./scripts/build-app-bundle.sh

DEST="$HOME/Applications"
mkdir -p "$DEST"
rm -rf "$DEST/Org Screen Saver.app"
ditto "dist/Org Screen Saver.app" "$DEST/Org Screen Saver.app"
xattr -dr com.apple.quarantine "$DEST/Org Screen Saver.app" 2>/dev/null || true

echo
echo "Installed to $DEST/Org Screen Saver.app"
echo "Opening it now. Follow the setup window to grant permissions."
open "$DEST/Org Screen Saver.app"
