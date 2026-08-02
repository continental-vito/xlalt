#!/bin/bash
# build/bisect-menubar.sh — find which build step stops the status item
# from being laid out.
#
# First attempt at this was wrong: editing Info.plist invalidates the
# runtime's Developer ID signature, so the intermediate variants could not
# launch at all. Only the untouched one and the fully re-signed one ran.
#
# So every variant is now re-signed, and re-signing is step 1 — the thing
# under test rather than a side effect. The variants are cumulative:
#
#   0-pristine   untouched (control; known to work)
#   1-adhoc      + ad-hoc re-signature, nothing else changed
#   2-bundleid   + our bundle identifier
#   3-dockicon   + LSUIElement removed
#   4-launcher   + renamed executable behind our launcher
#   5-nibs       + rewritten nibs  (= the full pipeline)
#
# Usage:
#   bash build/bisect-menubar.sh
#   open dist/bisect/0-pristine.app     wait for the alert, then quit
#   open dist/bisect/1-adhoc.app        ... and so on
#
# The first variant that is not VISIBLE names the step.
#
# To test whether a REAL signature fixes it (no Apple account needed —
# Keychain Access can make a self-signed code signing certificate):
#   XL_SIGN_IDENTITY="My Self Signed" bash build/bisect-menubar.sh
set -euo pipefail
cd "$(dirname "$0")/.."

HS_VERSION="${HS_VERSION:-1.1.1}"
SIGN="${XL_SIGN_IDENTITY:--}"          # "-" is ad-hoc
OUT="dist/bisect"
LOGS="$HOME/Library/Logs/xl-bisect"
CFG="$HOME/.xl-bisect"
rm -rf "$OUT" ; mkdir -p "$OUT" "$LOGS" "$CFG"

echo "→ Signing identity for variants 1-5: $SIGN"
echo "→ Fetching a pristine runtime"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
curl -sL -o "$WORK/hs.zip" \
  "https://github.com/Hammerspoon/hammerspoon/releases/download/${HS_VERSION}/Hammerspoon-${HS_VERSION}.zip"
unzip -q "$WORK/hs.zip" -d "$WORK"
PRISTINE="$WORK/Hammerspoon.app"
test -d "$PRISTINE"

# One shared config for every variant. It labels itself from the bundle it
# is running in, so the variants cannot mix up their log lines even where
# they share a bundle identifier.
cat > "$CFG/init.lua" <<LUA
local me = (hs.processInfo.bundlePath or "?"):match("([^/]+)%.app") or "?"
BAR = hs.menubar.new(true)
if BAR then BAR:setTitle("XLTEST") end
TIMER = hs.timer.doAfter(3, function()
  local f = BAR and BAR:frame()
  local ok = f and f.h > 0
  local line = os.date("%H:%M:%S") .. "  " .. me .. "  " ..
    (f and string.format("frame=(%.0f,%.0f %.0fx%.0f)", f.x, f.y, f.w, f.h)
       or "no frame") .. "  laidOut=" .. tostring(ok == true)
  local fh = io.open("$LOGS/bisect.log", "a")
  if fh then fh:write(line .. "\n") ; fh:close() end
  hs.alert.show(me .. ": " .. (ok and "VISIBLE" or "NOT laid out"), 5)
end)
LUA

BID="com.corgianalyst.menubar-bisect"
plist() { /usr/libexec/PlistBuddy -c "$2" "$1/Contents/Info.plist" 2>/dev/null || true; }

point_config() {                       # point_config <bundle-id>
  defaults write "$1" MJConfigFile "$CFG/init.lua" 2>/dev/null || true
}

resign() {                             # resign <app> <bundle-id>
  codesign --force --deep --sign "$SIGN" "$1" >/dev/null 2>&1
  # Match what build-app.sh does: an explicit designated requirement, so
  # this bisect exercises the real pipeline rather than an approximation.
  codesign --force --sign "$SIGN" --identifier "$2" \
    -r="designated => identifier \"$2\"" "$1" >/dev/null 2>&1
}

start() {                              # start <name> -> echoes app path
  local app="$OUT/$1.app"
  cp -R "$PRISTINE" "$app"
  echo "$app"
}

echo "→ 0-pristine  (control, untouched)"
A=$(start 0-pristine)
point_config "org.hammerspoon.Hammerspoon"

# Same bundle id as pristine on purpose: the ONLY difference from the
# control is the signature.
echo "→ 1-adhoc     (re-signed, nothing else)"
A=$(start 1-adhoc)
resign "$A" "org.hammerspoon.Hammerspoon"

echo "→ 2-bundleid  (+ our identifier)"
A=$(start 2-bundleid)
plist "$A" "Set :CFBundleIdentifier $BID.two"
point_config "$BID.two"
resign "$A" "$BID.two"

echo "→ 3-dockicon  (+ LSUIElement removed)"
A=$(start 3-dockicon)
plist "$A" "Set :CFBundleIdentifier $BID.three"
plist "$A" "Delete :LSUIElement"
point_config "$BID.three"
resign "$A" "$BID.three"

echo "→ 4-launcher  (+ our launcher in front of the engine)"
A=$(start 4-launcher)
plist "$A" "Set :CFBundleIdentifier $BID.four"
plist "$A" "Delete :LSUIElement"
mv "$A/Contents/MacOS/Hammerspoon" "$A/Contents/MacOS/ExcelAltCore"
clang -O2 -arch arm64 -arch x86_64 \
  -o "$A/Contents/MacOS/ExcelAlt" build/launcher.c -framework CoreFoundation
plist "$A" "Set :CFBundleExecutable ExcelAlt"
point_config "$BID.four"
resign "$A" "$BID.four"

echo "→ 5-nibs      (+ rewritten nibs = the full pipeline)"
A=$(start 5-nibs)
plist "$A" "Set :CFBundleIdentifier $BID.five"
plist "$A" "Delete :LSUIElement"
mv "$A/Contents/MacOS/Hammerspoon" "$A/Contents/MacOS/ExcelAltCore"
clang -O2 -arch arm64 -arch x86_64 \
  -o "$A/Contents/MacOS/ExcelAlt" build/launcher.c -framework CoreFoundation
plist "$A" "Set :CFBundleExecutable ExcelAlt"
for nib in "$A"/Contents/Resources/*.nib; do
  python3 build/rename-nib.py "$nib" "Hammerspoon" "CobAlt" >/dev/null 2>&1 || true
done
point_config "$BID.five"
resign "$A" "$BID.five"

echo
echo "→ Confirming every variant will actually launch"
fail=0
for app in "$OUT"/*.app; do
  if codesign --verify --deep --strict "$app" >/dev/null 2>&1; then
    echo "   ok       $(basename "$app")"
  else
    echo "   BROKEN   $(basename "$app") — will not launch, do not trust its result"
    fail=1
  fi
done
test "$fail" = "0" || echo "   (a broken variant is a bug in this script, not a result)"

cat <<NOTES

  Open them ONE AT A TIME, wait for the alert, quit, then the next:

    open $OUT/0-pristine.app
    open $OUT/1-adhoc.app
    open $OUT/2-bundleid.app
    open $OUT/3-dockicon.app
    open $OUT/4-launcher.app
    open $OUT/5-nibs.app

  Each says VISIBLE or NOT laid out on screen, and appends to
  $LOGS/bisect.log

  The FIRST one that is not VISIBLE names the step.

  Cleanup:  rm -rf $OUT "$CFG" "$LOGS"
NOTES
