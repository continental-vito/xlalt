#!/bin/bash
# build/verify-signing.sh — proves the signing technique that in-place
# updates depend on. macOS only; runs in CI on every push.
#
# The claim being tested: two *different* builds of this app can satisfy
# each other's designated requirement, which is the check Sparkle's
# installer performs and the one that has been failing since v3.2.
#
# It builds a minimal bundle rather than the real app so it costs seconds
# and needs no network. The signing commands are the same ones
# build/build-app.sh uses; if this passes and the real build uses the same
# commands, the real build satisfies the same property.
#
# Both directions are checked. A plain ad-hoc signature MUST fail — a
# test that passes with and without the fix proves nothing.
set -euo pipefail
cd "$(dirname "$0")/.."

BID="com.corgianalyst.excel-alt-shortcuts.signtest"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "→ Building the requirement checker"
clang -O2 -o "$WORK/drcheck" build/drcheck.c \
  -framework CoreFoundation -framework Security

# --- a minimal but structurally real app bundle -----------------------
# Same shape as the product: a compiled Mach-O main executable plus a
# resource that changes between builds.
make_bundle() {           # make_bundle <dir> <resource-contents>
  local app="$1" body="$2"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$BID</string>
  <key>CFBundleName</key><string>SignTest</string>
  <key>CFBundleExecutable</key><string>SignTest</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
</dict></plist>
PLIST
  echo 'int main(void){return 0;}' > "$WORK/stub.c"
  clang -O2 -o "$app/Contents/MacOS/SignTest" "$WORK/stub.c"
  printf '%s' "$body" > "$app/Contents/Resources/init.lua"
}

# The two signing strategies, isolated so the difference is the variable.
sign_adhoc() {            # what the build did before — synthesises cdhash
  codesign --force --deep --sign - "$1"
}
sign_with_requirement() { # what build/build-app.sh does now
  codesign --force --deep --sign - "$1"
  codesign --force --sign - --identifier "$BID" \
    -r="designated => identifier \"$BID\"" "$1"
}

# Two builds that differ, as consecutive releases do.
make_bundle "$WORK/old.app" "-- release one"
make_bundle "$WORK/new.app" "-- release two, with more code in it"

# --- negative control -------------------------------------------------
echo
echo "→ Control: plain ad-hoc signing (the v3.2–v3.9 behaviour)"
sign_adhoc "$WORK/old.app"
sign_adhoc "$WORK/new.app"
if "$WORK/drcheck" "$WORK/old.app" "$WORK/new.app"; then
  echo "✗ plain ad-hoc signing validated across builds — this test is not" >&2
  echo "  measuring what it claims to measure; do not trust the result below" >&2
  exit 1
fi
echo "  ✓ fails as expected"

# --- the fix ----------------------------------------------------------
echo
echo "→ With an explicit designated requirement"
sign_with_requirement "$WORK/old.app"
sign_with_requirement "$WORK/new.app"
if ! "$WORK/drcheck" "$WORK/old.app" "$WORK/new.app"; then
  echo "✗ the explicit requirement does NOT make cross-build updates valid" >&2
  exit 1
fi

# Also confirm the requirement reads the way build-app.sh asserts it does.
DR="$(codesign -d -r- "$WORK/old.app" 2>&1 | grep '^designated' || true)"
case "$DR" in
  *"identifier \"$BID\""*) echo "  ✓ $DR" ;;
  *) echo "✗ unexpected designated requirement: $DR" >&2 ; exit 1 ;;
esac

echo
echo "✓ cross-build update validation works with an explicit requirement"
