#!/bin/bash
# start.sh — pull the repo, run this, and ⌥XL is up.
# First run builds the app from source and installs it; later runs relaunch.
#
#   git pull && ./start.sh
#
set -euo pipefail
cd "$(dirname "$0")"

BID="com.corgianalyst.excel-alt-shortcuts"
APP_NAME="ExcelAlt.app"
DEST="/Applications/$APP_NAME"
BUILT="dist/$APP_NAME"

echo ""
echo "  ⌥XL — starting up"
echo "  ─────────────────"

# 0) macOS only
if [ "$(uname)" != "Darwin" ]; then
  echo "  ✗ This app runs on macOS only."; exit 1
fi

# 1) Build the app bundle if we don't have one yet (or if --rebuild given)
if [ "${1:-}" = "--rebuild" ] || [ ! -d "$BUILT" ]; then
  echo "  • Building the app from source (first run or --rebuild)…"
  bash build/build-app.sh
else
  echo "  • Using existing build in dist/ (pass --rebuild to force a fresh build)"
fi

# 2) Stop any running copy so we can replace it cleanly
pkill -f "$DEST/Contents/MacOS/Hammerspoon" 2>/dev/null || true
sleep 0.4

# 3) Install to /Applications (persists; launches at login via the app itself)
rm -rf "$DEST"
cp -R "$BUILT" "$DEST"
echo "  ✓ Installed to /Applications"

# 4) Point the engine at its embedded config, keep it a menu-bar-only agent,
#    disable any update checks
# (Self-configuring since v1.3 — the app writes its own settings at launch.)

# 5) Clear quarantine and ad-hoc sign. (Accessibility is NOT reset on
#    routine installs — your existing grant keeps working across updates.
#    If shortcuts ever go dead after a macOS update, run:
#      tccutil reset Accessibility com.corgianalyst.excel-alt-shortcuts )
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
codesign --force --deep --sign - "$DEST" 2>/dev/null
echo "  ✓ Signed and cleared for launch"

# 6) Launch
open "$DEST"
echo ""
echo "  ⌥XL is running (look for the ⌥-chart icon in the menu bar)."
echo "  → If macOS asks for Accessibility permission, grant it to \"ExcelAlt\";"
echo "    shortcuts activate automatically a couple of seconds later."
echo "  → Open Excel and tap the ⌥ key to begin."
echo ""
