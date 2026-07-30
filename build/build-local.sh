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
    --package)   PACKAGE=1 ;;   # also writes dist/XL-dev.dmg
    --reset-tcc) RESET_TCC=1 ;;
    -h|--help)   sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
  esac
done

DEV_APP="$HOME/Applications/ExcelAlt-dev.app"
LIVE_CONFIG="$HOME/Library/Application Support/ExcelAlt/shortcuts.json"
DEV_SUPPORT="$HOME/Library/Application Support/ExcelAlt-dev"
BACKUPS="$HOME/.xlalt-backups"

# The dev build is a SEPARATE APP: its own bundle id, so macOS gives it its
# own preferences and its own Accessibility entry, and the engine puts its
# data in ExcelAlt-dev/ rather than ExcelAlt/. The released app in
# /Applications is never read from, written to, or replaced.
export XL_BUNDLE_ID="com.corgianalyst.excel-alt-shortcuts.dev"
export XL_BUNDLE_NAME="ExcelAlt-dev"
export XL_DISPLAY_NAME="⌥XL (dev)"
export XL_NO_UPDATES=1
export XL_DMG_NAME="XL-dev"

# ---------------------------------------------------------------- safety net
# Belt and braces: snapshot the RELEASED app's shortcuts.json before every
# build. The dev build should never touch it, and this is how we would know
# if that ever stopped being true.
if [ -f "$LIVE_CONFIG" ]; then
  mkdir -p "$BACKUPS"
  STAMP=$(date +%Y%m%d-%H%M%S)
  cp "$LIVE_CONFIG" "$BACKUPS/shortcuts-$STAMP.json"
  ls -1t "$BACKUPS"/shortcuts-*.json 2>/dev/null | tail -n +21 | while read -r f; do rm -f "$f"; done
  echo "→ Released app's config snapshotted to $BACKUPS/shortcuts-$STAMP.json"
else
  echo "→ No released shortcuts.json found — nothing to snapshot"
fi

# Start the dev build from a copy of the real shortcuts so the lists look
# familiar, but only once: after that the dev app owns its own file.
if [ ! -f "$DEV_SUPPORT/shortcuts.json" ] && [ -f "$LIVE_CONFIG" ]; then
  mkdir -p "$DEV_SUPPORT"
  cp "$LIVE_CONFIG" "$DEV_SUPPORT/shortcuts.json"
  echo "→ Seeded the dev app with a copy of your current shortcuts"
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
# Only the previous DEV build is stopped; a running release build is left
# alone. They have separate bundle ids, separate config dirs and separate
# data, so both can run at once — but two engines both watching Excel would
# double-fire every shortcut, so quit the release app while you test.
echo "→ Stopping any running dev build"
pkill -f "ExcelAlt-dev.app" 2>/dev/null || true
sleep 1

if [ -n "$RESET_TCC" ]; then
  echo "→ Clearing the dev build's Accessibility grant (you will be re-prompted)"
  tccutil reset Accessibility "$XL_BUNDLE_ID" || true
fi

mkdir -p "$HOME/Applications"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# Drop the old record before the bundle disappears, or LaunchServices keeps
# pointing at a path that no longer exists.
[ -x "$LSREGISTER" ] && [ -d "$DEV_APP" ] && "$LSREGISTER" -u "$DEV_APP" 2>/dev/null
rm -rf "$DEV_APP"
# ditto, not cp: the bundle signature lives in extended attributes.
ditto "dist/${XL_BUNDLE_NAME}.app" "$DEV_APP"

# macOS caches app icons hard. Reusing the same install path across builds
# means Finder and the About panel can show the icon from three builds
# ago until LaunchServices is told the bundle changed. Re-registering the
# bundle is enough and is inert.
#
# This deliberately does NOT restart the Dock. An earlier version ran
# `killall Dock` here: normally launchd respawns it in under a second,
# but when it does not the user loses the Dock, Mission Control and
# Cmd-Tab at once — no build script should be able to do that to a
# machine someone is working on.
touch "$DEV_APP"
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$DEV_APP" 2>/dev/null
echo "→ Installed $DEV_APP"

if [ -n "$LAUNCH" ]; then
  open -a "$DEV_APP"
  echo "✓ $XL_VERSION running"
else
  echo "✓ $XL_VERSION built — open $DEV_APP when ready"
fi

cat <<NOTES

  This is a separate app from the one in /Applications:
    bundle id   $XL_BUNDLE_ID
    data        ~/Library/Application Support/ExcelAlt-dev/
    log         ~/Library/Application Support/ExcelAlt-dev/debug.log
  Your released ⌥XL and its shortcuts are untouched.

  Quit the released ⌥XL while testing — two engines watching the same app
  would both fire on every sequence.

  macOS will ask for Accessibility for "⌥XL (dev)" separately. Ad-hoc
  signing changes the code hash every build, so it may ask again after a
  rebuild; if shortcuts are dead and nothing is asked, re-run --reset-tcc.

  If the Dock or Finder still shows an old icon, log out and back in —
  that clears the icon cache without restarting anything by force.

  Done testing: quit ⌥XL (dev) and reopen /Applications/ExcelAlt.app.
  To remove the dev build entirely:
    rm -rf "$DEV_APP" "$DEV_SUPPORT" ~/.hammerspoon-xldev
NOTES
