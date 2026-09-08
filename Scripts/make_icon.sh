#!/usr/bin/env bash
# Regenerate Icon.icns from Scripts/make_icon.swift.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ICONSET=$(mktemp -d)/Readout.iconset
mkdir -p "$ICONSET"

swift "$ROOT/Scripts/make_icon.swift" "$ICONSET"
iconutil --convert icns --output "$ROOT/Icon.icns" "$ICONSET"
rm -rf "$(dirname "$ICONSET")"
echo "Created $ROOT/Icon.icns"
