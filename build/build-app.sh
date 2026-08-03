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
# The bundle FILENAME is what Finder, the Dock and the app switcher show.
# CFBundleDisplayName does not override it without localised display
# names, and those did not work here, so the file is named for the
# product. The updater renames an existing install to match.
XL_BUNDLE_NAME="${XL_BUNDLE_NAME:-CobAlt}"
XL_DISPLAY_NAME="${XL_DISPLAY_NAME:-CobAlt}"
XL_DMG_NAME="${XL_DMG_NAME:-CobAlt}"
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

# Finder, the Dock and ⌘-Tab show the bundle's FILENAME, not
# CFBundleDisplayName — unless the bundle opts into localized display
# names. The filename stays ExcelAlt.app on purpose (an update replaces
# the host bundle in place, and renaming it underneath an installed copy
# risks the swap), so opt in instead. This is the supported way to show
# a name that differs from the file on disk.
/usr/libexec/PlistBuddy -c "Add :LSHasLocalizedDisplayName bool true" "$APP/Contents/Info.plist" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Set :LSHasLocalizedDisplayName true" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDevelopmentRegion en" "$APP/Contents/Info.plist" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :CFBundleDevelopmentRegion string en" "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources/en.lproj"
cat > "$APP/Contents/Resources/en.lproj/InfoPlist.strings" <<STRINGS
/* Shown by Finder, the Dock and the app switcher. */
CFBundleName = "$XL_DISPLAY_NAME";
CFBundleDisplayName = "$XL_DISPLAY_NAME";
STRINGS
if [ -n "${XL_AGENT:-}" ]; then
  # EXPERIMENT (see docs/ARCHITECTURE.md, menu bar).
  #
  # The runtime ships LSUIElement, which we normally delete to get a Dock
  # icon. boringNotch — no Developer account, ad-hoc signed, same
  # NSStatusBar API — keeps LSUIElement=YES and does appear under Control
  # Center > Allow in the Menu Bar, where we do not appear at all.
  #
  # That is the clearest remaining difference between an app whose status
  # item works on this machine and ours. Agent mode removes the Dock icon,
  # so this is a diagnostic, not a default.
  /usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$APP/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :LSUIElement true" "$APP/Contents/Info.plist"
  echo "→ Experiment: agent mode (LSUIElement), no Dock icon"
else
  /usr/libexec/PlistBuddy -c "Delete :LSUIElement" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

# Sparkle's XPC services. Its installer runs through a helper that connects
# back over XPC, and without these keys it is never launched — which is
# exactly what "agent connection was never initiated" meant in the log.
# The services ship inside Sparkle.framework already; these switch them on.
for k in SUEnableDownloaderService SUEnableInstallerLauncherService; do
  /usr/libexec/PlistBuddy -c "Add :$k bool true" "$APP/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :$k true" "$APP/Contents/Info.plist"
done

# The runtime's own wording leaks into the Apple Events permission prompt,
# where the user would read the engine's name and not ours.
/usr/libexec/PlistBuddy -c "Set :NSAppleEventsUsageDescription $XL_DISPLAY_NAME sends events to Excel, PowerPoint and Word to run your shortcuts." \
  "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :LSApplicationCategoryType public.app-category.productivity" \
  "$APP/Contents/Info.plist" 2>/dev/null || true
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
if [ -n "${XL_NO_UPDATES:-}" ]; then
  # Dev builds (build/build-local.sh) get no feed at all. The dev bundle
  # id gives them a different designated requirement, so a release could
  # not install over one anyway — but a dev build should not be reaching
  # for the release appcast in the first place. build-local.sh has
  # exported this since it was written; build-app.sh never read it.
  /usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$APP/Contents/Info.plist" 2>/dev/null || true
  echo "   (no update feed: XL_NO_UPDATES)"
else
  /usr/libexec/PlistBuddy -c "Set :SUFeedURL https://raw.githubusercontent.com/continental-vito/xlalt/main/appcast.xml" "$APP/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :SUFeedURL string https://raw.githubusercontent.com/continental-vito/xlalt/main/appcast.xml" "$APP/Contents/Info.plist"
