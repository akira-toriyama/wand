#!/bin/zsh
# Build + launch a wand .app bundle locally. Defaults to release
# (Wand.app, com.wand.wand) — the bundle you'd actually use day
# to day. ``--dev`` builds the parallel Wand-dev.app
# (com.wand.wand.dev) for verification alongside a Homebrew
# install without TCC grant collisions.
#
#   ./run.sh             release → Wand.app     (WAND_DEBUG on)
#   ./run.sh --dev       dev     → Wand-dev.app (WAND_DEBUG on)
#
# Always kills any currently-running wand first (via stop.sh) so
# the new bundle takes over cleanly. Quit later: ``./stop.sh`` or
# ``wand daemon --quit``.
set -e
cd "$(dirname "$0")"

MODE=""
APP="Wand.app"
if [[ "${1:-}" == "--dev" ]]; then
    MODE="--dev"
    APP="Wand-dev.app"
fi

./package.sh $MODE
./stop.sh
sleep 0.5

# run.sh is the local dev/debug launcher → always set WAND_DEBUG so
# /tmp/wand.log gets the verbose lines (event-tap samples, target
# resolution, dispatch traces) and is mirrored to stderr. A normal
# `brew services start wand` / raw `open Wand.app` sets nothing and
# stays quiet — there is no `--debug` CLI flag: debug is env-var-
# triggered. macOS Launch Services starts the .app in its own
# context (it does NOT inherit the calling shell's environment), so
# the var has to be passed through explicitly via `open --env`.
open "./$APP" --env WAND_DEBUG=1
echo "$APP launched (WAND_DEBUG=1). Grant Accessibility on first run."
echo "logs: tail -f /tmp/wand.log   |   quit: ./stop.sh or wand daemon --quit"
