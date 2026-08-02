#!/bin/bash
# tests/swap_test.sh — run the generated update script for real.
#
# The Lua suite checks that this script CONTAINS the right lines. That is
# not the same as it doing the right thing, and the swap is the one path
# where a bug means the user is left with no working app. So here the
# script is actually executed, against real directories, and the result on
# disk is checked.
#
# Runs on Linux: the macOS-only commands are stubbed. What is under test is
# the ordering and the failure paths, not ditto.
set -uo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

ok()   { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; fail=$((fail+1)); }
check(){ if [ "$2" = "yes" ]; then ok "$1"; else bad "$1" "${3:-}"; fi; }

# A bundle that looks enough like the real thing for the script's checks.
make_app() {                      # make_app <path> [--empty]
  mkdir -p "$1/Contents/MacOS" "$1/Contents/Resources"
  if [ "${2:-}" != "--empty" ]; then
    printf '#!/bin/sh\n' > "$1/Contents/MacOS/Hammerspoon"
    chmod +x "$1/Contents/MacOS/Hammerspoon"
  fi
  echo "$1" > "$1/Contents/Resources/marker"
}

# Take the script the engine really generates and make it runnable here.
generate() {                      # generate <dest> <new> -> script path
  lua5.4 tests/run_tests.lua >/dev/null 2>&1
  local src=/tmp/xlalt-update/swap.sh out="$WORK/swap.sh"
  test -f "$src" || { echo "the Lua suite did not write a swap script" >&2; exit 1; }
  sed -e "s|^PID=.*|PID=1|" \
      -e "s|^DEST=.*|DEST=\"$1\"|" \
      -e "s|^NEW=.*|NEW=\"$2\"|" \
      -e "s|^LOG=.*|LOG=\"$WORK/update.log\"|" \
      -e "s|/usr/bin/ditto|cp -R|g" \
      -e "s|/usr/bin/xattr|true|g" \
      -e "s|/usr/bin/open|echo OPENED|g" \
      -e "s|^while kill.*|:|" \
      -e "s|^sleep 0.5||" \
      "$src" > "$out"
  # cp -R needs the destination not to exist; ditto overwrites. Same effect
  # here because the script always removes .new first.
  chmod +x "$out"
  echo "$out"
}

run() { sh "$1" >/dev/null 2>&1; }

echo "Update swap"

# --- the rename: this is what the release is for -----------------------
D="$WORK/a"; mkdir -p "$D"
make_app "$D/ExcelAlt.app"
make_app "$WORK/src-a/CobAlt.app"
run "$(generate "$D/ExcelAlt.app" "$WORK/src-a/CobAlt.app")"
check "a renamed archive installs under its own name" \
  "$([ -x "$D/CobAlt.app/Contents/MacOS/Hammerspoon" ] && echo yes || echo no)" \
  "$(ls "$D" 2>/dev/null | tr '\n' ' ')"
check "and the previously-named bundle is gone" \
  "$([ ! -e "$D/ExcelAlt.app" ] && echo yes || echo no)" \
  "$(ls "$D" 2>/dev/null | tr '\n' ' ')"
check "no scratch directories are left behind" \
  "$([ ! -e "$D/CobAlt.app.new" ] && [ ! -e "$D/CobAlt.app.old" ] && echo yes || echo no)" \
  "$(ls "$D" 2>/dev/null | tr '\n' ' ')"

# --- same name, the ordinary case --------------------------------------
D="$WORK/b"; mkdir -p "$D"
make_app "$D/CobAlt.app"
echo old > "$D/CobAlt.app/Contents/Resources/marker"
make_app "$WORK/src-b/CobAlt.app"
echo new > "$WORK/src-b/CobAlt.app/Contents/Resources/marker"
run "$(generate "$D/CobAlt.app" "$WORK/src-b/CobAlt.app")"
check "an ordinary update replaces the bundle in place" \
  "$([ "$(cat "$D/CobAlt.app/Contents/Resources/marker" 2>/dev/null)" = new ] && echo yes || echo no)" \
  "$(cat "$D/CobAlt.app/Contents/Resources/marker" 2>/dev/null)"

# --- a download with no engine in it -----------------------------------
# The failure that matters: something went wrong with the archive and the
# installed app must survive untouched.
D="$WORK/c"; mkdir -p "$D"
make_app "$D/ExcelAlt.app"
make_app "$WORK/src-c/CobAlt.app" --empty
run "$(generate "$D/ExcelAlt.app" "$WORK/src-c/CobAlt.app")"
check "a download with no engine leaves the installed app alone" \
  "$([ -x "$D/ExcelAlt.app/Contents/MacOS/Hammerspoon" ] && echo yes || echo no)" \
  "$(ls "$D" 2>/dev/null | tr '\n' ' ')"
check "and does not leave a half-installed bundle behind" \
  "$([ ! -e "$D/CobAlt.app" ] && [ ! -e "$D/CobAlt.app.new" ] && echo yes || echo no)" \
  "$(ls "$D" 2>/dev/null | tr '\n' ' ')"

# --- the archive vanishes between download and swap --------------------
D="$WORK/d"; mkdir -p "$D"
make_app "$D/ExcelAlt.app"
run "$(generate "$D/ExcelAlt.app" "$WORK/does-not-exist/CobAlt.app")"
check "a missing archive leaves the installed app alone" \
  "$([ -x "$D/ExcelAlt.app/Contents/MacOS/Hammerspoon" ] && echo yes || echo no)" \
  "$(ls "$D" 2>/dev/null | tr '\n' ' ')"

echo
echo "$pass passed, $fail failed"
[ "$fail" = "0" ]
