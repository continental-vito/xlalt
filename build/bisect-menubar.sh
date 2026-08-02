#!/bin/bash
# build/bisect-menubar.sh — find which build step stops the status item
# from being laid out.
#
# The same hs.menubar call works in an unmodified Hammerspoon.app and does
# not work in our bundle, so one of the things build-app.sh does to the
# bundle is responsible. Rather than guess again, this applies those steps
# cumulatively and produces one app per step.
#
# Each variant runs a MINIMAL config — create a status item, report its
# frame — so the engine's own code is out of the picture entirely.
#
#   bash build/bisect-menubar.sh
#   open dist/bisect/0-pristine.app        (wait 5s, then quit it)
#   open dist/bisect/1-bundleid.app        ... and so on
#   cat ~/Library/Logs/xl-bisect/*.log
#
# The first variant whose log shows h=0 is the step that breaks it.
set -euo pipefail
cd "$(dirname "$0")/.."

HS_VERSION="${HS_VERSION:-1.1.1}"
OUT="dist/bisect"
LOGS="$HOME/Library/Logs/xl-bisect"
rm -rf "$OUT" ; mkdir -p "$OUT" "$LOGS"

echo "→ Fetching a pristine runtime"
WORK="$(mktemp -d)"
curl -sL -o "$WORK/hs.zip" \
  "https://github.com/Hammerspoon/hammerspoon/releases/download/${HS_VERSION}/Hammerspoon-${HS_VERSION}.zip"
unzip -q "$WORK/hs.zip" -d "$WORK"
PRISTINE="$WORK/Hammerspoon.app"
test -d "$PRISTINE"

# The whole test, in nine lines. Retained globally so nothing is collected.
write_config() {                # write_config <dir> <label>
  mkdir -p "$1"
  cat > "$1/init.lua" <<LUA
BAR = hs.menubar.new(true)
if BAR then BAR:setTitle("XLTEST") end
TIMER = hs.timer.doAfter(3, function()
  local f = BAR and BAR:frame()
  local line = os.date("%H:%M:%S") .. "  $2  " ..
    (f and string.format("frame=(%.0f,%.0f %.0fx%.0f) laidOut=%s",
                         f.x, f.y, f.w, f.h, tostring(f.h > 0))
       or "no frame at all")
  local fh = io.open("$LOGS/$2.log", "a")
  if fh then fh:write(line .. "\n") ; fh:close() end
  hs.alert.show("$2: " .. (f and f.h > 0 and "VISIBLE" or "not laid out"), 4)
end)
LUA
}

BID="com.corgianalyst.menubar-bisect"

make_variant() {                # make_variant <n-name> <bundle-id>
  local name="$1" bid="$2"
  local app="$OUT/$name.app"
  cp -R "$PRISTINE" "$app"
  local cfgdir="$HOME/.xl-bisect/$name"
  write_config "$cfgdir" "$name"
  defaults write "$bid" MJConfigFile "$cfgdir/init.lua" 2>/dev/null || true
  defaults write "$bid" MJShowMenuIconKey -bool true 2>/dev/null || true
  echo "$app"
}

plist() { /usr/libexec/PlistBuddy -c "$2" "$1/Contents/Info.plist" 2>/dev/null || true; }

# --- 0: pristine ------------------------------------------------------
# Control. If this does not show a status item, the problem is the
# machine or the runtime version, not anything we do.
APP=$(make_variant "0-pristine" "org.hammerspoon.Hammerspoon")

# --- 1: our bundle identifier ----------------------------------------
APP=$(make_variant "1-bundleid" "$BID")
plist "$APP" "Set :CFBundleIdentifier $BID"

# --- 2: + LSUIElement removed (the Dock icon) ------------------------
APP=$(make_variant "2-dockicon" "$BID.dock")
plist "$APP" "Set :CFBundleIdentifier $BID.dock"
plist "$APP" "Delete :LSUIElement"

# --- 3: + renamed executable behind a launcher -----------------------
APP=$(make_variant "3-launcher" "$BID.launcher")
plist "$APP" "Set :CFBundleIdentifier $BID.launcher"
plist "$APP" "Delete :LSUIElement"
mv "$APP/Contents/MacOS/Hammerspoon" "$APP/Contents/MacOS/ExcelAltCore"
clang -O2 -arch arm64 -arch x86_64 \
  -o "$APP/Contents/MacOS/ExcelAlt" build/launcher.c -framework CoreFoundation
plist "$APP" "Set :CFBundleExecutable ExcelAlt"

# --- 4: + rewritten nibs ---------------------------------------------
APP=$(make_variant "4-nibs" "$BID.nibs")
plist "$APP" "Set :CFBundleIdentifier $BID.nibs"
plist "$APP" "Delete :LSUIElement"
mv "$APP/Contents/MacOS/Hammerspoon" "$APP/Contents/MacOS/ExcelAltCore"
clang -O2 -arch arm64 -arch x86_64 \
  -o "$APP/Contents/MacOS/ExcelAlt" build/launcher.c -framework CoreFoundation
plist "$APP" "Set :CFBundleExecutable ExcelAlt"
for nib in "$APP"/Contents/Resources/*.nib; do
  python3 build/rename-nib.py "$nib" "Hammerspoon" "CobAlt" >/dev/null
done

# --- 5: + ad-hoc re-signing (the full pipeline) ----------------------
APP=$(make_variant "5-resigned" "$BID.resigned")
plist "$APP" "Set :CFBundleIdentifier $BID.resigned"
plist "$APP" "Delete :LSUIElement"
mv "$APP/Contents/MacOS/Hammerspoon" "$APP/Contents/MacOS/ExcelAltCore"
clang -O2 -arch arm64 -arch x86_64 \
  -o "$APP/Contents/MacOS/ExcelAlt" build/launcher.c -framework CoreFoundation
plist "$APP" "Set :CFBundleExecutable ExcelAlt"
for nib in "$APP"/Contents/Resources/*.nib; do
  python3 build/rename-nib.py "$nib" "Hammerspoon" "CobAlt" >/dev/null
done
codesign --force --sign - "$APP/Contents/MacOS/ExcelAltCore"
codesign --force --deep --sign - "$APP"
codesign --force --sign - --identifier "$BID.resigned" \
  -r="designated => identifier \"$BID.resigned\"" "$APP"

rm -rf "$WORK"

cat <<NOTES

  Built in $OUT:
NOTES
ls -1 "$OUT"
cat <<NOTES

  Open them ONE AT A TIME, wait for the alert, then quit before the next:

    open $OUT/0-pristine.app

  Each says VISIBLE or "not laid out" on screen and appends to
  $LOGS/<name>.log

  0-pristine is the control. If it is not VISIBLE, stop — the problem is
  not something we do to the bundle.

  Otherwise the FIRST variant that is not VISIBLE names the step.

  To clean up afterwards:
    rm -rf $OUT "$HOME/.xl-bisect" "$LOGS"
NOTES
