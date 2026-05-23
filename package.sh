#!/bin/zsh
# Build a release binary and assemble the .app bundle.
#
# Modes:
#   ./package.sh           release → Stroke.app     / com.stroke.stroke
#   ./package.sh --dev     dev     → Stroke-dev.app / com.stroke.stroke.dev
#
# Why two flavors: the dev build (run from the repo) and a co-installed
# Homebrew release would otherwise share the same bundle id, so macOS
# would treat them as one app for TCC and the System Settings list
# would show two indistinguishable "stroke" entries. The dev variant
# gets its own bundle id + display name "stroke (dev)" so each side
# keeps its own Accessibility grant.
#
# The RELEASE bundle id is com.stroke.stroke — keep it stable across
# versions: macOS keys the Accessibility (TCC) grant + the self-signed
# cert to it.
#
# TCC: ad-hoc signing is not a stable identity → re-grant on every
# rebuild. Persist with a self-signed cert via
# ./setup-signing-cert.sh (writes .signing-id).
set -e
cd "$(dirname "$0")"

MODE="release"
PLIST="Info.plist"
APP="Stroke.app"
if [[ "${1:-}" == "--dev" ]]; then
  MODE="dev"; PLIST="Info.plist.dev"; APP="Stroke-dev.app"
fi

swift build -c release

# Clean up any prior bundle of either flavor before re-assembling.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PLIST" "$APP/Contents/Info.plist"
cp .build/release/stroke "$APP/Contents/MacOS/stroke"   # = CFBundleExecutable
# CFBundleIconFile = Stroke (set in Info.plist) tells Launch Services
# to look for Stroke.icns in Resources/. Committed binary lives in
# assets/; regenerate with scripts/make-icon.sh.
if [[ -f assets/Stroke.icns ]]; then
  cp assets/Stroke.icns "$APP/Contents/Resources/Stroke.icns"
fi

# Identity precedence: $CODESIGN_ID > .signing-id file > ad-hoc ("-").
ID="${CODESIGN_ID:-}"
if [[ -z "$ID" && -f .signing-id ]]; then ID="$(cat .signing-id)"; fi
ID="${ID:--}"
codesign --force --sign "$ID" "$APP"

echo "built $APP  ($MODE, signed: $ID)"
echo "launch: open $APP   |   quit: pkill -f /Contents/MacOS/stroke"
