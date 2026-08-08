#!/bin/bash
# tests/names_test.sh — build scripts must not spell out an app name that
# a rename can orphan.
#
# build-local.sh killed the running dev build with
#
#     pkill -f "ExcelAlt-dev.app"
#
# and that literal stayed behind when the dev bundle became CobAlt-dev.app.
# It matched nothing, so the old process kept running and `open` merely
# brought it to the front. Every rebuild appeared to change nothing while
# the bundle on disk was completely up to date — three separate features
# were reported broken because of it.
#
# Names belong in one variable each. Everything else refers to that.
set -uo pipefail
cd "$(dirname "$0")/.."

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; fail=$((fail+1)); }

echo "Build scripts"

# The one place each literal is allowed is the assignment that defines it.
check_file() {                     # check_file <path> <pattern> <allowed-regex>
  local file="$1" pat="$2" allow="$3"
  local hits
  hits=$(grep -n "$pat" "$file" | grep -vE "$allow" || true)
  if [ -z "$hits" ]; then
    ok "$(basename "$file") does not spell out $pat"
  else
    bad "$(basename "$file") spells out $pat" "$(echo "$hits" | head -3)"
  fi
}

# ExcelAlt-dev.app may appear only where OLD_DEV_APP is defined: it is the
# name we clean up after, and it must not be used for anything else.
check_file build/build-local.sh "ExcelAlt-dev\.app" '^[0-9]+:#|OLD_DEV_APP='

# The product name belongs to XL_BUNDLE_NAME / XL_DISPLAY_NAME.
check_file build/build-local.sh "CobAlt-dev\.app" '^[0-9]+:#|DEV_APP='

# A kill that names a bundle must derive it from a variable, or a rename
# leaves it matching nothing and the failure is invisible.
if grep -nE '^[^#]*pkill .*"\$(DEV_APP|OLD_DEV_APP)"' build/build-local.sh >/dev/null; then
  ok "the running dev build is stopped by path, not by a literal name"
else
  bad "the running dev build is not stopped by a derived path" \
      "$(grep -n 'pkill' build/build-local.sh | head -3)"
fi

# ...and it must actually wait, or ditto races the dying process.
if grep -q 'pgrep -f "\$DEV_APP"' build/build-local.sh; then
  ok "and the build waits for it to exit"
else
  bad "the build does not wait for the old process to exit"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" = "0" ]