fi
/usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBKEY" "$APP/Contents/Info.plist" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $SPARKLE_PUBKEY" "$APP/Contents/Info.plist"
# No launcher.
#
# A bisect against an unmodified runtime settled this: our bundle id,
# LSUIElement removed and an ad-hoc signature are all fine, and the status
# item stops being laid out the moment a launcher is introduced. Not
# because of anything it does -- compiling out its preference purge
# changed nothing -- but because the running executable is then not the
# one the bundle declares, and macOS 26 will not register a menu bar item
# for it. The app never even appeared under Control Center > Allow in the
# Menu Bar.
#
# The launcher existed only to set MJConfigFile before the engine started.
# setup.lua is handed configdir as an argument and every other path it
# receives is inside the bundle, so configdir is derived from
# frameworkspath instead. No preference to set, so nothing has to run
# first, and the engine stays the main executable under its own name.
#
# build/launcher.c is gone. Recover it from history if it is ever needed.
echo "→ Resolving the config inside the engine"
python3 - "$APP" <<'PATCH'
import sys
p = sys.argv[1] + "/Contents/Resources/setup.lua"
s = open(p).read()

# setup.lua receives its arguments as varargs, destructures them into
# locals on line 1, and then ends with
#
#     return require'hs._coresetup'.setup(...)
#
# passing the ORIGINAL varargs onward. Assigning to the locals therefore
# changes nothing. The first version of this patch did exactly that and
# was a no-op for two releases; the app kept working only because a
# preference left behind by the old launcher still pointed at the config.
# Rename the bundle and that path stops existing, and no config loads.
#
# So the tail call has to be rewritten to pass the locals.
CALL_IN  = "return require'hs._coresetup'.setup(...)"
CALL_OUT = ("return require'hs._coresetup'.setup(modpath, frameworkspath, "
            "prettypath, fullpath, configdir, docstringspath, hasinitfile, "
            "autoload_extensions)")

BLOCK = """
-- CobAlt: the config lives in this bundle.
-- Located from this file's own path rather than from any argument or
-- preference, so it survives the bundle being renamed or moved. Falls
-- back to whatever the runtime passed if our init.lua is not there.
local _xl_dir = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$")
if _xl_dir then
  local _f = io.open(_xl_dir .. "/init.lua", "r")
  if _f then
    _f:close()
    configdir   = _xl_dir
    fullpath    = _xl_dir .. "/init.lua"
    prettypath  = fullpath
    hasinitfile = true
  end
end
"""

if "CobAlt: the config lives in this bundle" in s:
    print("   setup.lua already patched")
else:
    if CALL_IN not in s:
        sys.exit("setup.lua does not end the way this patch expects")
    first, rest = s.split("\n", 1)
    s = first + BLOCK + "\n" + rest
    s = s.replace(CALL_IN, CALL_OUT)
    open(p, "w").write(s)
    print("   setup.lua patched")
PATCH

SETUP="$APP/Contents/Resources/setup.lua"
# Assert BOTH halves. The block alone is what shipped in v3.14 and did
# nothing, because the tail call still forwarded the untouched varargs.
grep -q "CobAlt: the config lives in this bundle" "$SETUP" \
  || { echo "✗ setup.lua patch did not apply" >&2 ; exit 1 ; }
grep -q "setup(modpath, frameworkspath" "$SETUP" \
  || { echo "✗ setup.lua still forwards the original varargs; the patch is inert" >&2 ; exit 1 ; }
grep -q "setup(\.\.\.)" "$SETUP" \
  && { echo "✗ setup.lua still contains the vararg tail call" >&2 ; exit 1 ; }

ENGINE="$APP/Contents/MacOS/Hammerspoon"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable Hammerspoon" "$APP/Contents/Info.plist"

CORE_ARCHS="$(lipo -archs "$ENGINE")"
echo "   engine:   $CORE_ARCHS"
for A in arm64 x86_64; do
  case "$CORE_ARCHS" in
    *"$A"*) ;;
    *) echo "✗ engine has no $A slice" >&2 ; exit 1 ;;
  esac
