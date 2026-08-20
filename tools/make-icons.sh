#!/bin/zsh
# Regenerates every app icon from assets/icon/*.png. Run after changing the artwork.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$(mktemp -d)/make-icons"

echo "==> compiling"
swiftc -O -o "$BIN" "$ROOT/tools/make-icons.swift"

echo "==> generating"
"$BIN" "$ROOT"

echo "==> packing AppIcon.icns"
iconutil -c icns "$ROOT/mac/Resources/AppIcon.iconset" -o "$ROOT/mac/Resources/AppIcon.icns"
rm -rf "$ROOT/mac/Resources/AppIcon.iconset"

echo "==> ok"
