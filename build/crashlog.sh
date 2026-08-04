#!/bin/bash
# build/crashlog.sh — print the useful part of the newest crash report.
#
# .ips files are two JSON documents stuck together and are unreadable by
# eye. This prints the exception, the termination reason and the frames of
# the thread that actually crashed, which is all that is needed to say
# what went wrong.
#
#   bash build/crashlog.sh
set -uo pipefail

python3 - <<'PY'
import glob, json, os, sys

pats = ["Hammerspoon-*.ips", "CobAlt*.ips", "ExcelAlt*.ips"]
files = []
for p in pats:
    files += glob.glob(os.path.expanduser("~/Library/Logs/DiagnosticReports/" + p))
if not files:
    sys.exit("no crash reports found")
path = max(files, key=os.path.getmtime)
print("report:", os.path.basename(path))

raw = open(path, "r", errors="replace").read().split("\n", 1)
try:
    body = json.loads(raw[1])
except Exception as e:
    sys.exit("could not parse the report: %s" % e)

print("process:", body.get("procName"), body.get("procPath", ""))
exc = body.get("exception") or {}
print("exception:", exc.get("type"), exc.get("signal"), exc.get("subtype", ""))
term = body.get("termination") or {}
if term:
    print("termination:", term.get("namespace"), term.get("code"),
          term.get("indicator", ""))
    for r in (term.get("reasons") or [])[:4]:
        print("   ", r)
if body.get("asi"):
    for k, v in body["asi"].items():
        for line in v[:4]:
            print("  asi %s: %s" % (k, line))

images = body.get("usedImages", [])
def image_name(i):
    if i is None or i >= len(images):
        return "?"
    return images[i].get("name") or "?"

for t in body.get("threads", []):
    if not t.get("triggered"):
        continue
    print("\ncrashed thread: %s" % (t.get("name") or t.get("queue") or ""))
    for f in (t.get("frames") or [])[:24]:
        print("   %-28s %s" % (image_name(f.get("imageIndex")),
                               f.get("symbol") or hex(f.get("imageOffset", 0))))
    break
PY
