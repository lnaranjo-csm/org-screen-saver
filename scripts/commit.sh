#!/bin/bash
# Bump VERSION and commit everything with the new version appended to the message.
# Usage: scripts/commit.sh <minor|larger> "commit message"
#   minor  : 1.3.0 -> 1.3.1  (small fix)
#   larger : 1.3.0 -> 1.4.0  (new feature / bigger change)
# Does not tag or push. See docs/RELEASING.md for the rest of the release steps.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <minor|larger> \"commit message\"" >&2
  exit 1
fi
KIND="$1"; MSG="$2"

CUR="$(tr -d '[:space:]' < VERSION)"
if ! [[ "$CUR" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "error: VERSION '$CUR' is not X.Y.Z" >&2; exit 1
fi
MAJ="${BASH_REMATCH[1]}"; MIN="${BASH_REMATCH[2]}"; PAT="${BASH_REMATCH[3]}"

case "$KIND" in
  minor)  NEW="$MAJ.$MIN.$((PAT + 1))" ;;
  larger) NEW="$MAJ.$((MIN + 1)).0" ;;
  *) echo "error: bump must be 'minor' or 'larger', got '$KIND'" >&2; exit 1 ;;
esac

echo "$NEW" > VERSION
git add -A
git commit -m "$MSG (v$NEW)"
echo "Committed v$CUR -> v$NEW"
echo "Next: add a **$NEW** block to README.md if not done, push, then: git tag v$NEW && git push origin v$NEW"
