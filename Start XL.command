#!/bin/bash
# Start XL.command — double-click this in Finder to build (first time),
# install, and launch ⌥XL. It just calls start.sh from the repo root.
cd "$(dirname "$0")"
./start.sh
echo "Press any key to close this window…"
read -n 1 -s
