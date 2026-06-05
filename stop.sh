#!/bin/zsh
# Kill every running wand instance — release bundle, dev bundle,
# or raw SwiftPM binary. Use when you've lost track of which one
# is up (M2 first-run debugging or verification sessions often
# pile up). Safe to run when nothing is running (no-op + "(none
# running)").
#
#   ./stop.sh

set -e
cd "$(dirname "$0")"

pkill -f '/Contents/MacOS/wand' 2>/dev/null || true
pkill -f '\.build/.*/wand'      2>/dev/null || true

# Confirmation pass: anything still alive?
remaining="$(ps aux \
    | grep -E '/Contents/MacOS/wand|\.build/.*/wand' \
    | grep -v grep || true)"
if [[ -n "$remaining" ]]; then
    echo "warning: some wand instances survived:" >&2
    echo "$remaining" >&2
    exit 1
fi
echo "killed: all wand instances"
