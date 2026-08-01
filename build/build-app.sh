#!/bin/bash
# build/build-app.sh — reproducible CobAlt build. Run on macOS from repo root:
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
XL_DISPLAY_NAME="${XL_DISPLAY_NAME:-CobAlt}"
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
# CFBundleName drives the app menu and the Dock label, so it follows the
# DISPLAY name. XL_BUNDLE_NAME stays the bundle's filename on disk
# (ExcelAlt.app) — Sparkle replaces the host bundle in place, and
# renaming it underneath an installed copy risks the update path.
/usr/libexec/PlistBuddy -c "Set :CFBundleName $XL_DISPLAY_NAME" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $XL_DISPLAY_NAME" "$APP/Contents/Info.plist" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $XL_DISPLAY_NAME" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable ExcelAlt" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Delete :LSUIElement" "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $XL_VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $XL_BUILD" "$APP/Contents/Info.plist"
# In-app updates: feed + EdDSA public key.
#
# The feed and key stay published: from v3.10 the runtime's own
# Check for Updates… in the top-left app menu can install, because the
# designated requirement it checks is now stable across builds (see the
# signing step below).
#
# Scheduled checks are OFF, deliberately. The engine runs its own
# automatic check (20s after launch, then every six hours), and with
# Sparkle also scheduling one the user would be asked twice about the
# same version by two different dialogs. Turning this off leaves
# Sparkle as a manual entry point and exactly one automatic path.
/usr/libexec/PlistBuddy -c "Set :SUEnableAutomaticChecks false" "$APP/Contents/Info.plist" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :SUEnableAutomaticChecks bool false" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :SUFeedURL https://raw.githubusercontent.com/continental-vito/xlalt/main/appcast.xml" "$APP/Contents/Info.plist" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :SUFeedURL string https://raw.githubusercontent.com/continental-vito/xlalt/main/appcast.xml" "$APP/Contents/Info.plist"
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

echo "→ Signing (ad-hoc, with a stable designated requirement)"
# Sign the Mach-O engine first, then seal the bundle.
codesign --force --sign - "$APP/Contents/MacOS/ExcelAltCore"
codesign --force --deep --sign - "$APP"

# Then re-seal the top level with an EXPLICIT designated requirement.
#
# This is what makes an in-place update possible at all. Sparkle's
# installer helper reads the *installed* app's designated requirement and
# checks the downloaded app against it. With a plain ad-hoc signature
# there is no explicit requirement, so macOS synthesises one from the
# code hash: `cdhash H"c26014e4…"`. That is pinned to a single build, so
# no subsequent build can ever satisfy it, and the install stops at
# "Code signature of the new version doesn't match the old version".
#
# `identifier "<bundle id>"` is stable across builds and is satisfied by
# any build of this app. It is deliberately not a security boundary —
# ad-hoc code has no certificate to anchor to, and the EdDSA signature on
# the appcast is what attests the archive. It exists so the requirement
# stops being build-specific. A Developer ID certificate would replace
# this with a real anchor.
#
# --deep is NOT used here: it would push this requirement down onto the
# nested Sparkle framework, whose identifier is different.
codesign --force --sign - --identifier "$BID" \
  -r="designated => identifier \"$BID\"" "$APP"

# Assert it landed. A silently-synthesised cdhash requirement looks fine
# to `codesign --verify` and only shows up as a failed update months
# later, which is exactly how this went unnoticed for six releases.
DR="$(codesign -d -r- "$APP" 2>&1 | grep '^designated' || true)"
echo "   $DR"
case "$DR" in
  *cdhash*|"") echo "✗ designated requirement is build-specific — updates would not install" >&2
               exit 1 ;;
  *"identifier \"$BID\""*) ;;
  *) echo "✗ unexpected designated requirement" >&2 ; exit 1 ;;
esac
codesign --verify --deep --strict "$APP"

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
