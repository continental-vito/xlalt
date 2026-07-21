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
pkill -f "$DEST/Contents/MacOS/ExcelAlt" 2>/dev/null || true
sleep 0.4

# 3) Install to /Applications (persists; launches at login via the app itself)
rm -rf "$DEST"
cp -R "$BUILT" "$DEST"
echo "  ✓ Installed to /Applications"

# 4) Point the engine at its embedded config, keep it a menu-bar-only agent,
#    disable any update checks
defaults write "$BID" MJConfigFile -string "$DEST/Contents/Resources/init.lua"
defaults write "$BID" MJShowMenuIconKey -bool false
defaults write "$BID" MJShowDockIconKey -bool false
defaults write "$BID" MJShowWindowAtLaunchKey -bool false
defaults write "$BID" SUEnableAutomaticChecks -bool false
defaults write "$BID" HSUploadCrashData -bool false

# 5) Clear quarantine + any STALE Accessibility grant, then ad-hoc sign.
#    (A re-signed/renamed bundle keeps an old, invalid TCC entry that
#     silently blocks event taps — resetting forces a clean prompt.)
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
tccutil reset Accessibility "$BID" 2>/dev/null || true
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
