#!/bin/bash
# build/build-app.sh — reproducible ⌥XL build. Run on macOS from repo root:
#   bash build/build-app.sh
# Produces dist/ExcelAlt.app and dist/XL-App.zip
set -euo pipefail
cd "$(dirname "$0")/.."

HS_VERSION="1.1.1"
HS_URL="https://github.com/Hammerspoon/hammerspoon/releases/download/${HS_VERSION}/Hammerspoon-${HS_VERSION}.zip"
BID="com.corgianalyst.excel-alt-shortcuts"
XL_VERSION="${XL_VERSION:-2.5}"
XL_BUILD="${XL_BUILD:-1}"
SPARKLE_PUBKEY="c2aHOy058alqEV8VJ/7MzioCtONcOmQWU0Df0LiMGac="

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
/usr/libexec/PlistBuddy -c "Delete :LSUIElement" "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $XL_VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $XL_BUILD" "$APP/Contents/Info.plist"
# In-app updates: feed + EdDSA public key (manual "Check for updates")
/usr/libexec/PlistBuddy -c "Set :SUFeedURL https://raw.githubusercontent.com/vitodelcambio/xlalt/main/appcast.xml" "$APP/Contents/Info.plist" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :SUFeedURL string https://raw.githubusercontent.com/vitodelcambio/xlalt/main/appcast.xml" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBKEY" "$APP/Contents/Info.plist" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $SPARKLE_PUBKEY" "$APP/Contents/Info.plist"
mv "$APP/Contents/MacOS/Hammerspoon" "$APP/Contents/MacOS/ExcelAltCore"
# Native launcher (see build/launcher.c): configures the app's own prefs,
# then execs the engine. Compiled here so the bundle's main executable is
# a proper Mach-O, which Gatekeeper accepts unconditionally.
clang -O2 -o "$APP/Contents/MacOS/ExcelAlt" build/launcher.c -framework CoreFoundation

echo "→ Branding the About window"
cp build/Credits.html "$APP/Contents/Resources/Credits.html"
rm -f "$APP/Contents/Resources/Credits.rtf" 2>/dev/null || true
# Some AppKit builds read Credits files as MacRoman unless the charset is
# declared in-file (done above) — verify it is valid UTF-8 before shipping.
iconv -f UTF-8 -t UTF-8 "$APP/Contents/Resources/Credits.html" >/dev/null

echo "→ De-branding engine UI resources"
# First-run windows (e.g. the Accessibility prompt) come from the engine's
# nib/strings resources. Length-preserving rename keeps binary plists valid:
# "Hammerspoon" (11 chars) -> "ExcelAlt XL" (11 chars).
find "$APP/Contents/Resources" \( -name "*.nib" -o -name "*.strings" \) -print0 | \
  xargs -0 perl -pi -e 's/Hammerspoon/ExcelAlt XL/g' 2>/dev/null || true

echo "→ Embedding engine config and assets"
cp src/init.lua "$APP/Contents/Resources/init.lua"
if [ -f assets/AppIcon.icns ]; then
  cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
[ -f assets/menubar@2x.png ] && cp assets/menubar@2x.png "$APP/Contents/Resources/xl-menubar@2x.png"
[ -f assets/xl-corgi.png ]   && cp assets/xl-corgi.png   "$APP/Contents/Resources/xl-corgi.png"

echo "→ Signing (ad-hoc)"
# Sign the Mach-O engine first, then seal the bundle. The bundle's main
# executable is a shell launcher; its signature lives in extended
# attributes, which DMG transport preserves (zip does not, reliably).
codesign --force --sign - "$APP/Contents/MacOS/ExcelAltCore"
codesign --force --deep --sign - "$APP"

echo "→ Building DMG (classic drag-to-Applications)"
DMGROOT="dist/dmgroot"
rm -rf "$DMGROOT" && mkdir -p "$DMGROOT"
cp -R "$APP" "$DMGROOT/"
ln -s /Applications "$DMGROOT/Applications"
hdiutil create -volname "XL" -srcfolder "$DMGROOT" -ov -format UDZO -quiet dist/XL.dmg
rm -rf "$DMGROOT"

echo "→ Update archive (Sparkle in-app updates)"
ditto -c -k --keepParent "$APP" dist/ExcelAlt-update.zip

echo "→ Zip fallback (app + optional installer, for troubleshooting)"
cp "installer/Install XL.command" dist/
(cd dist && zip -qry XL-App.zip ExcelAlt.app "Install XL.command")
rm -rf dist/work
echo "✓ dist/XL.dmg and dist/XL-App.zip ready"
