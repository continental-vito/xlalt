#!/bin/bash
# ⌥XL installer — copies the app, wires it up, signs it, launches it.
set -e
cd "$(dirname "$0")"

APP="ExcelAlt.app"
DEST="/Applications/$APP"
BID="com.corgianalyst.excel-alt-shortcuts"

echo ""
echo "  Installing ⌥XL — Alt shortcuts for Excel"
echo "  ─────────────────────────────────────────"

if [ ! -d "$APP" ]; then
  echo "  ✗ $APP not found next to this installer."; exit 1
fi

# 1) Stop any running copy
pkill -f "$DEST/Contents/MacOS/ExcelAlt" 2>/dev/null || true
sleep 0.5

# 2) Install
rm -rf "$DEST"
cp -R "$APP" "$DEST"
echo "  ✓ Copied to /Applications"

# 3) Configure (config path, hide engine menu icon, keep dock hidden, no update checks)
defaults write "$BID" MJConfigFile -string "$DEST/Contents/Resources/init.lua"
defaults write "$BID" MJShowMenuIconKey -bool false
defaults write "$BID" MJShowDockIconKey -bool false
defaults write "$BID" MJShowWindowAtLaunchKey -bool false
defaults write "$BID" SUEnableAutomaticChecks -bool false
defaults write "$BID" HSUploadCrashData -bool false
echo "  ✓ Configured"

# 4) Clear quarantine + stale Accessibility grant, then ad-hoc sign
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
tccutil reset Accessibility "$BID" 2>/dev/null || true
codesign --force --deep --sign - "$DEST" 2>/dev/null
echo "  ✓ Signed"

# 5) Launch
open "$DEST"
echo ""
echo "  ⌥XL is starting. One last step:"
echo "  → macOS will ask for Accessibility permission."
echo "    Grant it to “ExcelAlt”, and the shortcuts go live automatically"
echo "    (no relaunch needed)."
echo ""
echo "  Then open Excel and tap the ⌥ key. Done!"
echo ""
