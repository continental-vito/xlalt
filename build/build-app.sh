#!/bin/bash
# build/build-app.sh — reproducible ⌥XL build. Run on macOS from repo root:
#   bash build/build-app.sh
# Produces dist/ExcelAlt.app and dist/XL-App.zip
set -euo pipefail
cd "$(dirname "$0")/.."

HS_VERSION="1.1.1"
HS_URL="https://github.com/Hammerspoon/hammerspoon/releases/download/${HS_VERSION}/Hammerspoon-${HS_VERSION}.zip"
BID="com.corgianalyst.excel-alt-shortcuts"

rm -rf dist && mkdir -p dist/work
echo "→ Downloading engine ${HS_VERSION}"
curl -sL -o dist/work/hs.zip "$HS_URL"
unzip -q dist/work/hs.zip -d dist/work
mv dist/work/Hammerspoon.app dist/ExcelAlt.app
APP="dist/ExcelAlt.app"

echo "→ Rebranding bundle"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BID" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName ExcelAlt" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string ⌥XL" "$APP/Contents/Info.plist" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ⌥XL" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable ExcelAlt" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$APP/Contents/Info.plist" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Set :LSUIElement true" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$APP/Contents/Info.plist" 2>/dev/null || true
mv "$APP/Contents/MacOS/Hammerspoon" "$APP/Contents/MacOS/ExcelAlt"

echo "→ Embedding engine config and assets"
cp src/init.lua "$APP/Contents/Resources/init.lua"
if [ -f assets/AppIcon.icns ]; then
  cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
[ -f assets/menubar@2x.png ] && cp assets/menubar@2x.png "$APP/Contents/Resources/xl-menubar@2x.png"
[ -f assets/xl-corgi.png ]   && cp assets/xl-corgi.png   "$APP/Contents/Resources/xl-corgi.png"

echo "→ Signing (ad-hoc)"
codesign --force --deep --sign - "$APP"

echo "→ Packaging"
cp "installer/Install XL.command" dist/
cp installer/README.txt dist/ 2>/dev/null || true
(cd dist && zip -qry XL-App.zip ExcelAlt.app "Install XL.command" README.txt 2>/dev/null || \
            zip -qry XL-App.zip ExcelAlt.app "Install XL.command")
rm -rf dist/work
echo "✓ dist/XL-App.zip ready"
