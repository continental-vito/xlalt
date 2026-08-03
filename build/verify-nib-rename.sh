#!/bin/bash
# build/verify-nib-rename.sh — proves build/rename-nib.py is safe to run
# against the runtime's compiled nibs.
#
# A corrupt MainMenu.nib is an app that will not start, and a nib that
# renames too much is an app with dead menu items — the state Quit was in
# from v1 to v3.10. Neither shows up in the Lua suite, so it is checked
# here against the real files.
#
# Needs no macOS: NIBArchive parsing is pure Python.
set -euo pipefail
cd "$(dirname "$0")/.."

HS_VERSION="${HS_VERSION:-1.1.1}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "→ Fetching the runtime's nibs (${HS_VERSION})"
curl -sL -o "$WORK/hs.zip" \
  "https://github.com/Hammerspoon/hammerspoon/releases/download/${HS_VERSION}/Hammerspoon-${HS_VERSION}.zip"
unzip -q "$WORK/hs.zip" -d "$WORK"
NIBS="$WORK/Hammerspoon.app/Contents/Resources"
test -f "$NIBS/MainMenu.nib"

echo
echo "→ Every nib must round-trip byte-for-byte before any is edited"
python3 - "$NIBS" <<'PY'
import glob, importlib.util, os, sys
spec = importlib.util.spec_from_file_location("rn", "build/rename-nib.py")
rn = importlib.util.module_from_spec(spec); spec.loader.exec_module(rn)
bad = 0
for f in sorted(glob.glob(os.path.join(sys.argv[1], "*.nib"))):
    d = open(f, "rb").read()
    if rn.build(rn.parse(d)) != d:
        print("  ✗ %s does not round-trip" % os.path.basename(f)); bad += 1
    else:
        print("  ✓ %s" % os.path.basename(f))
sys.exit(1 if bad else 0)
PY

echo
echo "→ Renaming to a name that is NOT the same length as the original"
# The whole point of parsing rather than substituting: "CobAlt" is six
# characters against "Hammerspoon"'s eleven. If this only ever ran with
# an 11-character name it would not be testing anything the old
# substitution could not already do.
for nib in "$NIBS"/*.nib; do
  python3 build/rename-nib.py "$nib" "Hammerspoon" "CobAlt"
done

echo
echo "→ Checking the result"
fail=0
expect_present() {
  if strings -a "$NIBS/MainMenu.nib" | grep -qx "$1"; then
    echo "  ✓ present: $1"
  else
    echo "  ✗ MISSING: $1" >&2 ; fail=1
  fi
}
expect_absent() {
  if strings -a "$NIBS/MainMenu.nib" | grep -qx "$1"; then
    echo "  ✗ STILL THERE: $1" >&2 ; fail=1
  else
    echo "  ✓ gone: $1"
  fi
}

expect_present "CobAlt"
expect_present "About CobAlt"
expect_present "Quit CobAlt"
expect_present "Hide CobAlt"
expect_absent  "About Hammerspoon"
expect_absent  "Quit Hammerspoon"
expect_absent  "Hammerspoon"

# The one string that must survive untouched. Renaming it is what left
# Quit wired to a method no class implements.
expect_present "quitHammerspoon:"
# The other menu selectors have no app name in them, but assert anyway:
# they are what About and Preferences hang off.
expect_present "showAboutPanel:"
expect_present "showPreferencesWindow:"

echo
echo "→ An unsupported invocation must fail, not quietly do nothing"
if python3 build/rename-nib.py "$NIBS/MainMenu.nib" --remove-item 2>/dev/null; then
  echo "  ✗ a malformed call succeeded" >&2 ; fail=1
else
  echo "  ✓ malformed calls are rejected"
fi

echo
echo "→ Removing BOTH Preferences items"
# One lives in the app menu (real ellipsis), one in the engine's own
# status menu (three dots). Both open the same window, so leaving either
# leaves the settings reachable.
for item in "Preferences…" "Preferences..."; do
  python3 build/rename-nib.py "$NIBS/MainMenu.nib" --remove-item "$item"
done
gone_from_menus() {
  python3 - "$NIBS/MainMenu.nib" "$1" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("rn", "build/rename-nib.py")
rn = importlib.util.module_from_spec(spec); spec.loader.exec_module(rn)
a = rn.parse(open(sys.argv[1], "rb").read())
for i in range(len(a["objects"])):
    if rn._cls(a, i) == "NSMenuItem" and rn._item_title(a, i) == sys.argv[2]:
        sys.exit(1 if rn._in_a_menu(a, i) else 0)
sys.exit(0)
PY
}
for item in "Preferences…" "Preferences..."; do
  if gone_from_menus "$item"; then echo "  ✓ no menu holds: $item"
  else echo "  ✗ STILL IN A MENU: $item" >&2 ; fail=1 ; fi
done
# Removing entries shifts every value index after them; a botched edit
# empties the menu without complaining.
expect_present "Quit CobAlt"
expect_present "About CobAlt"
expect_present "Check for Updates..."

echo
echo "→ Edited nibs must still parse and round-trip"
python3 - "$NIBS" <<'PY'
import glob, importlib.util, os, sys
spec = importlib.util.spec_from_file_location("rn", "build/rename-nib.py")
rn = importlib.util.module_from_spec(spec); spec.loader.exec_module(rn)
bad = 0
for f in sorted(glob.glob(os.path.join(sys.argv[1], "*.nib"))):
    d = open(f, "rb").read()
    try:
        if rn.build(rn.parse(d)) != d:
            print("  ✗ %s no longer round-trips" % os.path.basename(f)); bad += 1
        else:
            print("  ✓ %s" % os.path.basename(f))
    except Exception as e:
        print("  ✗ %s is corrupt: %s" % (os.path.basename(f), e)); bad += 1
sys.exit(1 if bad else 0)
PY

test "$fail" = "0"
echo
echo "✓ nib rename is lossless, renames display strings, and leaves selectors alone"
