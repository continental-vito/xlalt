#!/bin/bash
# build/build-app.sh — reproducible ⌥XL build. Run on macOS from repo root:
#   bash build/build-app.sh
# Produces dist/ExcelAlt.app and dist/XL-App.zip
set -euo pipefail
cd "$(dirname "$0")/.."

HS_VERSION="1.1.1"
HS_URL="https://github.com/Hammerspoon/hammerspoon/releases/download/${HS_VERSION}/Hammerspoon-${HS_VERSION}.zip"
# Identity is overridable so build-local.sh can produce a genuinely separate
# app that installs alongside the released one: its own bundle id (hence its
# own preferences, its own Accessibility grant and its own data directory),
# its own name in the Dock. Unset = the real release identity.
BID="${XL_BUNDLE_ID:-com.corgianalyst.excel-alt-shortcuts}"
XL_BUNDLE_NAME="${XL_BUNDLE_NAME:-ExcelAlt}"
XL_DISPLAY_NAME="${XL_DISPLAY_NAME:-⌥XL}"
XL_DMG_NAME="${XL_DMG_NAME:-XL}"
XL_VERSION="${XL_VERSION:-2.5}"
XL_BUILD="${XL_BUILD:-1}"
SPARKLE_PUBKEY="c2aHOy058alqEV8VJ/7MzioCtONcOmQWU0Df0LiMGac="

rm -rf dist && mkdir -p dist/work
echo "→ Downloading engine ${HS_VERSION}"
curl -sL -o dist/work/hs.zip "$HS_URL"
unzip -q dist/work/hs.zip -d dist/work
mv dist/work/Hammerspoon.app "dist/${XL_BUNDLE_NAME}.app"
APP="dist/${XL_BUNDLE_NAME}.app"

echo "→ Rebranding bundle"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BID" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $XL_BUNDLE_NAME" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $XL_DISPLAY_NAME" "$APP/Contents/Info.plist" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $XL_DISPLAY_NAME" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable ExcelAlt" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Delete :LSUIElement" "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $XL_VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $XL_BUILD" "$APP/Contents/Info.plist"
# Sparkle is switched off in every build.
#
# It ships with the runtime and cannot be deleted (the binary links
# against it), but it is able to download and verify an update and then
# unable to install one: applying it launches Sparkle's nested
# Updater.app, and macOS refuses to launch a nested helper inside an
# ad-hoc-signed, un-notarized bundle. Every check a user ran therefore
# ended at "An error occurred while running the updater".
#
# Removing SUFeedURL outright leaves nothing to check even if something
# triggers one. Note that these keys are only DEFAULTS: a value written
# to the app's user defaults on an earlier launch overrides the bundle,
# which is why launcher.c clears the same keys on every launch. The
# public key stays so that re-enabling is a one-line change once a
# Developer ID certificate exists.
/usr/libexec/PlistBuddy -c "Set :SUEnableAutomaticChecks false" "$APP/Contents/Info.plist" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :SUEnableAutomaticChecks bool false" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Delete :SUScheduledCheckInterval" "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBKEY" "$APP/Contents/Info.plist" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $SPARKLE_PUBKEY" "$APP/Contents/Info.plist"
mv "$APP/Contents/MacOS/Hammerspoon" "$APP/Contents/MacOS/ExcelAltCore"
# Native launcher (see build/launcher.c): configures the app's own prefs,
# then execs the engine. Compiled here so the bundle's main executable is
# a proper Mach-O, which Gatekeeper accepts unconditionally.
clang -O2 -o "$APP/Contents/MacOS/ExcelAlt" build/launcher.c -framework CoreFoundation

echo "→ Branding the About window"
# Text only. The About panel already shows the app icon above this
# content, and AppKit renders Credits HTML through NSAttributedString,
# which ignores width/height on <img> and draws at natural size — an
# image here arrives enormous, not as the 54px badge you asked for.
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
[ -f assets/menubar.png ]    && cp assets/menubar.png    "$APP/Contents/Resources/xl-menubar.png"
[ -f assets/xl-corgi.png ]   && cp assets/xl-corgi.png   "$APP/Contents/Resources/xl-corgi.png"

echo "→ Signing (ad-hoc)"
# Sign the Mach-O engine first, then seal the bundle. The bundle's main
# executable is a shell launcher; its signature lives in extended
# attributes, which DMG transport preserves (zip does not, reliably).
codesign --force --sign - "$APP/Contents/MacOS/ExcelAltCore"
codesign --force --deep --sign - "$APP"

# Local development builds only need dist/ExcelAlt.app; DMG + archives add
# ~a minute per iteration and are never used off-CI. See build/build-local.sh.
if [ -n "${XL_APP_ONLY:-}" ]; then
  rm -rf dist/work
  echo "✓ $APP ready (packaging skipped: XL_APP_ONLY)"
  exit 0
fi

echo "→ Building DMG (classic drag-to-Applications)"
DMGROOT="dist/dmgroot"
rm -rf "$DMGROOT" && mkdir -p "$DMGROOT"
cp -R "$APP" "$DMGROOT/"
ln -s /Applications "$DMGROOT/Applications"
# The disk image and the bundle inside it are named after the build, so a
# development DMG drags into /Applications as ExcelAlt-dev.app and cannot
# replace the released app.
hdiutil create -volname "$XL_DMG_NAME" -srcfolder "$DMGROOT" -ov -format UDZO -quiet "dist/${XL_DMG_NAME}.dmg"
rm -rf "$DMGROOT"

echo "→ Update archive (Sparkle in-app updates)"
ditto -c -k --keepParent "$APP" dist/ExcelAlt-update.zip

echo "→ Zip fallback (app + optional installer, for troubleshooting)"
cp "installer/Install XL.command" dist/
(cd dist && zip -qry "${XL_DMG_NAME}-App.zip" "${XL_BUNDLE_NAME}.app" "Install XL.command")
rm -rf dist/work
echo "✓ dist/${XL_DMG_NAME}.dmg and dist/${XL_DMG_NAME}-App.zip ready"
