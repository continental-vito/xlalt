#!/bin/bash
# build/check-installed-menu.sh — what is actually in the app you are running?
#
# The nib edits are invisible to `strings`: removing a menu item unlinks
# the menu's reference to it and leaves the text in the archive. So the
# only way to tell whether a build really carries the edit is to parse it.
#
#   bash build/check-installed-menu.sh                     (the dev app)
#   bash build/check-installed-menu.sh /Applications/CobAlt.app
set -uo pipefail
cd "$(dirname "$0")/.."

APP="${1:-$HOME/Applications/CobAlt-dev.app}"
NIB="$APP/Contents/Resources/MainMenu.nib"
test -f "$NIB" || { echo "no MainMenu.nib at $NIB" >&2; exit 1; }

echo "Inspecting $APP"
python3 - "$NIB" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("rn", "build/rename-nib.py")
rn = importlib.util.module_from_spec(spec); spec.loader.exec_module(rn)
a = rn.parse(open(sys.argv[1], "rb").read())

print("\nMenus this app will actually show:")
for i in range(len(a["objects"])):
    if rn._cls(a, i) not in ("NSMutableArray", "NSArray"):
        continue
    members = [int.from_bytes(v[2], "little")
               for _, v in rn._obj_values(a, i) if v[1] == 10]
    kinds = [rn._cls(a, m) for m in members if m < len(a["objects"])]
    if not kinds or kinds.count("NSMenuItem") < max(1, len(kinds) - 1):
        continue
    if len(members) > 14:
        continue
    titles = [rn._item_title(a, m) or "-----"
              for m in members if m < len(a["objects"])]
    if any("Quit" in t for t in titles):
        print("  " + " | ".join(titles))

print("\nPreferences:")
bad = False
for want in ("Preferences\u2026", "Preferences..."):
    held = any(rn._cls(a, i) == "NSMenuItem"
               and rn._item_title(a, i) == want
               and rn._in_a_menu(a, i)
               for i in range(len(a["objects"])))
    print("  %-16s %s" % (want, "STILL IN A MENU" if held else "not in any menu"))
    bad = bad or held

print("\nEngine status icon artwork:")
PY

if [ -e "$APP/Contents/Resources/statusicon.pdf" ]; then
  echo "  statusicon.pdf  PRESENT — this build still carries the engine's hammer"
else
  echo "  statusicon.pdf  gone"
fi
if [ -f "$APP/Contents/Resources/statusicon.png" ]; then
  echo "  statusicon.png  present — our artwork is installed"
else
  echo "  statusicon.png  MISSING"
fi

echo
echo "Build identity:"
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
  "$APP/Contents/Info.plist" 2>/dev/null | sed 's/^/  version /'
