#!/bin/bash
# Removes the app, its settings, snapshots, logs and Keychain entries.
set -uo pipefail

read -r -p "Remove Org Screen Saver and ALL its data (settings, snapshots, logs)? [y/N] " ans
[[ "$ans" == "y" || "$ans" == "Y" ]] || { echo "Cancelled."; exit 0; }

osascript -e 'tell application "Org Screen Saver" to quit' >/dev/null 2>&1 || true
sleep 1
pkill -x OrgScreenSaver 2>/dev/null || true

rm -rf "$HOME/Applications/Org Screen Saver.app"
rm -rf "$HOME/Library/Application Support/OrgScreenSaver"
rm -rf "$HOME/Library/Logs/OrgScreenSaver"
defaults delete com.orgscreensaver.app >/dev/null 2>&1 || true
security delete-generic-password -s com.orgscreensaver.app -a pin >/dev/null 2>&1 || true
security delete-generic-password -s com.orgscreensaver.app -a recovery >/dev/null 2>&1 || true

echo "Removed. Also remove 'Org Screen Saver' from System Settings > Privacy & Security (Accessibility, Screen Recording, Camera) and Login Items if listed."
