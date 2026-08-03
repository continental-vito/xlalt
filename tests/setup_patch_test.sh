#!/bin/bash
# tests/setup_patch_test.sh — prove the setup.lua patch actually changes
# where the engine looks for its config.
#
# This exists because the first version of that patch was inert. It
# assigned the right locals, the build asserted the assignment was present,
# CI was green — and setup.lua forwards its ORIGINAL varargs to
# hs._coresetup.setup(...), so none of it reached the runtime. The app kept
# working only on a machine where a preference left by the old launcher
# still pointed at a config directory. Renaming the bundle broke that, and
# the app launched to a menu bar and nothing else.
#
# So this runs the patched file with a stub _coresetup and checks the
# arguments that come out the other end.
set -uo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; fail=$((fail+1)); }

HS_VERSION="${HS_VERSION:-1.1.1}"
echo "Config resolution"
echo "→ Fetching the runtime's setup.lua (${HS_VERSION})"
curl -sL -o "$WORK/hs.zip" \
  "https://github.com/Hammerspoon/hammerspoon/releases/download/${HS_VERSION}/Hammerspoon-${HS_VERSION}.zip"
unzip -q "$WORK/hs.zip" -d "$WORK"

# A bundle laid out like the real one.
APP="$WORK/CobAlt.app"
mkdir -p "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$WORK/Hammerspoon.app/Contents/Resources/setup.lua" "$APP/Contents/Resources/"
echo "-- the engine" > "$APP/Contents/Resources/init.lua"

# Apply exactly what build-app.sh applies, by running that section of it.
sed -n "/^python3 - \"\$APP\" <<'PATCH'$/,/^PATCH$/p" build/build-app.sh \
  | sed -e "1s/.*/python3 - \"\$APP\" <<'PATCH'/" > "$WORK/apply.sh"
APP="$APP" bash "$WORK/apply.sh" >/dev/null || { echo "  FAIL  patch did not run" ; exit 1; }

if grep -q "setup(\.\.\.)" "$APP/Contents/Resources/setup.lua"; then
  bad "the vararg tail call is rewritten" "setup(...) is still there"
else
  ok "the vararg tail call is rewritten"
fi

# Run it. The stub records what setup.lua actually forwards.
cat > "$WORK/stub.lua" <<'LUA'
package.preload['hs._coresetup'] = function()
  return { setup = function(modpath, frameworkspath, prettypath, fullpath,
                            configdir, docstringspath, hasinitfile, autoload)
    RESULT = { configdir = configdir, fullpath = fullpath,
               hasinitfile = hasinitfile }
    return {}
  end }
end
-- setup.lua touches these before the tail call.
hs = setmetatable({}, { __index = function() return function() end end })
LUA

run_setup() {                 # run_setup <configdir-argument>
  lua5.4 -e "
    dofile('$WORK/stub.lua')
    local f = assert(loadfile('$APP/Contents/Resources/setup.lua'))
    pcall(f, '$APP/Contents/Frameworks/hs', '$APP/Contents/Frameworks',
             '$1/init.lua', '$1/init.lua', '$1', '/docs', false, false)
    -- setup.lua prints package.path itself, so mark ours.
    print('XLDIR=' .. ((RESULT and RESULT.configdir) or 'NONE'))
    print('XLHAS=' .. ((RESULT and tostring(RESULT.hasinitfile)) or 'NONE'))
  " 2>/dev/null
}

# The runtime is told the config is somewhere else entirely — which is what
# a machine with no MJConfigFile preference looks like.
OUT=$(run_setup "$WORK/nowhere")
GOT_DIR=$(echo "$OUT" | sed -n 's/^XLDIR=//p')
GOT_HAS=$(echo "$OUT" | sed -n 's/^XLHAS=//p')

if [ "$GOT_DIR" = "$APP/Contents/Resources" ]; then
  ok "the config directory is redirected into the bundle"
else
  bad "the config directory is redirected into the bundle" \
      "got: $GOT_DIR  wanted: $APP/Contents/Resources"
fi
if [ "$GOT_HAS" = "true" ]; then
  ok "and the runtime is told an init file exists"
else
  bad "and the runtime is told an init file exists" "got: $GOT_HAS"
fi

# With no init.lua in the bundle it must not claim one: better to fall back
# than to promise a config that is not there.
rm -f "$APP/Contents/Resources/init.lua"
OUT=$(run_setup "$WORK/nowhere")
if [ "$(echo "$OUT" | sed -n 's/^XLDIR=//p')" = "$WORK/nowhere" ]; then
  ok "with no config in the bundle it leaves the runtime's own path alone"
else
  bad "with no config in the bundle it leaves the runtime's own path alone" \
      "got: $(echo "$OUT" | sed -n 's/^XLDIR=//p')"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" = "0" ]