done

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
# The application menu, the About/Hide/Quit items and the window titles
# are baked into the runtime's compiled nibs; nothing substitutes them at
# runtime. build/rename-nib.py parses the NIBArchive and rewrites the
# display strings.
#
# This replaced a length-preserving `perl -pi -e s/Hammerspoon/…/`, which
# had two faults. It forced the product name to be exactly 11 characters
# — the only reason the menu ever read "ExcelAlt XL" while the Dock read
# "CobAlt". And it rewrote the *selector* `quitHammerspoon:` along with
# the display strings, leaving Quit wired to a method no class
# implements, which is why Quit did nothing from v1 onward.
for nib in "$APP"/Contents/Resources/*.nib; do
  python3 build/rename-nib.py "$nib" "Hammerspoon" "$XL_DISPLAY_NAME"
done

# Assert the outcome rather than trusting the loop. A nib that silently
# failed to rewrite ships an app menu that still says Hammerspoon, and a
# nib that rewrote too much ships dead menu items.
LEFT=$(strings -a "$APP/Contents/Resources/MainMenu.nib" | grep -c '^Hammerspoon$\|^About Hammerspoon$\|^Quit Hammerspoon$' || true)
if [ "$LEFT" != "0" ]; then
  echo "✗ MainMenu.nib still carries the engine name in $LEFT display string(s)" >&2
  exit 1
fi
if ! strings -a "$APP/Contents/Resources/MainMenu.nib" | grep -qx "quitHammerspoon:"; then
  echo "✗ the quit selector was rewritten — Quit would do nothing" >&2
  exit 1
fi
if ! strings -a "$APP/Contents/Resources/MainMenu.nib" | grep -qx "Quit $XL_DISPLAY_NAME"; then
  echo "✗ the Quit item was not renamed to $XL_DISPLAY_NAME" >&2
  exit 1
fi

# The runtime's Preferences window is its own UI, not ours. "Show menu
# icon" puts the engine's hammer in the menu bar beside our own item, and
# everything else in it is either duplicated by our menu or irrelevant.
# Unlink it from the app menu so it cannot be opened.
#
# NOTE the ellipsis: the app menu uses U+2026 while the engine's own status
# menu uses three dots. They are different objects in different menus, and
# removing the three-dot one changes nothing a user can see.
python3 build/rename-nib.py "$APP/Contents/Resources/MainMenu.nib" \
  --remove-item "Preferences…" \
  || { echo "✗ could not remove the Preferences menu item" >&2 ; exit 1 ; }
# The surrounding items must survive: removing an entry shifts every value
# index after it, and getting that wrong silently empties the menu.
for keep in "Quit $XL_DISPLAY_NAME" "About $XL_DISPLAY_NAME" "Check for Updates..."; do
  strings -a "$APP/Contents/Resources/MainMenu.nib" | grep -qx "$keep" \
    || { echo "✗ the app menu lost \"$keep\"" >&2 ; exit 1 ; }
done

echo "→ Embedding engine config and assets"
cp src/init.lua "$APP/Contents/Resources/init.lua"
if [ -f assets/AppIcon.icns ]; then
  cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
[ -f assets/menubar@2x.png ] && cp assets/menubar@2x.png "$APP/Contents/Resources/xl-menubar@2x.png"
[ -f assets/menubar.png ]    && cp assets/menubar.png    "$APP/Contents/Resources/xl-menubar.png"

# The engine has a status icon of its own -- the hammer -- loaded by the
# name "statusicon" from Resources. It is only shown if someone switches
# it on, and the switch lives in the Preferences window we unlink from the
# app menu, so it should be unreachable. Replace the artwork anyway: if it
# ever does appear, it should be our corgi and not another product's logo.
#
# NSImage resolves "statusicon" to any supported extension, so the PDF is
# removed and PNGs put in its place. Same template as our own item, so
# both render identically.
rm -f "$APP/Contents/Resources/statusicon.pdf"
if [ -f assets/menubar@2x.png ] && [ -f assets/menubar.png ]; then
  cp assets/menubar.png    "$APP/Contents/Resources/statusicon.png"
  cp assets/menubar@2x.png "$APP/Contents/Resources/statusicon@2x.png"
fi
[ -e "$APP/Contents/Resources/statusicon.pdf" ] \
  && { echo "✗ the engine's status icon is still in the bundle" >&2 ; exit 1 ; }
[ -f "$APP/Contents/Resources/statusicon.png" ] \
  || { echo "✗ no replacement status icon was installed" >&2 ; exit 1 ; }
[ -f assets/xl-corgi.png ]   && cp assets/xl-corgi.png   "$APP/Contents/Resources/xl-corgi.png"


if [ -n "${XL_SIGN_IDENTITY:-}" ]; then
  # ---------------------------------------------------------------
  # Developer ID build
  # ---------------------------------------------------------------
  # Signed inside-out, deliberately, instead of with --deep. --deep
  # would re-sign the nested Sparkle helpers with OUR entitlements and
  # strip theirs, which is worse than leaving them alone. Each nested
  # binary keeps whatever entitlements it already had; only the app
  # itself gets build/entitlements.plist.
  echo "→ Signing with Developer ID: $XL_SIGN_IDENTITY"
  ENT_TMP="$(mktemp -d)"
  sign_nested() {
    local target="$1" ent="$ENT_TMP/ent.plist"
    if codesign -d --entitlements :- "$target" 2>/dev/null > "$ent" && [ -s "$ent" ]; then
      codesign --force --options runtime --timestamp \
        --entitlements "$ent" --sign "$XL_SIGN_IDENTITY" "$target"
    else
      codesign --force --options runtime --timestamp \
        --sign "$XL_SIGN_IDENTITY" "$target"
    fi
  }
  # -depth so the innermost code is sealed before whatever contains it.
  while IFS= read -r nested; do
    sign_nested "$nested"
  done < <(find "$APP/Contents" -depth \
             \( -name "*.app" -o -name "*.xpc" -o -name "*.framework" \
                -o -name "*.dylib" -o -name "*.so" -o -name "*.bundle" \) 2>/dev/null)
  sign_nested "$ENGINE"
  rm -rf "$ENT_TMP"

  # No explicit -r here. A Developer ID signature produces a designated
  # requirement anchored to the certificate, which is both stronger than
  # the identifier-only one and still satisfied across builds. The
  # identifier clause it contains is what lets a machine running an
  # ad-hoc build (whose requirement is `identifier "<bid>"`) accept this
  # one as an update.
  codesign --force --options runtime --timestamp \
    --entitlements build/entitlements.plist \
    --sign "$XL_SIGN_IDENTITY" "$APP"
else
echo "→ Signing (ad-hoc, with a stable designated requirement)"
  # Sign the Mach-O engine first, then seal the bundle.
  codesign --force --sign - "$ENGINE"
  codesign --force --deep --sign - "$APP"
fi

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
if [ -z "${XL_SIGN_IDENTITY:-}" ]; then
  codesign --force --sign - --identifier "$BID" \
    -r="designated => identifier \"$BID\"" "$APP"
fi

# Assert it landed. A silently-synthesised cdhash requirement looks fine
# to `codesign --verify` and only shows up as a failed update months
# later, which is exactly how this went unnoticed for six releases.
DR="$(codesign -d -r- "$APP" 2>&1 | grep '^designated' || true)"
echo "   $DR"
case "$DR" in
  *cdhash*|"") echo "✗ designated requirement is build-specific — updates would not install" >&2
               exit 1 ;;
  # Ad-hoc: identifier only. Developer ID: identifier plus a certificate
  # anchor. Either is stable across builds, which is the property that
  # matters; a cdhash is not, and is rejected above.
  *"identifier \"$BID\""*) ;;
  *) echo "✗ unexpected designated requirement" >&2 ; exit 1 ;;
esac
if [ -n "${XL_SIGN_IDENTITY:-}" ]; then
  case "$DR" in
    *"anchor apple generic"*) ;;
    *) echo "✗ signed with an identity but the requirement has no Apple anchor" >&2
       exit 1 ;;
  esac
  # Notarization rejects anything without the hardened runtime, and the
  # flag is easy to lose by re-signing one step later.
  codesign -d -vv "$APP" 2>&1 | grep -q "flags=.*runtime" || {
    echo "✗ hardened runtime flag is missing — notarization would reject this" >&2
    exit 1
  }
fi
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
