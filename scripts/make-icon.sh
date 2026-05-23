#!/bin/zsh
# Generate assets/Stroke.icns from the Swift renderer + macOS iconutil.
# Idempotent — re-run after any edit to make-icon.swift and the
# committed .icns updates.
set -euo pipefail

cd "$(dirname "$0")/.."

tmp=".icon-build"
rm -rf "$tmp"
mkdir -p "$tmp"
pushd "$tmp" > /dev/null

swift ../scripts/make-icon.swift
iconutil -c icns Stroke.iconset -o Stroke.icns

popd > /dev/null
mkdir -p assets
mv "$tmp/Stroke.icns" assets/Stroke.icns
rm -rf "$tmp"

echo "wrote assets/Stroke.icns ($(stat -f%z assets/Stroke.icns) bytes)"
