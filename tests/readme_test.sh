#!/bin/bash
# tests/readme_test.sh — the download link must name the file the build
# actually produces.
#
# GitHub's /releases/latest/download/<name> 404s if <name> is not an asset.
# Renaming the product renamed the DMG, and the README kept pointing at
# XL.dmg, so the download button on the front page was broken.
set -uo pipefail
cd "$(dirname "$0")/.."

DMG_NAME=$(sed -n 's/^XL_DMG_NAME="${XL_DMG_NAME:-\(.*\)}"$/\1/p' build/build-app.sh)
test -n "$DMG_NAME" || { echo "could not read XL_DMG_NAME from build-app.sh" >&2; exit 1; }
echo "  build produces: ${DMG_NAME}.dmg"

fail=0
while IFS= read -r url; do
  case "$url" in
    */releases/latest/download/"${DMG_NAME}.dmg") echo "  ok    $url" ;;
    */releases/latest/download/*)
      echo "  FAIL  $url" >&2
      echo "        does not match ${DMG_NAME}.dmg" >&2
      fail=1 ;;
  esac
done < <(grep -o 'https://github.com/[^)]*/releases/latest/download/[^)]*' README.md)

grep -o 'https://github.com/[^)]*/releases/latest/download/[^)]*' README.md >/dev/null \
  || { echo "  FAIL  README has no download link at all" >&2; fail=1; }

test "$fail" = "0" && echo "  download link matches the built DMG"
exit "$fail"
