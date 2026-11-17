#!/bin/bash
# Creates dist/OrgScreenSaver-<version>.zip and its .sha256 for a GitHub release.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(tr -d '[:space:]' < VERSION)"
./scripts/build-app-bundle.sh
ZIP="dist/OrgScreenSaver-$VERSION.zip"
rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --keepParent "dist/Org Screen Saver.app" "$ZIP"
( cd dist && shasum -a 256 "OrgScreenSaver-$VERSION.zip" > "OrgScreenSaver-$VERSION.zip.sha256" )
echo "==> $ZIP"
cat "$ZIP.sha256"
