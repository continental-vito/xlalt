#!/bin/bash
# build/build-local.sh — build a development build of ⌥XL and run it on this Mac.
#
#   bash build/build-local.sh                # test → build → install → launch
#   bash build/build-local.sh --no-launch    # build and install, don't open it
#   bash build/build-local.sh --reset-tcc    # clear the stale Accessibility grant first
#   bash build/build-local.sh --package      # also produce dist/XL.dmg (slow, rarely needed)
#
# Installs to ~/Applications/ExcelAlt-dev.app, leaving the released build in
# /Applications untouched. Touches no git state: no tag, no release, no
# appcast — users on the released version see nothing until a v* tag is
# pushed from main.
set -euo pipefail
cd "$(dirname "$0")/.."

LAUNCH=1
PACKAGE=""
RESET_TCC=""
for arg in "$@"; do
  case "$arg" in
    --no-launch) LAUNCH="" ;;
    --package)   PACKAGE=1 ;;
    --reset-tcc) RESET_TCC=1 ;;
    -h|--help)   sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
  esac
done

DEV_APP="$HOME/Applications/ExcelAlt-dev.app"
CONFIG="$HOME/Library/Application Support/Excel Alt Shortcuts/shortcuts.json"
BACKUPS="$HOME/.xlalt-backups"

# ---------------------------------------------------------------- safety net
# shortcuts.json is user data the released build also reads. If a dev build
# writes a new schema, going back to the release means handing it a file it
# does not understand — so snapshot it before every single build.
if [ -f "$CONFIG" ]; then
  mkdir -p "$BACKUPS"
  STAMP=$(date +%Y%m%d-%H%M%S)
  cp "$CONFIG" "$BACKUPS/shortcuts-$STAMP.json"
  # Keep the 20 most recent snapshots.
  ls -1t "$BACKUPS"/shortcuts-*.json 2>/dev/null | tail -n +21 | while read -r f; do rm -f "$f"; done
  echo "→ Config backed up to $BACKUPS/shortcuts-$STAMP.json"
else
  echo "→ No shortcuts.json yet (first run) — nothing to back up"
fi

# --------------------------------------------------------------------- tests
LUA=$(command -v lua5.4 || command -v lua || true)
if [ -n "$LUA" ]; then
  echo "→ Running test suite ($LUA)"
  "$LUA" tests/run_tests.lua
else
  echo "→ Lua not installed locally, skipping tests (CI runs them on push)"
fi

# --------------------------------------------------------------------- build
# Version carries the branch and commit so the About window, logs, and any
# feedback email name the exact build — never a released version number.
BASE=$(git describe --tags --abbrev=0 2>/dev/null || echo 0.0)
BASE="${BASE#v}"
SHA=$(git rev-parse --short HEAD 2>/dev/null || echo nogit)
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo detached)
DIRTY=""
[ -n "$(git status --porcelain 2>/dev/null)" ] && DIRTY="+"
export XL_VERSION="${BASE}-dev.${BRANCH}.${SHA}${DIRTY}"
# CFBundleVersion is what Sparkle compares. Releases use the CI run number
# (small); parking dev builds at 90000+ guarantees the live appcast can never
# offer to "update" a dev build back down to the released one.
export XL_BUILD=$((90000 + $(git rev-list --count HEAD 2>/dev/null || echo 0)))

echo "→ Building $XL_VERSION (build $XL_BUILD)"
if [ -n "$PACKAGE" ]; then
  bash build/build-app.sh
else
  XL_APP_ONLY=1 bash build/build-app.sh
fi

# ------------------------------------------------------------------- install
echo "→ Stopping any running ExcelAlt"
# Released and dev builds share a bundle id and both rewrite
# ~/.hammerspoon/init.lua at launch — only one can run at a time.
pkill -x ExcelAlt ExcelAltCore 2>/dev/null || true
sleep 1

if [ -n "$RESET_TCC" ]; then
  echo "→ Clearing Accessibility grant (you will be re-prompted)"
  tccutil reset Accessibility com.corgianalyst.excel-alt-shortcuts || true
fi

mkdir -p "$HOME/Applications"
rm -rf "$DEV_APP"
# ditto, not cp: the bundle signature lives in extended attributes.
ditto dist/ExcelAlt.app "$DEV_APP"
echo "→ Installed $DEV_APP"

if [ -n "$LAUNCH" ]; then
  open -a "$DEV_APP"
  echo "✓ $XL_VERSION running"
else
  echo "✓ $XL_VERSION built — open $DEV_APP when ready"
fi

cat <<NOTES

  Ad-hoc signing changes the code hash every build, so macOS may ask for
  Accessibility again. If the shortcuts are dead and no prompt appears,
  re-run with --reset-tcc.

  Back to the released build: quit this one, open /Applications/ExcelAlt.app.
  It rewrites ~/.hammerspoon/init.lua itself, so its own code returns. If
  shortcuts.json changed shape in the meantime, restore a snapshot from
  $BACKUPS.
NOTES
